import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'download_isolate.dart';
import '../lifecycle/lifecycle_observer.dart';

/// Priority-based download manager with isolate support.
/// Manages concurrent downloads with prioritization.
class DownloadManager with LifecycleAware {
  final int maxConcurrent;
  final bool useIsolates;

  DownloadIsolateManager? _isolateManager;
  Directory? _cacheDir;

  /// Reusable HttpClient for direct downloads
  HttpClient? _httpClient;

  /// Queue of pending downloads, sorted by priority
  final Queue<_QueuedDownload> _queue = Queue();

  /// Active downloads
  final Map<String, _ActiveDownload> _activeDownloads = {};

  /// Completed downloads cache (URL -> file path)
  final Map<String, String> _completedCache = {};

  bool _isInitialized = false;
  bool _isPaused = false;

  DownloadManager({
    this.maxConcurrent = 3,
    this.useIsolates = true,
  });

  /// Get or create reusable HttpClient
  HttpClient get _client {
    _httpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    return _httpClient!;
  }

  /// Initialize the download manager
  Future<void> initialize() async {
    if (_isInitialized) return;

    _cacheDir = await getTemporaryDirectory();

    if (useIsolates && !kIsWeb) {
      _isolateManager = DownloadIsolateManager();
      await _isolateManager!.initialize();
    }

    _isInitialized = true;
    debugPrint('DownloadManager: Initialized (useIsolates: $useIsolates)');
  }

  /// Enqueue a download with priority
  Future<DownloadHandle> enqueue({
    required String url,
    Map<String, String>? headers,
    int priority = 0,
    void Function(double progress)? onProgress,
    void Function(String filePath)? onComplete,
    void Function(Object error)? onError,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    // Check if already completed
    if (_completedCache.containsKey(url)) {
      final filePath = _completedCache[url]!;
      if (await File(filePath).exists()) {
        onProgress?.call(1.0);
        onComplete?.call(filePath);
        return DownloadHandle._(
          url: url,
          manager: this,
          isComplete: true,
        );
      }
    }

    // Check if already downloading
    if (_activeDownloads.containsKey(url)) {
      final active = _activeDownloads[url]!;
      if (onProgress != null) {
        active.addProgressCallback(onProgress);
      }
      if (onComplete != null) {
        active.addCompleteCallback(onComplete);
      }
      if (onError != null) {
        active.addErrorCallback(onError);
      }
      return DownloadHandle._(url: url, manager: this);
    }

    // Check if already in queue
    final existingQueued = _queue.where((q) => q.url == url).firstOrNull;
    if (existingQueued != null) {
      // Update priority if higher
      if (priority > existingQueued.priority) {
        existingQueued.priority = priority;
      }
      if (onProgress != null) {
        existingQueued.addProgressCallback(onProgress);
      }
      if (onComplete != null) {
        existingQueued.addCompleteCallback(onComplete);
      }
      if (onError != null) {
        existingQueued.addErrorCallback(onError);
      }
      return DownloadHandle._(url: url, manager: this);
    }

    // Add to queue
    final queued = _QueuedDownload(
      url: url,
      headers: headers,
      priority: priority,
      filePath: _getFilePath(url),
    );

    if (onProgress != null) {
      queued.addProgressCallback(onProgress);
    }
    if (onComplete != null) {
      queued.addCompleteCallback(onComplete);
    }
    if (onError != null) {
      queued.addErrorCallback(onError);
    }

    _queue.add(queued);
    _processQueue();

    return DownloadHandle._(url: url, manager: this);
  }

  /// Process the download queue
  void _processQueue() {
    // Don't start new downloads when paused
    if (_isPaused) {
      debugPrint('DownloadManager: Paused - not starting new downloads');
      return;
    }

    while (_activeDownloads.length < maxConcurrent && _queue.isNotEmpty) {
      // Sort queue by priority (highest first)
      final sorted = _queue.toList()
        ..sort((a, b) => b.priority.compareTo(a.priority));

      if (sorted.isEmpty) break;

      final next = sorted.first;
      _queue.remove(next);

      _startDownload(next);
    }
  }

  /// Start a download
  Future<void> _startDownload(_QueuedDownload queued) async {
    final active = _ActiveDownload(
      url: queued.url,
      filePath: queued.filePath,
      progressCallbacks: queued.progressCallbacks,
      completeCallbacks: queued.completeCallbacks,
      errorCallbacks: queued.errorCallbacks,
    );

    _activeDownloads[queued.url] = active;

    try {
      if (_isolateManager != null && useIsolates) {
        // Use isolate for download
        final task = await _isolateManager!.download(
          url: queued.url,
          filePath: queued.filePath,
          headers: queued.headers,
        );

        active.isolateTask = task;

        // Listen for progress - store subscription so it can be cancelled
        active.progressSubscription = task.progressStream.listen((progress) {
          for (final callback in active.progressCallbacks) {
            callback(progress.progress);
          }
        });

        // Wait for completion
        await task.future;

        if (!task.isCancelled) {
          _onDownloadComplete(queued.url, queued.filePath);
        }
      } else {
        // Direct download (main thread)
        await _downloadDirect(
            queued.url, queued.filePath, queued.headers, active);
        _onDownloadComplete(queued.url, queued.filePath);
      }
    } catch (e) {
      _onDownloadError(queued.url, e);
    }
  }

  /// Direct download without isolate
  Future<void> _downloadDirect(
    String url,
    String filePath,
    Map<String, String>? headers,
    _ActiveDownload active,
  ) async {
    // Use shared HttpClient for efficiency
    final request = await _client.getUrl(Uri.parse(url));

    if (headers != null) {
      headers.forEach((key, value) => request.headers.set(key, value));
    }

    final response = await request.close();

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('HTTP ${response.statusCode}');
    }

    final totalBytes = response.contentLength;
    final file = File(filePath);
    final sink = file.openWrite();

    int downloaded = 0;
    int lastProgressUpdate = 0;

    try {
      await for (final chunk in response) {
        if (active.isCancelled) {
          throw Exception('Download cancelled');
        }

        sink.add(chunk);
        downloaded += chunk.length;

        // Update progress every 64KB
        if (downloaded - lastProgressUpdate >= 65536) {
          final progress = totalBytes > 0 ? downloaded / totalBytes : 0.0;
          for (final callback in active.progressCallbacks) {
            callback(progress);
          }
          lastProgressUpdate = downloaded;
        }
      }
    } finally {
      await sink.close();
      if (active.isCancelled && await file.exists()) {
        await file.delete();
      }
    }
  }

