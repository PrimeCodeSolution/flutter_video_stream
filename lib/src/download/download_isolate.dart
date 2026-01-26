import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';

/// Message types for isolate communication
enum DownloadMessageType {
  start,
  progress,
  complete,
  error,
  cancel,
}

/// Message sent to/from the download isolate
class DownloadMessage {
  final DownloadMessageType type;
  final String? url;
  final String? filePath;
  final Map<String, String>? headers;
  final int? bytesDownloaded;
  final int? totalBytes;
  final String? error;
  final int? taskId;

  DownloadMessage({
    required this.type,
    this.url,
    this.filePath,
    this.headers,
    this.bytesDownloaded,
    this.totalBytes,
    this.error,
    this.taskId,
  });
}

/// Download task running in an isolate
class IsolateDownloadTask {
  final int id;
  final String url;
  final String filePath;
  final Map<String, String>? headers;
  final int priority;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  final _completer = Completer<void>();

  int _bytesDownloaded = 0;
  int _totalBytes = 0;
  bool _isCancelled = false;

  IsolateDownloadTask({
    required this.id,
    required this.url,
    required this.filePath,
    this.headers,
    this.priority = 0,
  });

  /// Stream of download progress
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  /// Future that completes when download finishes
  Future<void> get future => _completer.future;

  /// Current download progress (0.0 to 1.0)
  double get progress => _totalBytes > 0 ? _bytesDownloaded / _totalBytes : 0.0;

  /// Whether the download has been cancelled
  bool get isCancelled => _isCancelled;

  void _updateProgress(int downloaded, int total) {
    _bytesDownloaded = downloaded;
    _totalBytes = total;
    if (!_progressController.isClosed) {
      _progressController.add(DownloadProgress(
        bytesDownloaded: downloaded,
        totalBytes: total,
        progress: total > 0 ? downloaded / total : 0.0,
      ));
    }
  }

  void _complete() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
    _progressController.close();
  }

  void _completeWithError(Object error) {
    if (!_completer.isCompleted) {
      _completer.completeError(error);
    }
    _progressController.close();
  }

  void cancel() {
    _isCancelled = true;
    // Complete with cancellation error and close controller
    if (!_completer.isCompleted) {
      _completer.completeError(Exception('Download cancelled'));
    }
    if (!_progressController.isClosed) {
      _progressController.close();
    }
  }
}

/// Download progress info
class DownloadProgress {
  final int bytesDownloaded;
  final int totalBytes;
  final double progress;

  DownloadProgress({
    required this.bytesDownloaded,
    required this.totalBytes,
    required this.progress,
  });
}

/// Isolate entry point for download worker
void _downloadIsolateEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  final activeDownloads = <int, HttpClient>{};

  receivePort.listen((message) async {
    if (message is! DownloadMessage) return;

    switch (message.type) {
      case DownloadMessageType.start:
        await _handleDownload(message, mainSendPort, activeDownloads);
        break;

      case DownloadMessageType.cancel:
        final client = activeDownloads.remove(message.taskId);
        client?.close(force: true);
        break;

      default:
        break;
    }
  });
}

