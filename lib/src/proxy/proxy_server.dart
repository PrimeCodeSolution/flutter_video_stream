import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../cache/cache_manager.dart';
import '../cache/mobile_cache_manager.dart';
import '../utils/http_utils.dart';
import 'hls_handler.dart';
import 'mp4_handler.dart';

/// Localhost HTTP proxy server for video streaming.
/// Intercepts video requests, serves from cache or fetches and caches.
class ProxyServer {
  HttpServer? _server;
  int _port = 0;
  final CacheManager _cacheManager;
  bool _isRunning = false;
  bool _isShuttingDown = false;

  /// Specialized handlers
  late final HlsHandler _hlsHandler;
  late final Mp4Handler _mp4Handler;

  /// Active download streams for play-while-download
  final Map<String, _DownloadStream> _activeDownloads = {};

  /// Cast to MobileCacheManager for memory cache access
  MobileCacheManager get _mobileCacheManager =>
      _cacheManager as MobileCacheManager;

  ProxyServer(
      {required CacheManager cacheManager,
      int chunkSize = Mp4Handler.defaultChunkSize})
      : _cacheManager = cacheManager {
    final mobileCacheManager = cacheManager as MobileCacheManager;
    _hlsHandler = HlsHandler(cacheManager: mobileCacheManager);
    _mp4Handler =
        Mp4Handler(cacheManager: mobileCacheManager, chunkSize: chunkSize);
  }

  /// Whether the proxy server is running
  bool get isRunning => _isRunning;

  /// The port the server is listening on
  int get port => _port;

  /// Start the proxy server on an available port
  Future<void> start() async {
    if (_isRunning) return;

    try {
      // Bind to localhost on any available port
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      _isRunning = true;

      debugPrint('ProxyServer: Started on http://127.0.0.1:$_port');

      // Handle incoming requests
      _server!.listen(
        _handleRequest,
        onError: (error) {
          debugPrint('ProxyServer: Error handling request: $error');
        },
      );
    } catch (e) {
      debugPrint('ProxyServer: Failed to start: $e');
      rethrow;
    }
  }

  /// Stop the proxy server
  Future<void> stop() async {
    if (!_isRunning) return;

    // Mark as shutting down to prevent new requests
    _isShuttingDown = true;

    // Cancel all active downloads (copy to avoid concurrent modification)
    final downloads = List.from(_activeDownloads.values);
    for (final download in downloads) {
      await download.cancel();
    }
    _activeDownloads.clear();

    // Dispose handlers
    _hlsHandler.dispose();
    _mp4Handler.dispose();

    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
    _isShuttingDown = false;
    _port = 0;

    debugPrint('ProxyServer: Stopped');
  }

  /// Convert an original URL to a proxy URL
  String getProxyUrl(String originalUrl) {
    if (!_isRunning) {
      debugPrint('ProxyServer: Not running, returning original URL');
      return originalUrl;
    }
    // Encode the original URL as a path parameter
    final encoded = Uri.encodeComponent(originalUrl);
    return 'http://127.0.0.1:$_port/video?url=$encoded';
  }

  /// Handle incoming proxy requests
  Future<void> _handleRequest(HttpRequest request) async {
    // Reject new requests during shutdown
    if (_isShuttingDown) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.write('Server shutting down');
      await request.response.close();
      return;
    }

