/// Abstract interface for video cache management.
///
/// The cache manager handles storing and retrieving video data from both
/// disk and memory caches. Platform-specific implementations are provided
/// for mobile (file-based) and web (IndexedDB/memory).
///
/// Users typically don't interact with this directly - use [VideoStream]
/// static methods instead:
///
/// ```dart
/// // Check if a video is cached
/// final status = await VideoStream.getCacheStatus(url);
///
/// // Clear the cache
/// await VideoStream.clearCache();
/// ```
abstract class CacheManager {
  /// Initializes the cache system.
  ///
  /// - [keepCache]: Whether to persist cache between sessions
  /// - [cacheTTL]: How long cached items remain valid
  /// - [memoryCacheSize]: Maximum size of in-memory cache in bytes
  /// - [maxDiskCacheSize]: Maximum size of disk cache in bytes (for LRU eviction)
  /// - [respondToMemoryPressure]: Whether to respond to system memory pressure
  /// - [memoryPressureRetainPercent]: Target percentage of cache to retain under pressure
  /// - [evictOnStartup]: Whether to run eviction on startup
  /// - [enableRetry]: Whether to enable retry with exponential backoff
  /// - [maxRetries]: Maximum number of retry attempts
  /// - [enableMetrics]: Whether to enable metrics collection
  /// - [maxBandwidthBytesPerSecond]: Maximum download bandwidth (0 = unlimited)
  Future<void> initialize({
    bool keepCache = true,
    Duration cacheTTL,
    int memoryCacheSize = 100 * 1024 * 1024,
    int maxDiskCacheSize = 500 * 1024 * 1024,
    bool respondToMemoryPressure = true,
    double memoryPressureRetainPercent = 0.25,
    bool evictOnStartup = true,
    bool enableRetry = true,
    int maxRetries = 3,
    bool enableMetrics = true,
    int maxBandwidthBytesPerSecond = 0,
  });

  /// Returns a URL suitable for playback, which may be a local cache path.
  ///
  /// If the video is fully cached, returns the local file path.
  /// Otherwise, returns the original URL.
  Future<String> getCacheUrl(String originalUrl,
      {Map<String, String>? headers});

  /// Begins caching a video URL.
  ///
  /// - [bytes]: Optional limit on how many bytes to cache (for partial preload)
  /// - [headers]: Optional HTTP headers for the request
  Future<void> precache(String url, {int? bytes, Map<String, String>? headers});

  /// Returns the cache status for a URL.
  Future<CacheStatus> getStatus(String url);

  /// Removes a specific URL from the cache.
  Future<void> remove(String url);

  /// Clears all cached data.
  Future<void> clear();

  /// Returns the total size of cached data in bytes.
  Future<int> getSize();

  /// Releases cache resources.
  void dispose();
}

/// The caching status of a video URL.
enum CacheStatus {
  /// Not cached at all.
  none,

  /// Partially cached (some bytes downloaded).
  partial,

  /// Fully cached and ready for offline playback.
  complete,
}
