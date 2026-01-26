/// Configuration for the VideoStream package
class VideoStreamConfig {
  /// Maximum size of the disk cache in bytes
  final int maxCacheSize;

  /// Maximum size of the memory cache in bytes (RAM)
  final int maxMemoryCacheSize;

  /// Number of videos to preload ahead
  final int preloadCount;

  /// Number of bytes to preload for each video
  final int preloadBytes;

  /// Maximum number of concurrent video controllers in the pool
  final int poolSize;

  /// Logging level
  final LogLevel logLevel;

  /// Whether to enable precaching (preloading) of videos
  final bool precache;

  /// Whether to enable precaching on Web specifically
  final bool precacheWeb;

  /// Whether to enable precaching on Mobile (Android/iOS) specifically
  final bool precacheMobile;

  /// Whether to keep the cache after the session (persisted)
  final bool keepCache;

  /// Time to live for cached items
  final Duration cacheTTL;

  /// Whether to use localhost proxy server for video streaming (mobile only).
  /// Enables play-while-download and better caching.
  /// NOTE: Requires platform configuration for cleartext localhost traffic:
  /// - Android: Add network_security_config.xml allowing 127.0.0.1
  /// - iOS: Add NSAllowsLocalNetworking to Info.plist
  /// Disabled by default - enable only after adding platform config.
  final bool useProxy;

  /// Whether to use isolates for background downloads (mobile only).
  /// Offloads download work to separate threads for better performance.
  final bool useIsolates;

  /// Maximum concurrent downloads.
  final int maxConcurrentDownloads;

  /// Chunk size for MP4 chunking in bytes.
  final int chunkSize;

  /// Whether to pause downloads and preloading when app goes to background.
  /// When true, downloads resume automatically when app returns to foreground.
  final bool pauseOnBackground;

  /// Whether to respond to system memory pressure warnings.
  /// When true, memory cache will be reduced based on pressure severity.
  final bool respondToMemoryPressure;

  /// Target percentage of memory cache to retain under memory pressure (0.0-1.0).
  /// For example, 0.25 means keep only 25% of cache during high pressure.
  final double memoryPressureRetainPercent;

  /// Whether to run TTL cleanup and disk eviction on startup.
  /// Helps keep cache size under control after app restarts.
  final bool evictOnStartup;

  /// Whether to enable automatic retry for failed network requests.
  /// Uses exponential backoff with jitter.
  final bool enableRetry;

  /// Maximum number of retry attempts for failed requests.
  final int maxRetries;

  /// Whether to enable metrics collection.
  /// Tracks cache hits, download times, error rates, etc.
  final bool enableMetrics;

  /// Maximum download bandwidth in bytes per second.
  /// Set to 0 for unlimited bandwidth.
  final int maxBandwidthBytesPerSecond;

  const VideoStreamConfig({
    this.maxCacheSize = 500 * 1024 * 1024, // 500MB
    this.maxMemoryCacheSize = 100 * 1024 * 1024, // 100MB
    this.preloadCount = 2,
    this.preloadBytes = 2 * 1024 * 1024, // 2MB
    this.poolSize = 3,
    this.logLevel = LogLevel.none,
    this.precache = true,
    this.precacheWeb = true,
    this.precacheMobile = true,
    this.keepCache = true,
    this.cacheTTL = const Duration(days: 7),
    this.useProxy = false, // Disabled by default - requires platform config
    this.useIsolates = true,
    this.maxConcurrentDownloads = 3,
    this.chunkSize = 2 * 1024 * 1024, // 2MB
    this.pauseOnBackground = true,
    this.respondToMemoryPressure = true,
    this.memoryPressureRetainPercent = 0.25,
    this.evictOnStartup = true,
    this.enableRetry = true,
    this.maxRetries = 3,
    this.enableMetrics = true,
    this.maxBandwidthBytesPerSecond = 0, // Unlimited by default
  })  : assert(maxCacheSize > 0, 'maxCacheSize must be positive'),
        assert(maxMemoryCacheSize > 0, 'maxMemoryCacheSize must be positive'),
        assert(preloadCount >= 0, 'preloadCount must be non-negative'),
        assert(preloadBytes > 0, 'preloadBytes must be positive'),
        assert(poolSize > 0, 'poolSize must be positive'),
        assert(maxConcurrentDownloads > 0, 'maxConcurrentDownloads must be positive'),
        assert(chunkSize > 0, 'chunkSize must be positive'),
        assert(memoryPressureRetainPercent >= 0 && memoryPressureRetainPercent <= 1,
            'memoryPressureRetainPercent must be between 0 and 1'),
        assert(maxRetries >= 0, 'maxRetries must be non-negative'),
        assert(maxBandwidthBytesPerSecond >= 0, 'maxBandwidthBytesPerSecond must be non-negative');
}

enum LogLevel {
  none,
  error,
  info,
  verbose,
}