    try {
      final uri = request.uri;
      final originalUrl = uri.queryParameters['url'];
      final headersParam = uri.queryParameters['headers'];

      if (originalUrl == null || originalUrl.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('Missing url parameter');
        await request.response.close();
        return;
      }

      // Parse optional headers from query param
      Map<String, String>? headers;
      if (headersParam != null && headersParam.isNotEmpty) {
        try {
          headers = Map<String, String>.from(
            Uri.splitQueryString(headersParam),
          );
        } catch (_) {}
      }

      debugPrint('ProxyServer: Request for $originalUrl');

      // Route to appropriate handler based on content type
      if (_hlsHandler.isHlsUrl(originalUrl)) {
        debugPrint('ProxyServer: Routing to HLS handler');
        await _hlsHandler.handlePlaylist(request, originalUrl, headers);
        return;
      }

      if (_hlsHandler.isHlsSegment(originalUrl)) {
        debugPrint('ProxyServer: Routing to HLS segment handler');
        await _hlsHandler.handleSegment(request, originalUrl, headers);
        return;
      }

      // For large MP4 files, use chunked handler
      // For smaller files or unknown, use standard handler
      if (_mp4Handler.isMp4Url(originalUrl)) {
        debugPrint('ProxyServer: Routing to MP4 handler');
        await _mp4Handler.handleRequest(request, originalUrl, headers);
        return;
      }

      // Standard handling for other content types
      await _handleStandardRequest(request, originalUrl, headers);
    } catch (e) {
      debugPrint('ProxyServer: Error handling request: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Standard request handling (for non-specialized content)
  Future<void> _handleStandardRequest(
    HttpRequest request,
    String originalUrl,
    Map<String, String>? headers,
  ) async {
    // Check memory cache first (fastest)
    final memoryData = _mobileCacheManager.getFromMemory(originalUrl);
    if (memoryData != null) {
      debugPrint('ProxyServer: Serving from memory cache');
      await _serveBytes(request, memoryData, originalUrl);
      return;
    }

    // Check disk cache
    final cachedPath = await _cacheManager.getCacheUrl(originalUrl);
    if (cachedPath != originalUrl && await File(cachedPath).exists()) {
      debugPrint('ProxyServer: Serving from disk cache');
      await _serveFile(request, File(cachedPath), originalUrl);
      return;
    }

    // Not cached - stream from network while caching
    await _streamFromNetwork(request, originalUrl);
  }

  /// Serve bytes from memory cache
  Future<void> _serveBytes(
      HttpRequest request, Uint8List data, String originalUrl) async {
    final response = request.response;
    final rangeHeader = request.headers.value('range');

    _setContentType(response, originalUrl);
    response.headers.set('Accept-Ranges', 'bytes');
    response.headers.set('Cache-Control', 'public, max-age=31536000');

    if (rangeHeader != null) {
      // Handle byte range request
      final range = _parseRange(rangeHeader, data.length);
      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set('Content-Range',
            'bytes ${range.start}-${range.end}/${data.length}');
        response.headers.contentLength = range.end - range.start + 1;
        response.add(data.sublist(range.start, range.end + 1));
      } else {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('Content-Range', 'bytes */${data.length}');
      }
    } else {
      response.headers.contentLength = data.length;
      response.add(data);
    }

    await response.close();
  }

  /// Serve file from disk cache
  Future<void> _serveFile(
      HttpRequest request, File file, String originalUrl) async {
    final response = request.response;
    final fileLength = await file.length();
    final rangeHeader = request.headers.value('range');

    _setContentType(response, originalUrl);
    response.headers.set('Accept-Ranges', 'bytes');
    response.headers.set('Cache-Control', 'public, max-age=31536000');

    if (rangeHeader != null) {
      final range = _parseRange(rangeHeader, fileLength);
      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
            'Content-Range', 'bytes ${range.start}-${range.end}/$fileLength');
        response.headers.contentLength = range.end - range.start + 1;

        final stream = file.openRead(range.start, range.end + 1);
        await response.addStream(stream);
      } else {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('Content-Range', 'bytes */$fileLength');
      }
    } else {
      response.headers.contentLength = fileLength;
      await response.addStream(file.openRead());
    }

