import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert'; // for utf8
import 'cache_manager.dart';
import 'lru_memory_cache.dart';
import 'download_tracker.dart';
import '../lifecycle/lifecycle_observer.dart';
import '../utils/metrics.dart';
import '../utils/retry_helper.dart';
import '../utils/bandwidth_throttler.dart';

CacheManager getPlatformCacheManager() => MobileCacheManager();

class MobileCacheManager implements CacheManager {
  Directory? _cacheDir;
  LruMemoryCache? _memoryCache;
  DownloadTracker? _downloadTracker;
  int _maxDiskCacheSize = 500 * 1024 * 1024; // 500MB default
  Duration _cacheTTL = const Duration(days: 7);

  // Config options
  bool _respondToMemoryPressure = true;
  double _memoryPressureRetainPercent = 0.25;
  bool _evictOnStartup = true;
  bool _enableRetry = true;
  int _maxRetries = 3;
  bool _enableMetrics = true;

  // Bandwidth throttler
  BandwidthThrottler? _bandwidthThrottler;

  // Reusable HttpClient to avoid memory leaks
  HttpClient? _httpClient;

  HttpClient get _client {
    _httpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    return _httpClient!;
  }

  // Track in-flight downloads to prevent duplicates
  final Set<String> _inFlightDownloads = {};

  // Metadata cache for better eviction performance
  List<CacheMetadata>? _metadataCache;
  DateTime? _metadataCacheTime;
  static const _metadataCacheDuration = Duration(seconds: 30);

  @override
  Future<void> initialize({
    bool keepCache = true,
    Duration cacheTTL = const Duration(days: 7),
    int memoryCacheSize = 100 * 1024 * 1024,
    int maxDiskCacheSize = 500 * 1024 * 1024,
    bool respondToMemoryPressure = true,
    double memoryPressureRetainPercent = 0.25,
    bool evictOnStartup = true,
    bool enableRetry = true,
    int maxRetries = 3,
    bool enableMetrics = true,
    int maxBandwidthBytesPerSecond = 0,
  }) async {
    debugPrint('MobileCacheManager: Initializing file system cache...');

    // Use dedicated subdirectory for cache
    final tempDir = await getTemporaryDirectory();
    _cacheDir = Directory('${tempDir.path}/video_stream_cache');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }

    _memoryCache = LruMemoryCache(maxSizeBytes: memoryCacheSize);
    _downloadTracker = DownloadTracker(cacheDir: _cacheDir!);
    _maxDiskCacheSize = maxDiskCacheSize;
    _cacheTTL = cacheTTL;
    _respondToMemoryPressure = respondToMemoryPressure;
    _memoryPressureRetainPercent = memoryPressureRetainPercent;
    _evictOnStartup = evictOnStartup;
    _enableRetry = enableRetry;
    _maxRetries = maxRetries;
    _enableMetrics = enableMetrics;

    // Initialize bandwidth throttler if limit is set
    if (maxBandwidthBytesPerSecond > 0) {
      _bandwidthThrottler = BandwidthThrottler(
        maxBytesPerSecond: maxBandwidthBytesPerSecond,
      );
      debugPrint('MobileCacheManager: Bandwidth limit set to ${maxBandwidthBytesPerSecond ~/ 1024} KB/s');
    }

    // Register memory pressure handler only if enabled
    if (_respondToMemoryPressure) {
      VideoStreamLifecycleObserver.instance.addMemoryPressureCallback(_onMemoryPressure);
    }

    // Cleanup orphaned partial files
    await _downloadTracker!.cleanupOrphans();

    // Run initial TTL cleanup and disk eviction only if enabled
    if (_evictOnStartup) {
      await _runTTLCleanup();
      await _runDiskEviction();
    }