  /// Handle download completion
  void _onDownloadComplete(String url, String filePath) {
    final active = _activeDownloads.remove(url);
    if (active == null) return;

    _completedCache[url] = filePath;

    for (final callback in active.progressCallbacks) {
      callback(1.0);
    }

    for (final callback in active.completeCallbacks) {
      callback(filePath);
    }

    _processQueue();
  }

  /// Handle download error
  void _onDownloadError(String url, Object error) {
    final active = _activeDownloads.remove(url);
    if (active == null) return;

    for (final callback in active.errorCallbacks) {
      callback(error);
    }

    _processQueue();
  }

  /// Cancel a download
  void cancel(String url) {
    // Check queue
    _queue.removeWhere((q) => q.url == url);

    // Check active
    final active = _activeDownloads[url];
    if (active != null) {
      active.isCancelled = true;
      active.progressSubscription?.cancel();
      active.isolateTask?.cancel();
      _activeDownloads.remove(url);
    }
  }

  /// Cancel all downloads
  void cancelAll() {
    _queue.clear();

    for (final active in _activeDownloads.values) {
      active.isCancelled = true;
      active.progressSubscription?.cancel();
      active.isolateTask?.cancel();
    }
    _activeDownloads.clear();
  }

  /// Get the file extension from a URL using proper URL parsing.
  String _getExtension(String url) {
    try {
      final path = Uri.parse(url).path.toLowerCase();
      if (path.endsWith('.mp4')) return '.mp4';
      if (path.endsWith('.mov')) return '.mov';
      if (path.endsWith('.ts')) return '.ts';
      if (path.endsWith('.m4s')) return '.m4s';
      if (path.endsWith('.m3u8')) return '.m3u8';
      if (path.endsWith('.webm')) return '.webm';
      return '';
    } catch (_) {
      return '';
    }
  }

