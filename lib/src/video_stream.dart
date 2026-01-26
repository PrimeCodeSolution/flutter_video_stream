import 'package:flutter/foundation.dart';
import 'config/video_stream_config.dart';
import 'cache/cache_manager.dart';
import 'cache/mobile_cache_manager.dart'
    if (dart.library.js_interop) 'cache/web_cache_manager.dart';
import 'pool/controller_pool.dart';
import 'pool/preload_manager.dart';
import 'controller/video_stream_controller.dart';
import 'proxy/proxy_server.dart'
    if (dart.library.js_interop) 'proxy/proxy_stub.dart';
import 'download/download_manager.dart';
import 'web/web_preloader_stub.dart'
    if (dart.library.js_interop) 'web/web_preloader.dart';
import 'lifecycle/lifecycle_observer.dart';
import 'utils/metrics.dart';

class VideoStream {
  static final VideoStream _instance = VideoStream._();
  static VideoStream get instance => _instance;

  VideoStream._();

  late VideoStreamConfig _config;
  late CacheManager _cacheManager;
  late ControllerPool _controllerPool;
  late PreloadManager _preloadManager;
  ProxyServer? _proxyServer;
  DownloadManager? _downloadManager;
  WebPreloader? _webPreloader;
  bool _isInitialized = false;

  /// Configuration of the singleton
  VideoStreamConfig get config => _config;

  /// Internal access to subsystems
  CacheManager get cacheManager => _cacheManager;
  ControllerPool get controllerPool => _controllerPool;
  PreloadManager get preloadManager => _preloadManager;
  WebPreloader? get webPreloader => _webPreloader;

  /// Global controller for the active video.
  /// Use this to control playback (pause/play) and volume (mute/unmute).
  static VideoStreamController get controller => VideoStreamController.instance;

  /// Initialize the package. Must be called before use.
  static Future<void> initialize(
      {VideoStreamConfig config = const VideoStreamConfig()}) async {
    if (_instance._isInitialized) return;

    _instance._config = config;

    // Start lifecycle observer on mobile platforms
    if (!kIsWeb && config.pauseOnBackground) {
      VideoStreamLifecycleObserver.instance.start();
    }

    // Choose appropriate cache manager based on platform imports
    // or conditional imports (handled by imports above)
    _instance._cacheManager = getPlatformCacheManager();
    await _instance._cacheManager.initialize(
      keepCache: config.keepCache,
      cacheTTL: config.cacheTTL,
      memoryCacheSize: config.maxMemoryCacheSize,
      maxDiskCacheSize: config.maxCacheSize,
      respondToMemoryPressure: config.respondToMemoryPressure,
      memoryPressureRetainPercent: config.memoryPressureRetainPercent,
      evictOnStartup: config.evictOnStartup,
      enableRetry: config.enableRetry,
      maxRetries: config.maxRetries,
      enableMetrics: config.enableMetrics,
      maxBandwidthBytesPerSecond: config.maxBandwidthBytesPerSecond,
    );

    _instance._controllerPool = ControllerPool(maxSize: config.poolSize);

    _instance._preloadManager = PreloadManager(
      cacheManager: _instance._cacheManager,
      preloadCount: config.preloadCount,
      preloadBytes: config.preloadBytes,
      precacheEnabled: config.precache,
      precacheWeb: config.precacheWeb,
      precacheMobile: config.precacheMobile,
    );

    // Register preload manager with lifecycle observer
    if (!kIsWeb && config.pauseOnBackground) {
      VideoStreamLifecycleObserver.instance.addListener(_instance._preloadManager);
    }

    // Start proxy server on mobile platforms if enabled
    if (!kIsWeb && config.useProxy) {
      _instance._proxyServer = ProxyServer(
        cacheManager: _instance._cacheManager,
        chunkSize: config.chunkSize,
      );
      await _instance._proxyServer!.start();
      debugPrint(
          'VideoStream: Proxy server started on port ${_instance._proxyServer!.port}');
    }

    // Initialize download manager for background downloads
    if (!kIsWeb) {
      _instance._downloadManager = DownloadManager(
        maxConcurrent: config.maxConcurrentDownloads,
        useIsolates: config.useIsolates,
      );
      await _instance._downloadManager!.initialize();
      debugPrint(
          'VideoStream: Download manager initialized (isolates: ${config.useIsolates})');

      // Register download manager with lifecycle observer
      if (config.pauseOnBackground) {
        VideoStreamLifecycleObserver.instance.addListener(_instance._downloadManager!);
      }
    }

    // Initialize web preloader for in-memory preloading on web
    if (kIsWeb && config.precacheWeb) {
      _instance._webPreloader = getWebPreloader();
      debugPrint('VideoStream: Web preloader initialized');
    }

    _instance._isInitialized = true;
  }

  /// Ensure initialization happened
  static void _ensureInitialized() {
    if (!_instance._isInitialized) {
      throw Exception(
          'VideoStream.initialize() must be called before using the package.');
    }
  }

  /// Precache a list of videos
  static Future<void> precache(List<String> urls) async {
    _ensureInitialized();
    _instance._preloadManager.precache(urls);
  }

  /// Get cache status for a url
  static Future<CacheStatus> getCacheStatus(String url) async {
    _ensureInitialized();
    return _instance._cacheManager.getStatus(url);
  }

  /// Clear all cache
  static Future<void> clearCache() async {
    _ensureInitialized();
    await _instance._cacheManager.clear();
  }

  /// Remove specific file from cache
  static Future<void> removeFromCache(String url) async {
    _ensureInitialized();
    await _instance._cacheManager.remove(url);
  }

  /// Get total cache size in bytes
  static Future<int> getCacheSize() async {
    _ensureInitialized();
    return _instance._cacheManager.getSize();
  }

  /// Get the proxy URL for an original video URL.
  /// On mobile with proxy enabled, returns localhost URL.
  /// Otherwise returns the original URL.
  static String getProxyUrl(String originalUrl) {
    _ensureInitialized();
    if (_instance._proxyServer?.isRunning == true) {
      return _instance._proxyServer!.getProxyUrl(originalUrl);
    }
    return originalUrl;
  }

  /// Whether the proxy server is running
  static bool get isProxyRunning => _instance._proxyServer?.isRunning ?? false;

  /// Dispose the VideoStream instance and stop all services
  static Future<void> dispose() async {
    if (!_instance._isInitialized) return;

    // Stop lifecycle observer
    if (!kIsWeb) {
      VideoStreamLifecycleObserver.instance.stop();
    }

    await _instance._proxyServer?.stop();
    _instance._proxyServer = null;

    _instance._downloadManager?.dispose();
    _instance._downloadManager = null;

    _instance._webPreloader?.dispose();
    _instance._webPreloader = null;

    _instance._preloadManager.dispose();
    _instance._controllerPool.disposeAll();
    _instance._cacheManager.dispose();

    _instance._isInitialized = false;
    debugPrint('VideoStream: Disposed');
  }

  /// Access to the download manager for advanced download control
  static DownloadManager? get downloadManager => _instance._downloadManager;

  /// Access to metrics for monitoring performance
  static VideoStreamMetrics get metrics => VideoStreamMetrics.instance;

  /// Get a snapshot of current metrics
  static MetricsSnapshot getMetricsSnapshot() => VideoStreamMetrics.instance.getSnapshot();

  /// Reset all collected metrics
  static void resetMetrics() => VideoStreamMetrics.instance.reset();
}