    // Cleanup if needed (basic TTL check could go here)
    if (!keepCache) {
      await clear();
    }
  }

  String _getFileName(String url) {
    final bytes = utf8.encode(url);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Get the file extension from a URL using proper URL parsing.
  String _getExtension(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.toLowerCase();

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

  Future<File> _getCacheFile(String url) async {
    if (_cacheDir == null) await initialize();
    final fileName = _getFileName(url);
    final extension = _getExtension(url);

    return File('${_cacheDir!.path}/$fileName$extension');
  }

  @override
  Future<String> getCacheUrl(String originalUrl,
      {Map<String, String>? headers}) async {
    // Check memory cache first (fastest)
    if (_memoryCache?.contains(originalUrl) == true) {
      debugPrint('MobileCacheManager: Memory cache HIT for $originalUrl');
      if (_enableMetrics) {
        VideoStreamMetrics.instance.recordMemoryCacheHit();
      }
      // Memory cache hit - but we still return file path or original URL
      // The actual bytes will be served from memory when needed
    } else {
      if (_enableMetrics) {
        VideoStreamMetrics.instance.recordMemoryCacheMiss();
      }
    }

    final file = await _getCacheFile(originalUrl);
    if (await file.exists()) {
      debugPrint('MobileCacheManager: Serving from disk: ${file.path}');
      if (_enableMetrics) {
        VideoStreamMetrics.instance.recordDiskCacheHit();
      }
      // Update last accessed time for LRU tracking
      _downloadTracker?.updateLastAccessed(file);
      // Load into memory cache for faster subsequent access
      _loadIntoMemoryCache(originalUrl, file);
      return file.path;
    }

    if (_enableMetrics) {
      VideoStreamMetrics.instance.recordDiskCacheMiss();
    }
    return originalUrl;
  }

  /// Load file data into memory cache asynchronously
  Future<void> _loadIntoMemoryCache(String url, File file) async {
    if (_memoryCache == null) return;
    if (_memoryCache!.contains(url)) return; // Already in memory

    try {
      final bytes = await file.readAsBytes();
      _memoryCache!.put(url, bytes);
    } catch (e) {
      debugPrint('MobileCacheManager: Failed to load into memory cache: $e');
    }
  }

  /// Get data from memory cache directly (for proxy server use)
  Uint8List? getFromMemory(String url) => _memoryCache?.get(url);

  /// Store data directly in memory cache (for chunk caching)
  void storeInMemory(String url, Uint8List data) {
    _memoryCache?.put(url, data);
  }

  /// Access to memory cache for checking memory pressure
  LruMemoryCache? get memoryCache => _memoryCache;

  @override
  Future<void> precache(String url,
      {int? bytes, Map<String, String>? headers}) async {
    // Check if already downloading
    if (_inFlightDownloads.contains(url)) {
      debugPrint('MobileCacheManager: Download already in progress for $url');
      return;
    }

    _inFlightDownloads.add(url);
    final startTime = DateTime.now();
    if (_enableMetrics) {
      VideoStreamMetrics.instance.recordDownloadStarted();
    }

    try {
      final file = await _getCacheFile(url);
      if (await file.exists()) {
        // Already on disk, load into memory
        _loadIntoMemoryCache(url, file);
        return;
      }

      // Check for resumable partial download
      final tracker = _downloadTracker!;
      final partialFile = tracker.getPartialFile(file);
      final partialExists = await partialFile.exists();
      final existingBytes = partialExists ? await partialFile.length() : 0;

      // If we already have enough bytes for partial preload, skip
      if (bytes != null && existingBytes >= bytes) {
        debugPrint(
            'MobileCacheManager: Already have ${_formatBytes(existingBytes)} cached for $url (requested ${_formatBytes(bytes)})');
        return;
      }

      // For resumption, check if partial is valid (incomplete download)
      final hasPartial = await tracker.hasValidPartial(file);
      final startByte = hasPartial ? existingBytes : 0;

      // Determine end byte for Range request (only if bytes limit specified)
      final int? endByte = bytes != null ? (bytes - 1) : null;
      final isPartialPreload = bytes != null;

      // First, do a HEAD request to check Content-Length before downloading
      final contentLength = await _getContentLength(url, headers);
      if (contentLength != null && contentLength > 0) {
        final memoryCacheSize = _memoryCache?.maxSizeBytes ?? 0;

        // If doing a full download (no bytes limit) and file is too large for memory cache, skip
        if (!isPartialPreload && contentLength > memoryCacheSize) {
          debugPrint(
              'MobileCacheManager: Skipping $url - too large for memory cache (${_formatBytes(contentLength)} > ${_formatBytes(memoryCacheSize)})');
          return;
        }

        // If file is larger than disk cache limit, skip entirely
        if (contentLength > _maxDiskCacheSize) {
          debugPrint(
              'MobileCacheManager: Skipping $url - exceeds disk cache limit (${_formatBytes(contentLength)} > ${_formatBytes(_maxDiskCacheSize)})');
          return;
        }
      }

      debugPrint(
          'MobileCacheManager: Downloading $url (${isPartialPreload ? "first ${_formatBytes(bytes)}" : "full file"}, resuming from byte $startByte)');

      // Wrap download in retry logic if enabled
      final retryConfig = _enableRetry
          ? RetryConfig(maxRetries: _maxRetries)
          : const RetryConfig(maxRetries: 0);

      await RetryHelper.retry(
        config: retryConfig,
        onRetry: (attempt, error, delay) {
          if (_enableMetrics) {
            VideoStreamMetrics.instance.recordRetryAttempt();
          }
          debugPrint('MobileCacheManager: Retry attempt $attempt for $url');
        },
        operation: () async {
          // Use reusable HttpClient
          final request = await _client.getUrl(Uri.parse(url));
          if (headers != null) {
            headers.forEach((k, v) => request.headers.set(k, v));
          }

          // Add Range header for resumption and/or partial preload
          if (startByte > 0 || endByte != null) {
            final rangeEnd = endByte != null ? '$endByte' : '';
            request.headers.set('Range', 'bytes=$startByte-$rangeEnd');
          }

          final response = await request.close();

          // Handle response codes
          final isResumed = response.statusCode == 206; // Partial Content
          final isFullDownload = response.statusCode == 200;

          if (!isResumed && !isFullDownload) {
            await response.drain<void>();
            throw HttpRetryableException(
              'Failed to download: ${response.statusCode}',
              response.statusCode,
            );
          }

          // If server doesn't support resumption/ranges, start fresh
          if ((startByte > 0 || endByte != null) && !isResumed) {
            debugPrint(
                'MobileCacheManager: Server does not support Range requests');
            if (startByte > 0) {
              await tracker.cancelDownload(file);
            }
            // If we wanted partial preload but server doesn't support ranges,
            // check if full file is too large
            if (isPartialPreload && response.contentLength > 0) {
              final memoryCacheSize = _memoryCache?.maxSizeBytes ?? 0;
              if (response.contentLength > memoryCacheSize) {
                await response.drain<void>();
                debugPrint(
                    'MobileCacheManager: Server does not support Range - file too large (${_formatBytes(response.contentLength)})');
                return;
              }
            }
          }

          // Get content length for tracking (handle unknown content length)
          final responseContentLength = response.contentLength;
          if (responseContentLength > 0) {
            final totalExpected =
                isResumed ? startByte + responseContentLength : responseContentLength;
            await tracker.saveExpectedBytes(file, totalExpected);
          }

          // Apply bandwidth throttling if configured
          final responseStream = _bandwidthThrottler != null
              ? _bandwidthThrottler!.throttleStream(response)
              : response;

          // Stream download with resumption support
          final downloadedBytes = <int>[];
          int totalDownloaded = startByte;
          final downloadLimit = bytes ?? -1; // -1 means no limit

          await for (final chunk in responseStream) {
            downloadedBytes.addAll(chunk);
            totalDownloaded += chunk.length;

            // For large files, write in chunks to avoid memory pressure
            if (downloadedBytes.length >= 1024 * 1024) {
              // 1MB chunks
              await tracker.appendBytes(file, downloadedBytes);
              downloadedBytes.clear();
            }

            // Stop if we've downloaded enough for partial preload
            if (downloadLimit > 0 && totalDownloaded >= downloadLimit) {
              break;
            }
          }

          // Write remaining bytes
          if (downloadedBytes.isNotEmpty) {
            await tracker.appendBytes(file, downloadedBytes);
          }

          // Complete the download (or mark as partial)
          if (isPartialPreload) {
            // For partial preloads, we don't mark as complete - file stays as .partial
            debugPrint(
                'MobileCacheManager: Partial preload complete for $url (${_formatBytes(totalDownloaded)})');
          } else {
            await tracker.completeDownload(file);
          }
        },
      );

      // For partial preloads, skip post-processing since file is still .partial
      if (isPartialPreload) {
        final durationMs = DateTime.now().difference(startTime).inMilliseconds;
        if (_enableMetrics) {
          final partialFile = tracker.getPartialFile(file);
          final partialBytes = await partialFile.exists() ? await partialFile.length() : 0;
          VideoStreamMetrics.instance.recordDownloadCompleted(partialBytes, durationMs);
        }
        return;
      }

      final totalBytes = await file.length();
      final durationMs = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint(
          'MobileCacheManager: Download complete for $url ($totalBytes bytes in ${durationMs}ms)');

      if (_enableMetrics) {
        VideoStreamMetrics.instance.recordDownloadCompleted(totalBytes, durationMs);
      }

      // Save cache metadata for LRU tracking
      final now = DateTime.now();
      final metadata = CacheMetadata(
        url: url,
        filePath: file.path,
        fileSize: totalBytes,
        created: now,
        lastAccessed: now,
        expires: now.add(_cacheTTL),
      );
      await tracker.saveCacheMetadata(file, metadata);

      // Invalidate metadata cache after new download
      _invalidateMetadataCache();

      // Load into memory cache
      _loadIntoMemoryCache(url, file);

      // Run disk eviction after each download completes
      await _runDiskEviction();
    } catch (e) {
      debugPrint('MobileCacheManager: Error precaching $url: $e');
      if (_enableMetrics) {
        VideoStreamMetrics.instance.recordDownloadFailed(url, e);
        VideoStreamMetrics.instance.recordRetryFailure();
      }
      // Don't cancel partial download on network error - allow resumption
    } finally {
      _inFlightDownloads.remove(url);
    }
  }

  /// Get Content-Length for a URL using HEAD request.
  /// Returns null if unable to determine size.
  Future<int?> _getContentLength(String url, Map<String, String>? headers) async {
    try {
      final request = await _client.headUrl(Uri.parse(url));
      if (headers != null) {
        headers.forEach((k, v) => request.headers.set(k, v));
      }
      final response = await request.close();
      await response.drain<void>();

      if (response.statusCode == 200 || response.statusCode == 206) {
        return response.contentLength;
      }
    } catch (e) {
      debugPrint('MobileCacheManager: HEAD request failed for $url: $e');
    }
    return null;
  }

  @override
  Future<CacheStatus> getStatus(String url) async {
    final file = await _getCacheFile(url);
    if (await file.exists()) {
      return CacheStatus.complete;
    }
    // Check for partial download
    if (_downloadTracker != null &&
        await _downloadTracker!.hasValidPartial(file)) {
      return CacheStatus.partial;
    }
    return CacheStatus.none;
  }

  @override
  Future<void> remove(String url) async {
    final file = await _getCacheFile(url);
    // Remove completed file
    if (await file.exists()) {
      await file.delete();
    }
    // Remove any partial download
    await _downloadTracker?.cancelDownload(file);
    // Remove cache metadata
    await _downloadTracker?.deleteCacheMetadata(file);
    // Remove from memory cache
    _memoryCache?.remove(url);
  }

  /// Check if a file path represents a cache file.
  bool _isCacheFile(String path) {
    final fileName = path.substring(path.lastIndexOf('/') + 1);
    return path.endsWith('.mp4') ||
        path.endsWith('.mov') ||
        path.endsWith('.ts') ||
        path.endsWith('.m4s') ||
        path.endsWith('.webm') ||
        path.endsWith('.partial') ||
        path.endsWith('.meta') ||
        path.endsWith('.cachemeta') ||
        !fileName.contains('.');
  }

  @override
  Future<void> clear() async {
    // Clear memory cache
    _memoryCache?.clear();
    _invalidateMetadataCache();

    // Clear disk cache (including partial, meta, and cachemeta files)
    if (_cacheDir == null) return;
    if (!await _cacheDir!.exists()) return;

    try {
      await for (final entity in _cacheDir!.list()) {
        if (entity is File) {
          final path = entity.path;
          if (_isCacheFile(path)) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('MobileCacheManager: Error clearing cache: $e');
    }
  }

  @override
  Future<int> getSize() async {
    int totalSize = 0;

    // Memory cache size
    totalSize += _memoryCache?.currentSize ?? 0;

    // Disk cache size (use async stream to avoid blocking)
    if (_cacheDir != null && await _cacheDir!.exists()) {
      try {
        await for (final entity in _cacheDir!.list()) {
          if (entity is File) {
            totalSize += await entity.length();
          }
        }
      } catch (e) {
        debugPrint('MobileCacheManager: Error calculating cache size: $e');
      }
    }

    return totalSize;
  }

  // ============ Metadata Cache Methods ============

  /// Get cached metadata, refreshing if stale or forced.
  Future<List<CacheMetadata>> _getCachedMetadata({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _metadataCache != null &&
        _metadataCacheTime != null &&
        now.difference(_metadataCacheTime!) < _metadataCacheDuration) {
      return _metadataCache!;
    }
    _metadataCache = await _downloadTracker!.getAllCacheMetadata();
    _metadataCacheTime = now;
    return _metadataCache!;
  }

  /// Invalidate the metadata cache.
  void _invalidateMetadataCache() {
    _metadataCache = null;
    _metadataCacheTime = null;
  }

  // ============ Disk Cache Eviction Methods ============

  /// Run LRU eviction on disk cache when over size limit.
  ///
  /// Evicts least recently accessed files until under [_maxDiskCacheSize].
  Future<void> _runDiskEviction() async {
    if (_downloadTracker == null || _cacheDir == null) return;

    try {
      // Get all cache metadata (use cached if available)
      final allMetadata = await _getCachedMetadata();
      if (allMetadata.isEmpty) return;

      // Calculate total disk cache size
      int totalSize = 0;
      for (final meta in allMetadata) {
        totalSize += meta.fileSize;
      }

      if (totalSize <= _maxDiskCacheSize) return;

      debugPrint(
          'MobileCacheManager: Disk cache over limit (${_formatBytes(totalSize)} > ${_formatBytes(_maxDiskCacheSize)})');

      // Sort by last accessed (oldest first)
      final sortedMetadata = List<CacheMetadata>.from(allMetadata);
      sortedMetadata.sort((a, b) => a.lastAccessed.compareTo(b.lastAccessed));

      // Evict until under limit
      int evictedCount = 0;
      int evictedSize = 0;

      for (final meta in sortedMetadata) {
        if (totalSize <= _maxDiskCacheSize) break;

        final file = File(meta.filePath);
        if (await file.exists()) {
          await file.delete();
          await _downloadTracker!.deleteCacheMetadata(file);
          totalSize -= meta.fileSize;
          evictedSize += meta.fileSize;
          evictedCount++;
        }
      }

      if (evictedCount > 0) {
        // Invalidate cache after eviction
        _invalidateMetadataCache();
        debugPrint(
            'MobileCacheManager: Evicted $evictedCount files (${_formatBytes(evictedSize)})');
      }
    } catch (e) {
      debugPrint('MobileCacheManager: Error during disk eviction: $e');
    }
  }

  /// Remove files that have expired based on TTL.
  Future<void> _runTTLCleanup() async {
    if (_downloadTracker == null || _cacheDir == null) return;

    try {
      final allMetadata = await _downloadTracker!.getAllCacheMetadata();
      int removedCount = 0;

      for (final meta in allMetadata) {
        if (meta.isExpired) {
          final file = File(meta.filePath);
          if (await file.exists()) {
            await file.delete();
            await _downloadTracker!.deleteCacheMetadata(file);
            removedCount++;
          }
        }
      }

      if (removedCount > 0) {
        debugPrint('MobileCacheManager: TTL cleanup removed $removedCount expired files');
      }
    } catch (e) {
      debugPrint('MobileCacheManager: Error during TTL cleanup: $e');
    }
  }

  // ============ Memory Pressure Handling ============

  /// Handle memory pressure from the system.
  void _onMemoryPressure(MemoryPressureLevel level) {
    debugPrint('MobileCacheManager: Memory pressure level: $level');

    // Use configured retain percent for high pressure
    final retainPercent = _memoryPressureRetainPercent;

    switch (level) {
      case MemoryPressureLevel.low:
        _memoryCache?.evictToPercent(0.75);
        break;
      case MemoryPressureLevel.medium:
        _memoryCache?.evictToPercent(0.50);
        break;
      case MemoryPressureLevel.high:
        _memoryCache?.evictToPercent(retainPercent);
        break;
      case MemoryPressureLevel.critical:
        _memoryCache?.evictAll();
        break;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  void dispose() {
    // Unregister memory pressure handler
    if (_respondToMemoryPressure) {
      VideoStreamLifecycleObserver.instance.removeMemoryPressureCallback(_onMemoryPressure);
    }

    // Close HttpClient to release connections
    _httpClient?.close();
    _httpClient = null;

    // Clear memory cache
    _memoryCache?.clear();
    _memoryCache = null;

    // Clear in-flight downloads
    _inFlightDownloads.clear();

    // Invalidate metadata cache
    _invalidateMetadataCache();
  }
}
