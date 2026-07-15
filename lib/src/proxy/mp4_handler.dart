import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../cache/mobile_cache_manager.dart';
import '../utils/http_utils.dart';

/// Handler for MP4 video streaming with chunked caching.
/// Splits large MP4 files into chunks for efficient caching and seeking.
///
/// Handles edge cases:
/// - Missing Content-Length (chunked transfer encoding)
/// - Servers that don't support Range requests
/// - Corrupted or incomplete files
/// - Live/endless streams
class Mp4Handler {
  final MobileCacheManager _cacheManager;

  /// Default chunk size: 2MB
  static const int defaultChunkSize = 2 * 1024 * 1024;

  final int chunkSize;

  /// Shared HttpClient for all requests
  HttpClient? _httpClient;

  /// Track chunk download status per URL
  final Map<String, _Mp4ChunkInfo> _chunkInfos = {};

  /// Track URLs that require passthrough (no caching)
  final Set<String> _passthroughUrls = {};

  Mp4Handler({
    required MobileCacheManager cacheManager,
    this.chunkSize = defaultChunkSize,
  }) : _cacheManager = cacheManager;

  /// Get or create the shared HttpClient
  HttpClient get _client {
    _httpClient ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);
    return _httpClient!;
  }

  /// Check if a URL is an MP4 file
  bool isMp4Url(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp4') || lower.contains('video/mp4');
  }

  /// Handle an MP4 request with chunked caching
  Future<void> handleRequest(
    HttpRequest request,
    String originalUrl,
    Map<String, String>? headers,
  ) async {
    final response = request.response;

    try {
      // Check if this URL requires passthrough mode
      if (_passthroughUrls.contains(originalUrl)) {
        await _handlePassthrough(request, originalUrl, headers);
        return;
      }

      // Get or create chunk info for this URL
      var chunkInfo = _chunkInfos[originalUrl];
      if (chunkInfo == null) {
        chunkInfo = await _initChunkInfo(originalUrl, headers);
        if (chunkInfo == null) {
          // Fallback to passthrough mode
          debugPrint('Mp4Handler: No metadata available, using passthrough mode for $originalUrl');
          _passthroughUrls.add(originalUrl);
          await _handlePassthrough(request, originalUrl, headers);
          return;
        }
        _chunkInfos[originalUrl] = chunkInfo;
      }

      // Set response headers
      response.headers.contentType = ContentType('video', 'mp4');
      response.headers.set('Accept-Ranges', 'bytes');
      response.headers.set('Cache-Control', 'public, max-age=31536000');

      // Parse range request
      final rangeHeader = request.headers.value('range');
      int startByte = 0;
      int endByte = chunkInfo.contentLength - 1;

      if (rangeHeader != null) {
        final range = _parseRange(rangeHeader, chunkInfo.contentLength);
        if (range != null) {
          startByte = range.$1;
          endByte = range.$2;
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            'Content-Range',
            'bytes $startByte-$endByte/${chunkInfo.contentLength}',
          );
        } else {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers
              .set('Content-Range', 'bytes */${chunkInfo.contentLength}');
          await response.close();
          return;
        }
      }

      response.headers.contentLength = endByte - startByte + 1;

      // Stream the requested range using chunks
      await _streamRange(
          response, chunkInfo, originalUrl, startByte, endByte, headers);
      await response.close();
    } catch (e) {
      debugPrint('Mp4Handler: Error handling request: $e');

      // Try passthrough as last resort
      if (!_passthroughUrls.contains(originalUrl)) {
        debugPrint('Mp4Handler: Attempting passthrough fallback');
        _passthroughUrls.add(originalUrl);
        try {
          await _handlePassthrough(request, originalUrl, headers);
          return;
        } catch (e2) {
          debugPrint('Mp4Handler: Passthrough also failed: $e2');
        }
      }

      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  /// Handle passthrough streaming without caching
  /// Used when metadata is unavailable (chunked transfer, no Content-Length, etc.)
  Future<void> _handlePassthrough(
    HttpRequest request,
    String originalUrl,
    Map<String, String>? headers,
  ) async {
    final response = request.response;

    try {
      debugPrint('Mp4Handler: Passthrough mode for $originalUrl');

      final upstreamRequest = await _client.getUrl(Uri.parse(originalUrl));

      // Copy headers
      if (headers != null) {
        headers.forEach((key, value) => upstreamRequest.headers.set(key, value));
      }

      // Forward range header if present
      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null) {
        upstreamRequest.headers.set('Range', rangeHeader);
      }

      final upstreamResponse = await upstreamRequest.close();

      // Copy status code
      response.statusCode = upstreamResponse.statusCode;

      // Copy relevant headers
      response.headers.contentType = ContentType('video', 'mp4');

      final contentLength = upstreamResponse.contentLength;
      if (contentLength > 0) {
        response.headers.contentLength = contentLength;
      }

      final contentRange = upstreamResponse.headers.value('content-range');
      if (contentRange != null) {
        response.headers.set('Content-Range', contentRange);
      }

      final acceptRanges = upstreamResponse.headers.value('accept-ranges');
      if (acceptRanges != null) {
        response.headers.set('Accept-Ranges', acceptRanges);
      }

      // Stream data directly
      await for (final chunk in upstreamResponse) {
        response.add(chunk);
      }

      await response.close();
      debugPrint('Mp4Handler: Passthrough complete for $originalUrl');
    } catch (e) {
      debugPrint('Mp4Handler: Passthrough error: $e');
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
  }

  /// Initialize chunk info by fetching content length
  /// Returns null if content length cannot be determined (triggers passthrough)
  Future<_Mp4ChunkInfo?> _initChunkInfo(
    String url,
    Map<String, String>? headers,
  ) async {
    // Try HEAD request first
    var chunkInfo = await _initChunkInfoViaHead(url, headers);
    if (chunkInfo != null) return chunkInfo;

    // Fallback: Try GET with Range 0-0
    chunkInfo = await _initChunkInfoViaGet(url, headers);
    if (chunkInfo != null) return chunkInfo;

    // Fallback: Try to detect from first chunk of actual content
    chunkInfo = await _initChunkInfoViaProbe(url, headers);
    if (chunkInfo != null) return chunkInfo;

    // All methods failed - will use passthrough
    debugPrint('Mp4Handler: Could not determine content length for $url');
    return null;
  }

  /// Try to get content length via HEAD request
  Future<_Mp4ChunkInfo?> _initChunkInfoViaHead(
    String url,
    Map<String, String>? headers,
  ) async {
    try {
      final request = await _client.headUrl(Uri.parse(url));

      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }

      final response = await request.close();
      await response.drain<void>();

      if (response.statusCode != 200 && response.statusCode != 206) {
        debugPrint('Mp4Handler: HEAD request failed: ${response.statusCode}');
        return null;
      }

      final contentLength = response.contentLength;
      if (contentLength <= 0) {
        debugPrint('Mp4Handler: HEAD returned no Content-Length');
        return null;
      }

      return _createChunkInfo(contentLength, url);
    } catch (e) {
      debugPrint('Mp4Handler: HEAD request error: $e');
      return null;
    }
  }

  /// Fallback: get content length via GET with Range header
  Future<_Mp4ChunkInfo?> _initChunkInfoViaGet(
    String url,
    Map<String, String>? headers,
  ) async {
    try {
      final request = await _client.getUrl(Uri.parse(url));

      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }
      request.headers.set('Range', 'bytes=0-0');

      final response = await request.close();

      // Check header before draining
      final contentRange = response.headers.value('content-range');

      // Drain the response body
      await response.drain<void>();

      if (response.statusCode != 206) {
        debugPrint('Mp4Handler: Server does not support Range requests');
        return null;
      }

      // Parse Content-Range header: bytes 0-0/total
      if (contentRange == null) {
        debugPrint('Mp4Handler: No Content-Range header in response');
        return null;
      }

      final match = RegExp(r'bytes \d+-\d+/(\d+|\*)').firstMatch(contentRange);
      if (match == null) {
        debugPrint('Mp4Handler: Could not parse Content-Range: $contentRange');
        return null;
      }

      final totalStr = match.group(1)!;
      if (totalStr == '*') {
        // Unknown total length
        debugPrint('Mp4Handler: Content-Range has unknown total (*)');
        return null;
      }

      final contentLength = int.parse(totalStr);
      return _createChunkInfo(contentLength, url);
    } catch (e) {
      debugPrint('Mp4Handler: Range GET error: $e');
      return null;
    }
  }

  /// Last resort: probe the stream to estimate content length
  /// Downloads first chunk and checks for moov atom hints
  Future<_Mp4ChunkInfo?> _initChunkInfoViaProbe(
    String url,
    Map<String, String>? headers,
  ) async {
    try {
      final request = await _client.getUrl(Uri.parse(url));

      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }

      final response = await request.close();

      // Check for chunked transfer encoding. The body is abandoned (not
      // drained): draining would download the entire video just to probe.
      final transferEncoding = response.headers.value('transfer-encoding');
      if (transferEncoding?.toLowerCase() == 'chunked') {
        debugPrint('Mp4Handler: Chunked transfer encoding detected');
        // Can't determine length, will use passthrough
        await _abandonBody(response);
        return null;
      }

      // Check if Content-Length came with the GET response
      final contentLength = response.contentLength;
      if (contentLength > 0) {
        await _abandonBody(response);
        return _createChunkInfo(contentLength, url);
      }

      // No way to determine length
      await _abandonBody(response);
      return null;
    } catch (e) {
      debugPrint('Mp4Handler: Probe error: $e');
      return null;
    }
  }

  /// Create chunk info from content length
  _Mp4ChunkInfo _createChunkInfo(int contentLength, String url) {
    final numChunks = (contentLength / chunkSize).ceil();

    debugPrint('Mp4Handler: Initialized chunk info for $url');
    debugPrint('  Content-Length: $contentLength');
    debugPrint('  Chunks: $numChunks x $chunkSize bytes');

    return _Mp4ChunkInfo(
      contentLength: contentLength,
      chunkSize: chunkSize,
      numChunks: numChunks,
    );
  }

  /// Stream a range of bytes using cached chunks
  Future<void> _streamRange(
    HttpResponse response,
    _Mp4ChunkInfo chunkInfo,
    String originalUrl,
    int startByte,
    int endByte,
    Map<String, String>? headers,
  ) async {
    // Calculate which chunks we need
    final startChunk = startByte ~/ chunkInfo.chunkSize;
    final endChunk = endByte ~/ chunkInfo.chunkSize;

    for (var i = startChunk; i <= endChunk; i++) {
      final chunkData = await _getChunk(chunkInfo, originalUrl, i, headers);
      if (chunkData == null) {
        // Chunk failed - try to recover with direct stream for remaining data
        debugPrint('Mp4Handler: Chunk $i failed, switching to direct stream');
        await _streamRangeDirect(response, originalUrl,
            i * chunkInfo.chunkSize + (i == startChunk ? startByte % chunkInfo.chunkSize : 0),
            endByte, headers);
        return;
      }

      // Calculate byte range within this chunk
      final chunkStart = i * chunkInfo.chunkSize;

      int sliceStart = 0;
      int sliceEnd = chunkData.length;

      if (i == startChunk) {
        sliceStart = startByte - chunkStart;
      }
      if (i == endChunk) {
        sliceEnd = (endByte - chunkStart) + 1;
      }

      // Clamp to valid range
      sliceStart = sliceStart.clamp(0, chunkData.length);
      sliceEnd = sliceEnd.clamp(0, chunkData.length);

      if (sliceEnd > sliceStart) {
        response.add(chunkData.sublist(sliceStart, sliceEnd));
      }
    }
  }

  /// Direct stream for recovery when chunked caching fails
  Future<void> _streamRangeDirect(
    HttpResponse response,
    String originalUrl,
    int startByte,
    int endByte,
    Map<String, String>? headers,
  ) async {
    try {
      final request = await _client.getUrl(Uri.parse(originalUrl));

      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }
      request.headers.set('Range', 'bytes=$startByte-$endByte');

      final upstreamResponse = await request.close();

      if (upstreamResponse.statusCode == HttpStatus.partialContent) {
        // Server honored the range
        await for (final chunk in upstreamResponse) {
          response.add(chunk);
        }
        return;
      }

      if (upstreamResponse.statusCode == HttpStatus.ok) {
        // Server ignored the Range header and is sending the whole file:
        // deliver only the requested slice so the client still receives
        // exactly the bytes it asked for.
        var position = 0;
        await for (final chunk in upstreamResponse) {
          final chunkStart = position;
          position += chunk.length;
          if (position <= startByte) continue;
          final from = (startByte - chunkStart).clamp(0, chunk.length);
          final to = (endByte - chunkStart + 1).clamp(0, chunk.length);
          if (to > from) {
            response.add(chunk.sublist(from, to));
          }
          if (position > endByte) break;
        }
        return;
      }

      await upstreamResponse.drain<void>();
      throw HttpException(
          'Direct stream failed: ${upstreamResponse.statusCode}',
          uri: Uri.parse(originalUrl));
    } catch (e) {
      debugPrint('Mp4Handler: Direct stream failed: $e');
      rethrow;
    }
  }

  /// Abandon a response body without downloading the rest of it.
  Future<void> _abandonBody(HttpClientResponse response) async {
    try {
      await response.listen((_) {}).cancel();
    } catch (_) {}
  }

  /// Get a specific chunk, from cache or download
  Future<Uint8List?> _getChunk(
    _Mp4ChunkInfo chunkInfo,
    String originalUrl,
    int chunkIndex,
    Map<String, String>? headers,
  ) async {
    final chunkKey = _getChunkKey(originalUrl, chunkIndex);

    // Check memory cache
    final memoryData = _cacheManager.getFromMemory(chunkKey);
    if (memoryData != null) {
      return memoryData;
    }

    // Check disk cache
    final cachedPath = await _cacheManager.getCacheUrl(chunkKey);
    if (cachedPath != chunkKey && await File(cachedPath).exists()) {
      final file = File(cachedPath);
      try {
        return await file.readAsBytes();
      } catch (e) {
        debugPrint('Mp4Handler: Error reading cached chunk: $e');
        // Continue to download
      }
    }

    // Download the chunk
    return await _downloadChunk(chunkInfo, originalUrl, chunkIndex, headers);
  }

  /// Download a specific chunk using Range header
  Future<Uint8List?> _downloadChunk(
    _Mp4ChunkInfo chunkInfo,
    String originalUrl,
    int chunkIndex,
    Map<String, String>? headers,
  ) async {
    final chunkStart = chunkIndex * chunkInfo.chunkSize;
    var chunkEnd = ((chunkIndex + 1) * chunkInfo.chunkSize) - 1;

    // Don't exceed content length
    if (chunkEnd >= chunkInfo.contentLength) {
      chunkEnd = chunkInfo.contentLength - 1;
    }

    debugPrint(
        'Mp4Handler: Downloading chunk $chunkIndex ($chunkStart-$chunkEnd)');

    try {
      final request = await _client.getUrl(Uri.parse(originalUrl));

      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }
      request.headers.set('Range', 'bytes=$chunkStart-$chunkEnd');

      final response = await request.close();

      if (response.statusCode == HttpStatus.ok) {
        // Server ignored the Range header: chunked caching would store
        // whole-file bytes at chunk offsets and corrupt playback. Flip
        // this URL to passthrough; the direct-stream recovery path serves
        // the current request correctly.
        debugPrint(
            'Mp4Handler: Server ignored Range for $originalUrl, switching to passthrough');
        _passthroughUrls.add(originalUrl);
        _chunkInfos.remove(originalUrl);
        await _abandonBody(response);
        return null;
      }

      if (response.statusCode != 206) {
        debugPrint('Mp4Handler: Chunk download failed: ${response.statusCode}');
        await response.drain<void>();
        return null;
      }

      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }

      final data = Uint8List.fromList(bytes);

      // Validate chunk size (allow some tolerance for last chunk)
      final expectedSize = chunkEnd - chunkStart + 1;
      if (data.length != expectedSize) {
        debugPrint('Mp4Handler: Chunk size mismatch: got ${data.length}, expected $expectedSize');
        // Still usable if we got data
        if (data.isEmpty) return null;
      }

      // Cache the chunk in memory
      _cacheChunk(originalUrl, chunkIndex, data);

      return data;
    } catch (e) {
      debugPrint('Mp4Handler: Error downloading chunk: $e');
      return null;
    }
  }

  /// Cache a downloaded chunk in memory
  void _cacheChunk(String originalUrl, int chunkIndex, Uint8List data) {
    final chunkKey = _getChunkKey(originalUrl, chunkIndex);
    // Store in memory cache directly - synchronous operation
    _cacheManager.storeInMemory(chunkKey, data);
  }

  /// Generate a cache key for a chunk
  String _getChunkKey(String originalUrl, int chunkIndex) {
    return '$originalUrl#chunk$chunkIndex';
  }

  /// Parse HTTP Range header using shared utility
  (int, int)? _parseRange(String rangeHeader, int totalLength) =>
      HttpUtils.parseRange(rangeHeader, totalLength);

  /// Clear chunk info cache
  void clearCache() {
    _chunkInfos.clear();
    _passthroughUrls.clear();
  }

  /// Dispose and clean up all resources
  void dispose() {
    _httpClient?.close();
    _httpClient = null;
    _chunkInfos.clear();
    _passthroughUrls.clear();
  }
}

/// Information about MP4 chunking for a specific URL
class _Mp4ChunkInfo {
  final int contentLength;
  final int chunkSize;
  final int numChunks;

  _Mp4ChunkInfo({
    required this.contentLength,
    required this.chunkSize,
    required this.numChunks,
  });
}
