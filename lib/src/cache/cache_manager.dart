import 'dart:typed_data';

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

  /// Stores caller-supplied [bytes] in the cache under [key].
  ///
  /// The entry participates in the cache exactly like downloaded content:
  /// it is counted by [getSize], evicted by the LRU size cap, removable via
  /// [remove], and cleared by [clear]. [mimeType] / [filename] are optional
  /// hints used to pick a file extension (mobile) or blob type (web);
  /// `video/mp4` is assumed when absent.
  ///
  /// The size cap is soft for content that is about to play or currently
  /// playing: bytes larger than the cap are still stored (evicting
  /// everything not surfaced) and are cleaned up by the next eviction pass
  /// after the video leaves view.
  ///
  /// Throws [ArgumentError] if [bytes] is empty.
  Future<void> putBytes(
    String key,
    Uint8List bytes, {
    String? mimeType,
    String? filename,
  });

  /// Provider of keys that are currently surfaced (acquired by at least one
  /// player). Content for these keys is never evicted by the size cap —
  /// eviction only ever touches videos that are out of view.
  set activeKeysProvider(Set<String> Function()? provider);

  /// Called whenever a key's cached content is deleted (size-cap eviction,
  /// [remove], or replacement by a new [putBytes]). The controller pool
  /// uses this to drop warm controllers whose backing content is gone, so
  /// a re-acquire re-materializes instead of returning a dead controller.
  set onEvicted(void Function(String key)? callback);

  /// Runs a size-cap eviction pass now.
  ///
  /// Called automatically when a video leaves view so oversized or
  /// over-quota content is reclaimed as soon as it is no longer surfaced.
  Future<void> evictIfNeeded();

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
