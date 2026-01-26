import 'package:flutter/foundation.dart';
import 'cache_manager.dart';

CacheManager getPlatformCacheManager() => WebCacheManager();

/// Web cache manager - pure pass-through, no caching on web.
/// Video playback uses browser's native HTTP caching.
class WebCacheManager implements CacheManager {
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
    // No-op on web - browser handles caching natively
    debugPrint('WebCacheManager: Initialized (no-op, using browser cache)');
  }

  @override
  Future<String> getCacheUrl(String originalUrl,
      {Map<String, String>? headers}) async {
    // On web, always return original URL - browser handles caching
    return originalUrl;
  }

  @override
  Future<void> precache(String url,
      {int? bytes, Map<String, String>? headers}) async {
    // No-op on web - can't precache without service worker
  }

  @override
  Future<CacheStatus> getStatus(String url) async {
    // On web, we don't track cache status
    return CacheStatus.none;
  }

  @override
  Future<void> remove(String url) async {
    // No-op on web
  }

  @override
  Future<void> clear() async {
    // No-op on web
  }

  @override
  Future<int> getSize() async {
    // On web, we don't track cache size
    return 0;
  }

  @override
  void dispose() {}
}
