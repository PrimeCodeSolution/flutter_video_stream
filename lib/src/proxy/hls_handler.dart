import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../cache/cache_manager.dart';
import '../cache/mobile_cache_manager.dart';
import '../parser/hls_parser.dart';
import '../utils/http_utils.dart';

/// Handler for HLS (m3u8) streaming through the proxy.
/// Caches playlists and segments individually.
class HlsHandler {
  final MobileCacheManager _cacheManager;

  /// Shared HttpClient for all requests
  HttpClient? _httpClient;

  /// Cache of parsed playlists
  final Map<String, HlsPlaylist> _playlistCache = {};

  /// Track which segments are being downloaded
  final Set<String> _downloadingSegments = {};

  /// Track if handler has been disposed
  bool _isDisposed = false;

  HlsHandler({required MobileCacheManager cacheManager})
      : _cacheManager = cacheManager;

  /// Get or create the shared HttpClient
  HttpClient get _client {
    _httpClient ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);
    return _httpClient!;
  }

  /// Check if a URL is an HLS playlist
  bool isHlsUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('format=m3u8') ||
        lower.contains('type=hls');
  }

  /// Check if a URL is an HLS segment
  bool isHlsSegment(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.ts') ||
        lower.contains('.m4s') ||
        lower.contains('.fmp4');
  }

  /// Handle an HLS playlist request
  Future<void> handlePlaylist(
    HttpRequest request,
    String originalUrl,
    Map<String, String>? headers,
  ) async {
    final response = request.response;

    try {
      // Check cache first
      final memoryData = _cacheManager.getFromMemory(originalUrl);
      if (memoryData != null) {
        debugPrint('HlsHandler: Serving playlist from memory cache');
        response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        response.add(memoryData);
        await response.close();
        return;
      }

      // Fetch the playlist
      final playlist = await HlsParser.fetch(originalUrl, headers: headers);
      _playlistCache[originalUrl] = playlist;

      // If it's a master playlist, we might want to auto-select a variant
      String playlistContent;
      if (playlist.isMaster) {
        // For now, return the original playlist content
        // Could modify to rewrite URLs to proxy URLs
        playlistContent = await _fetchPlaylistContent(originalUrl, headers);
      } else {
        // Media playlist - rewrite segment URLs to go through proxy
        playlistContent = await _rewriteMediaPlaylist(originalUrl, headers);
      }

      // Cache the playlist content
      await _cacheManager.precache(originalUrl, headers: headers);

      response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      response.headers.set('Cache-Control', 'no-cache'); // Playlists may update
      response.write(playlistContent);
      await response.close();

      // Prefetch segments if this is a media playlist
      if (!playlist.isMaster) {
        _prefetchSegments(playlist as HlsMediaPlaylist, headers);
      }
    } catch (e) {
      debugPrint('HlsHandler: Error handling playlist: $e');
      response.statusCode = HttpStatus.badGateway;
      await response.close();
    }
  }

  /// Handle an HLS segment request
  Future<void> handleSegment(
    HttpRequest request,
    String originalUrl,
    Map<String, String>? headers,
  ) async {
    final response = request.response;

    try {
      // Check memory cache first
      final memoryData = _cacheManager.getFromMemory(originalUrl);
      if (memoryData != null) {
        debugPrint('HlsHandler: Serving segment from memory cache');
        _setSegmentHeaders(response, originalUrl, memoryData.length);
        _handleRangeRequest(request, response, memoryData);
        return;
      }

      // Check disk cache
      final cachedPath = await _cacheManager.getCacheUrl(originalUrl);
      if (cachedPath != originalUrl && await File(cachedPath).exists()) {
        debugPrint('HlsHandler: Serving segment from disk cache');
        final file = File(cachedPath);
        final bytes = await file.readAsBytes();
        _setSegmentHeaders(response, originalUrl, bytes.length);
        _handleRangeRequest(request, response, bytes);
        return;
      }

      // Download and cache the segment
      debugPrint('HlsHandler: Downloading segment $originalUrl');
      final bytes = await _downloadSegment(originalUrl, headers);

      if (bytes != null) {
        _setSegmentHeaders(response, originalUrl, bytes.length);
        _handleRangeRequest(request, response, bytes);

        // Cache asynchronously
        _cacheManager.precache(originalUrl, headers: headers);
      } else {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      }
    } catch (e) {
      debugPrint('HlsHandler: Error handling segment: $e');
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    }
  }

  void _setSegmentHeaders(HttpResponse response, String url, int length) {
    final lower = url.toLowerCase();
    if (lower.contains('.ts')) {
      response.headers.contentType = ContentType('video', 'mp2t');
    } else if (lower.contains('.m4s') || lower.contains('.fmp4')) {
      response.headers.contentType = ContentType('video', 'mp4');
    } else {
      response.headers.contentType = ContentType('application', 'octet-stream');
    }
    response.headers.set('Accept-Ranges', 'bytes');
    response.headers.set('Cache-Control', 'public, max-age=31536000');
    response.headers.contentLength = length;
  }

  void _handleRangeRequest(
    HttpRequest request,
    HttpResponse response,
    Uint8List data,
  ) async {
    final rangeHeader = request.headers.value('range');

    if (rangeHeader != null) {
      final range = HttpUtils.parseRange(rangeHeader, data.length);
      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          'Content-Range',
          'bytes ${range.$1}-${range.$2}/${data.length}',
        );
        response.headers.contentLength = range.$2 - range.$1 + 1;
        response.add(data.sublist(range.$1, range.$2 + 1));
      } else {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('Content-Range', 'bytes */${data.length}');
      }
    } else {
      response.add(data);
    }

    await response.close();
  }

  /// Fetch raw playlist content
  Future<String> _fetchPlaylistContent(
    String url,
    Map<String, String>? headers,
  ) async {
    final request = await _client.getUrl(Uri.parse(url));

    if (headers != null) {
      headers.forEach((key, value) => request.headers.set(key, value));
    }

    final response = await request.close();
    return await response.transform(const Utf8Decoder()).join();
  }

  /// Rewrite a media playlist to use proxy URLs for segments
  Future<String> _rewriteMediaPlaylist(
    String playlistUrl,
    Map<String, String>? headers,
  ) async {
    final content = await _fetchPlaylistContent(playlistUrl, headers);
    final lines = content.split('\n');
    final result = StringBuffer();

    for (final line in lines) {
      if (!line.startsWith('#') && line.trim().isNotEmpty) {
        // This is a segment URL - resolve it
        final segmentUrl = _resolveUrl(line.trim(), playlistUrl);
        result.writeln(segmentUrl);
      } else {
        result.writeln(line);
      }
    }

    return result.toString();
  }

  String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    final base = Uri.parse(baseUrl);

    if (url.startsWith('/')) {
      return '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}$url';
    } else {
      final basePath = base.path.substring(0, base.path.lastIndexOf('/') + 1);
      return '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}$basePath$url';
    }
  }

  /// Download a segment
  Future<Uint8List?> _downloadSegment(
    String url,
    Map<String, String>? headers,
  ) async {
    try {
      final request = await _client.getUrl(Uri.parse(url));

      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }

      final response = await request.close();

      if (response.statusCode != 200) {
        debugPrint(
            'HlsHandler: Failed to download segment: ${response.statusCode}');
        await response.drain<void>();
        return null;
      }

      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }

      return Uint8List.fromList(bytes);
    } catch (e) {
      debugPrint('HlsHandler: Error downloading segment: $e');
      return null;
    }
  }

  /// Prefetch upcoming segments
  void _prefetchSegments(
    HlsMediaPlaylist playlist,
    Map<String, String>? headers,
  ) {
    // Don't prefetch if disposed
    if (_isDisposed) return;

    // Check memory pressure before prefetching
    final memCache = _cacheManager.memoryCache;
    if (memCache != null &&
        memCache.currentSize > memCache.maxSizeBytes * 0.8) {
      debugPrint('HlsHandler: Skipping prefetch - memory pressure');
      return;
    }

    // Limit concurrent prefetches
    const maxConcurrentPrefetch = 3;
    final availableSlots = maxConcurrentPrefetch - _downloadingSegments.length;
    if (availableSlots <= 0) return;

    // Prefetch first few segments for faster start
    final segmentsToFetch = playlist.segments
        .where((s) => !_downloadingSegments.contains(s.url))
        .take(availableSlots);

    for (final segment in segmentsToFetch) {
      _downloadingSegments.add(segment.url);

      // Check if already cached, then download in background
      _cacheManager.getStatus(segment.url).then((status) {
        // Check if disposed while waiting
        if (_isDisposed) return;

        if (status == CacheStatus.complete) {
          _downloadingSegments.remove(segment.url);
          return;
        }

        // Download in background
        _cacheManager.precache(segment.url, headers: headers).then((_) {
          if (!_isDisposed) {
            _downloadingSegments.remove(segment.url);
          }
        }).catchError((e) {
          debugPrint('HlsHandler: Error prefetching segment: $e');
          if (!_isDisposed) {
            _downloadingSegments.remove(segment.url);
          }
        });
      }).catchError((e) {
        debugPrint('HlsHandler: Error checking segment status: $e');
        if (!_isDisposed) {
          _downloadingSegments.remove(segment.url);
        }
      });
    }
  }

  /// Clear cached playlists
  void clearCache() {
    _playlistCache.clear();
  }

  /// Dispose and clean up all resources
  void dispose() {
    _isDisposed = true;
    _httpClient?.close();
    _httpClient = null;
    _playlistCache.clear();
    _downloadingSegments.clear();
  }
}
