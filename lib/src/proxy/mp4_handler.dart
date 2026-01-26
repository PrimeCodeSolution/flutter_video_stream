import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../cache/mobile_cache_manager.dart';
import '../utils/http_utils.dart';

/// Handler for MP4 video streaming with chunked caching.
/// Splits large MP4 files into chunks for efficient caching and seeking.
class Mp4Handler {
  final MobileCacheManager _cacheManager;

  /// Default chunk size: 2MB
  static const int defaultChunkSize = 2 * 1024 * 1024;

  final int chunkSize;

  /// Shared HttpClient for all requests
  HttpClient? _httpClient;

  /// Track chunk download status per URL
  final Map<String, _Mp4ChunkInfo> _chunkInfos = {};

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
      // Get or create chunk info for this URL
      var chunkInfo = _chunkInfos[originalUrl];
      if (chunkInfo == null) {
        chunkInfo = await _initChunkInfo(originalUrl, headers);
        if (chunkInfo == null) {
          response.statusCode = HttpStatus.badGateway;
          await response.close();
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
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  /// Initialize chunk info by fetching content length
  Future<_Mp4ChunkInfo?> _initChunkInfo(
    String url,
    Map<String, String>? headers,
  ) async {
    try {
      // Do a HEAD request to get content length
      final request = await _client.headUrl(Uri.parse(url));

      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }

      final response = await request.close();

      if (response.statusCode != 200 && response.statusCode != 206) {
        debugPrint('Mp4Handler: HEAD request failed: ${response.statusCode}');
        await response.drain<void>();
        return null;
      }

      final contentLength = response.contentLength;
      if (contentLength <= 0) {
        // Try GET request with range 0-0 to get content length
        return await _initChunkInfoViaGet(url, headers);
      }

      final numChunks = (contentLength / chunkSize).ceil();

      debugPrint('Mp4Handler: Initialized chunk info for $url');
      debugPrint('  Content-Length: $contentLength');
      debugPrint('  Chunks: $numChunks x $chunkSize bytes');

      return _Mp4ChunkInfo(
        contentLength: contentLength,
        chunkSize: chunkSize,
        numChunks: numChunks,
      );
    } catch (e) {
      debugPrint('Mp4Handler: Error initializing chunk info: $e');
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
        debugPrint('Mp4Handler: Range request not supported');
        return null;
      }

      // Parse Content-Range header: bytes 0-0/total
      if (contentRange == null) return null;

      final match = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
      if (match == null) return null;

      final contentLength = int.parse(match.group(1)!);
      final numChunks = (contentLength / chunkSize).ceil();

      return _Mp4ChunkInfo(
        contentLength: contentLength,
        chunkSize: chunkSize,
        numChunks: numChunks,
      );
    } catch (e) {
      debugPrint('Mp4Handler: Error getting content length via GET: $e');
      return null;
    }
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
        throw Exception('Failed to get chunk $i');
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
      return await file.readAsBytes();
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

      if (response.statusCode != 206 && response.statusCode != 200) {
        debugPrint('Mp4Handler: Chunk download failed: ${response.statusCode}');
        await response.drain<void>();
        return null;
      }

      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }

      final data = Uint8List.fromList(bytes);

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
  }

  /// Dispose and clean up all resources
  void dispose() {
    _httpClient?.close();
    _httpClient = null;
    _chunkInfos.clear();
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