  /// Get file path for a URL
  String _getFilePath(String url) {
    final bytes = utf8.encode(url);
    final digest = sha256.convert(bytes);
    final fileName = digest.toString();
    final extension = _getExtension(url);

    return '${_cacheDir!.path}/$fileName$extension';
  }

  /// Check if a URL is completed
  Future<bool> isCompleted(String url) async {
    if (_completedCache.containsKey(url)) {
      final file = File(_completedCache[url]!);
      return await file.exists();
    }
    return false;
  }

  /// Get completed file path for a URL
  String? getCompletedPath(String url) => _completedCache[url];

  // ============ Lifecycle Methods ============

  @override
  void onPaused() {
    if (_isPaused) return;
    _isPaused = true;
    debugPrint('DownloadManager: Paused (app in background) - ${_activeDownloads.length} active, ${_queue.length} queued');
  }

  @override
  void onResumed() {
    if (!_isPaused) return;
    _isPaused = false;
    debugPrint('DownloadManager: Resumed (app in foreground)');
    // Resume processing queued downloads
    _processQueue();
  }

  /// Whether downloading is currently paused.
  bool get isPaused => _isPaused;

  /// Dispose the download manager
  void dispose() {
    cancelAll();
    _httpClient?.close();
    _httpClient = null;
    _isolateManager?.dispose();
    _isInitialized = false;

    // Unregister from lifecycle observer
    VideoStreamLifecycleObserver.instance.removeListener(this);

    debugPrint('DownloadManager: Disposed');
  }

  /// Number of active downloads
  int get activeCount => _activeDownloads.length;

  /// Number of queued downloads
  int get queuedCount => _queue.length;
}

/// Handle for a queued/active download
class DownloadHandle {
  final String url;
  final DownloadManager _manager;
  final bool isComplete;

  DownloadHandle._({
    required this.url,
    required DownloadManager manager,
    this.isComplete = false,
  }) : _manager = manager;

  /// Cancel this download
  void cancel() => _manager.cancel(url);
}

/// Queued download waiting to start
class _QueuedDownload {
  /// Maximum callbacks per download to prevent unbounded growth
  static const int _maxCallbacks = 10;

  final String url;
  final String filePath;
  final Map<String, String>? headers;
  int priority;

  final List<void Function(double)> progressCallbacks = [];
  final List<void Function(String)> completeCallbacks = [];
  final List<void Function(Object)> errorCallbacks = [];

  _QueuedDownload({
    required this.url,
    required this.filePath,
    this.headers,
    this.priority = 0,
  });

  void addProgressCallback(void Function(double) callback) {
    if (progressCallbacks.length < _maxCallbacks) {
      progressCallbacks.add(callback);
    }
  }

  void addCompleteCallback(void Function(String) callback) {
    if (completeCallbacks.length < _maxCallbacks) {
      completeCallbacks.add(callback);
    }
  }

  void addErrorCallback(void Function(Object) callback) {
    if (errorCallbacks.length < _maxCallbacks) {
      errorCallbacks.add(callback);
    }
  }
}

/// Active download in progress
class _ActiveDownload {
  /// Maximum callbacks per download to prevent unbounded growth
  static const int _maxCallbacks = 10;

  final String url;
  final String filePath;
  final List<void Function(double)> progressCallbacks;
  final List<void Function(String)> completeCallbacks;
  final List<void Function(Object)> errorCallbacks;

  IsolateDownloadTask? isolateTask;
  StreamSubscription<DownloadProgress>? progressSubscription;
  bool isCancelled = false;

  _ActiveDownload({
    required this.url,
    required this.filePath,
    required this.progressCallbacks,
    required this.completeCallbacks,
    required this.errorCallbacks,
  });

  void addProgressCallback(void Function(double) callback) {
    if (progressCallbacks.length < _maxCallbacks) {
      progressCallbacks.add(callback);
    }
  }

  void addCompleteCallback(void Function(String) callback) {
    if (completeCallbacks.length < _maxCallbacks) {
      completeCallbacks.add(callback);
    }
  }

  void addErrorCallback(void Function(Object) callback) {
    if (errorCallbacks.length < _maxCallbacks) {
      errorCallbacks.add(callback);
    }
  }
}