    await response.close();
  }

  /// Stream from network while caching (play-while-download)
  Future<void> _streamFromNetwork(
      HttpRequest request, String originalUrl) async {
    final response = request.response;

    // Don't start new downloads during shutdown
    if (_isShuttingDown) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }

    try {
      // Check if we already have an active download for this URL
      var download = _activeDownloads[originalUrl];
      if (download == null) {
        // Start new download
        download = _DownloadStream(originalUrl);
        _activeDownloads[originalUrl] = download;
        await download.start();
      }

      // Get content info from the download
      final contentLength = download.contentLength;
      final contentType = download.contentType;

      if (contentType != null) {
        response.headers.contentType = ContentType.parse(contentType);
      } else {
        _setContentType(response, originalUrl);
      }
      response.headers.set('Accept-Ranges', 'bytes');

      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null && contentLength != null && contentLength > 0) {
        // Handle range request for in-progress download
        final range = _parseRange(rangeHeader, contentLength);
        if (range != null) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set('Content-Range',
              'bytes ${range.start}-${range.end}/$contentLength');
          response.headers.contentLength = range.end - range.start + 1;

          // Stream the requested range
          await download.streamRange(response, range.start, range.end);
        } else {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set('Content-Range', 'bytes */$contentLength');
        }
      } else {
        // Stream entire content
        if (contentLength != null && contentLength > 0) {
          response.headers.contentLength = contentLength;
        }
        await download.streamAll(response);
      }

      await response.close();

      // If download completed successfully, trigger caching
      if (download.isComplete && !download.hasError) {
        _activeDownloads.remove(originalUrl);
        // The download stream already saved to disk
      }
    } catch (e) {
      debugPrint('ProxyServer: Error streaming from network: $e');
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
  }

  /// Set content type based on URL extension
  void _setContentType(HttpResponse response, String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.mp4')) {
      response.headers.contentType = ContentType('video', 'mp4');
    } else if (lower.contains('.webm')) {
      response.headers.contentType = ContentType('video', 'webm');
    } else if (lower.contains('.mov')) {
      response.headers.contentType = ContentType('video', 'quicktime');
    } else if (lower.contains('.m3u8')) {
      response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
    } else if (lower.contains('.ts')) {
      response.headers.contentType = ContentType('video', 'mp2t');
    } else {
      response.headers.contentType = ContentType('application', 'octet-stream');
    }
  }

  /// Parse HTTP Range header using shared utility
  _ByteRange? _parseRange(String rangeHeader, int totalLength) {
    final range = HttpUtils.parseRange(rangeHeader, totalLength);
    if (range == null) return null;
    return _ByteRange(range.$1, range.$2);
  }
}

/// Byte range for partial content
class _ByteRange {
  final int start;
  final int end;

  _ByteRange(this.start, this.end);
}

/// Manages streaming download with play-while-download support
class _DownloadStream {
  final String url;
  HttpClient? _client;
  HttpClientResponse? _response;
  StreamSubscription<List<int>>? _responseSubscription;

  /// Maximum buffer size to prevent OOM (50MB)
  static const int _maxBufferSize = 50 * 1024 * 1024;

  /// Timeout for waiting on data during streaming (30 seconds)
  static const Duration _streamTimeout = Duration(seconds: 30);

  final List<int> _buffer = [];
  int? contentLength;
  String? contentType;
  bool isComplete = false;
  bool hasError = false;

  /// Tracks if buffer overflowed (data was dropped due to size limit)
  bool _bufferOverflowed = false;

  final _dataController = StreamController<List<int>>.broadcast();
  final Completer<void> _startCompleter = Completer();

  /// Completer that fires when new data arrives (for non-polling waiting)
  Completer<void>? _dataArrivedCompleter;

  _DownloadStream(this.url);