/// Handle a download request in the isolate
Future<void> _handleDownload(
  DownloadMessage message,
  SendPort mainSendPort,
  Map<int, HttpClient> activeDownloads,
) async {
  final taskId = message.taskId!;
  final url = message.url!;
  final filePath = message.filePath!;
  final headers = message.headers;

  try {
    final client = HttpClient();
    activeDownloads[taskId] = client;

    final request = await client.getUrl(Uri.parse(url));

    if (headers != null) {
      headers.forEach((key, value) => request.headers.set(key, value));
    }

    final response = await request.close();

    if (response.statusCode != 200 && response.statusCode != 206) {
      mainSendPort.send(DownloadMessage(
        type: DownloadMessageType.error,
        taskId: taskId,
        error: 'HTTP ${response.statusCode}',
      ));
      activeDownloads.remove(taskId);
      client.close();
      return;
    }

    final totalBytes = response.contentLength;
    final file = File(filePath);
    final sink = file.openWrite();

    int downloaded = 0;
    int lastProgressUpdate = 0;

    await for (final chunk in response) {
      sink.add(chunk);
      downloaded += chunk.length;

      // Send progress update every 64KB
      if (downloaded - lastProgressUpdate >= 65536) {
        mainSendPort.send(DownloadMessage(
          type: DownloadMessageType.progress,
          taskId: taskId,
          bytesDownloaded: downloaded,
          totalBytes: totalBytes,
        ));
        lastProgressUpdate = downloaded;
      }
    }

    await sink.close();
    activeDownloads.remove(taskId);
    client.close();

    mainSendPort.send(DownloadMessage(
      type: DownloadMessageType.complete,
      taskId: taskId,
      bytesDownloaded: downloaded,
      totalBytes: totalBytes,
    ));
  } catch (e) {
    activeDownloads.remove(taskId);
    mainSendPort.send(DownloadMessage(
      type: DownloadMessageType.error,
      taskId: taskId,
      error: e.toString(),
    ));
  }
}

/// Manager for isolate-based downloads
class DownloadIsolateManager {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  ReceivePort? _receivePort;

  final Map<int, IsolateDownloadTask> _tasks = {};
  int _nextTaskId = 0;

  bool _isInitialized = false;

  /// Initialize the download isolate
  Future<void> initialize() async {
    if (_isInitialized) return;

    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(
      _downloadIsolateEntry,
      _receivePort!.sendPort,
    );

    // Wait for the isolate to send its SendPort
    final completer = Completer<SendPort>();
    _receivePort!.listen((message) {
      if (message is SendPort && !completer.isCompleted) {
        completer.complete(message);
      } else if (message is DownloadMessage) {
        _handleIsolateMessage(message);
      }
    });

    _isolateSendPort = await completer.future;
    _isInitialized = true;

    debugPrint('DownloadIsolateManager: Initialized');
  }

  /// Handle messages from the download isolate
  void _handleIsolateMessage(DownloadMessage message) {
    final task = _tasks[message.taskId];
    if (task == null) return;

    switch (message.type) {
      case DownloadMessageType.progress:
        task._updateProgress(
          message.bytesDownloaded ?? 0,
          message.totalBytes ?? 0,
        );
        break;

      case DownloadMessageType.complete:
        task._updateProgress(
          message.bytesDownloaded ?? 0,
          message.totalBytes ?? 0,
        );
        task._complete();
        _tasks.remove(message.taskId);
        break;

      case DownloadMessageType.error:
        task._completeWithError(Exception(message.error));
        _tasks.remove(message.taskId);
        break;

      default:
        break;
    }
  }

  /// Start a download task
  Future<IsolateDownloadTask> download({
    required String url,
    required String filePath,
    Map<String, String>? headers,
    int priority = 0,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final taskId = _nextTaskId++;
    final task = IsolateDownloadTask(
      id: taskId,
      url: url,
      filePath: filePath,
      headers: headers,
      priority: priority,
    );

    _tasks[taskId] = task;

    _isolateSendPort!.send(DownloadMessage(
      type: DownloadMessageType.start,
      taskId: taskId,
      url: url,
      filePath: filePath,
      headers: headers,
    ));

    return task;
  }

  /// Cancel a download task
  void cancel(int taskId) {
    final task = _tasks[taskId];
    if (task == null) return;

    task.cancel();
    _isolateSendPort?.send(DownloadMessage(
      type: DownloadMessageType.cancel,
      taskId: taskId,
    ));

    _tasks.remove(taskId);
  }

  /// Cancel all active downloads
  void cancelAll() {
    for (final taskId in _tasks.keys.toList()) {
      cancel(taskId);
    }
  }

  /// Dispose the isolate manager
  void dispose() {
    cancelAll();
    _isolate?.kill();
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _isolateSendPort = null;
    _isInitialized = false;

    debugPrint('DownloadIsolateManager: Disposed');
  }

  /// Number of active downloads
  int get activeCount => _tasks.length;
}