  /// Start the download
  Future<void> start() async {
    try {
      _client = HttpClient();
      final request = await _client!.getUrl(Uri.parse(url));
      _response = await request.close();

      if (_response!.statusCode != 200) {
        hasError = true;
        _startCompleter.complete();
        return;
      }

      contentLength = _response!.contentLength;
      contentType = _response!.headers.contentType?.toString();

      _startCompleter.complete();

      // Start buffering data - store subscription so it can be cancelled
      _responseSubscription = _response!.listen(
        (chunk) {
          // Only buffer up to max size to prevent OOM
          if (_buffer.length < _maxBufferSize) {
            _buffer.addAll(chunk);
          } else {
            _bufferOverflowed = true;
          }
          _dataController.add(chunk);
          // Signal that new data has arrived (with race condition fix)
          final completer = _dataArrivedCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete();
          }
          _dataArrivedCompleter = null;
        },
        onDone: () {
          isComplete = true;
          // Cancel subscription to release resources
          _responseSubscription?.cancel();
          _responseSubscription = null;
          _dataController.close();
          // Signal completion to any waiters (with race condition fix)
          final completer = _dataArrivedCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete();
          }
          _dataArrivedCompleter = null;
        },
        onError: (e) {
          hasError = true;
          // Cancel subscription to release resources
          _responseSubscription?.cancel();
          _responseSubscription = null;
          _dataController.addError(e);
          _dataController.close();
          // Signal error to any waiters (with race condition fix)
          final completer = _dataArrivedCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete();
          }
          _dataArrivedCompleter = null;
        },
      );
    } catch (e) {
      hasError = true;
      _startCompleter.complete();
      if (!_dataController.isClosed) {
        await _dataController.close();
      }
      debugPrint('_DownloadStream: Error starting download: $e');
    }
  }

  /// Wait for the download to be ready
  Future<void> get ready => _startCompleter.future;

  /// Stream all buffered and incoming data
  Future<void> streamAll(HttpResponse response) async {
    await ready;

    // First send buffered data
    if (_buffer.isNotEmpty) {
      response.add(Uint8List.fromList(_buffer));
    }

    // Then stream new data as it arrives (with timeout between chunks)
    if (!isComplete && !hasError) {
      await for (final chunk in _dataController.stream.timeout(
        _streamTimeout,
        onTimeout: (sink) {
          sink.addError(TimeoutException('Stream stalled - no data received'));
          sink.close();
        },
      )) {
        response.add(chunk);
      }
    }
  }

  /// Stream a specific byte range
  Future<void> streamRange(HttpResponse response, int start, int end) async {
    await ready;

    final length = end - start + 1;
    int sent = 0;

    // Wait for enough data using fresh Completer for each wait cycle
    while (_buffer.length < end + 1 && !isComplete && !hasError && !_bufferOverflowed) {
      final completer = Completer<void>();
      _dataArrivedCompleter = completer;
      try {
        await completer.future.timeout(_streamTimeout);
      } on TimeoutException {
        throw Exception('Timeout waiting for data: buffer has ${_buffer.length} bytes, need ${end + 1}');
      }
    }

    // Check if buffer overflow prevents serving the requested range
    if (_bufferOverflowed && start >= _buffer.length) {
      throw Exception('Buffer overflow: requested range $start-$end not available (buffer size: ${_buffer.length})');
    }

    // Send from buffer
    final available = _buffer.length.clamp(0, end + 1);
    if (start < available) {
      final chunk = _buffer.sublist(start, available);
      response.add(Uint8List.fromList(chunk));
      sent += chunk.length;
    }

    // If we need more data, wait for it
    if (sent < length && !isComplete && !hasError) {
      await for (final chunk in _dataController.stream) {
        if (sent >= length) break;
        final needed = length - sent;
        final toSend = chunk.length > needed ? chunk.sublist(0, needed) : chunk;
        response.add(toSend);
        sent += toSend.length;
      }
    }
  }

  /// Cancel the download
  Future<void> cancel() async {
    await _responseSubscription?.cancel();
    _responseSubscription = null;
    _client?.close(force: true);
    _client = null;
    if (!_dataController.isClosed) {
      await _dataController.close();
    }
    // Complete any pending waiters (with race condition fix)
    final completer = _dataArrivedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _dataArrivedCompleter = null;
  }
}
