import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'config/video_stream_config.dart';
import 'cache/cache_manager.dart';
import 'session/video_surface_arbiter.dart';
import 'source/video_source.dart';
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

  /// Direct access to the controller pool.
  @Deprecated('Use VideoStream.acquire/attach and VideoSession instead - '
      'they manage pool refcounts safely. Public access to the pool will be '
      'removed in 0.4.0.')
  ControllerPool get controllerPool => _controllerPool;

  /// Internal access to subsystems
  PreloadManager get preloadManager => _preloadManager;
  WebPreloader? get webPreloader => _webPreloader;

  /// Global controller for the active video.
  /// Use this to control playback (pause/play) and volume (mute/unmute).
  static VideoStreamController get controller => VideoStreamController.instance;

  final VideoSurfaceArbiter _surfaceArbiter = VideoSurfaceArbiter();

  /// The global [VideoSurfaceArbiter]: a canonical "who renders the
  /// texture" answer for apps sharing one controller between surfaces
  /// (e.g. inline tile ↔ fullscreen page). Usable before [initialize].
  static VideoSurfaceArbiter get surfaceArbiter => _instance._surfaceArbiter;

  /// Acquires (or joins) the pooled controller for [source] and returns a
  /// [VideoSession] handle owning exactly one pool reference.
  ///
  /// This is the entry point for apps that bring their own player UI
  /// instead of using [VideoStreamPlayer]:
  ///
  /// ```dart
  /// final session = await VideoStream.acquire(
  ///   VideoSource.bytes(decryptedBytes, key: eventId),
  /// );
  /// // session.controller is initialized and ready for VideoPlayer(...)
  /// await session.play();       // pauses every other video first
  /// ...
  /// session.release();          // exactly once, when done
  /// ```
  ///
  /// Acquiring a key that already has live sessions (or a
  /// [VideoStreamPlayer]) joins the existing controller; concurrent
  /// acquisitions of one key share a single controller creation. Throws
  /// [VideoSourceNotCachedException] when an injected source cannot be
  /// materialized (see [VideoSource]).
  static Future<VideoSession> acquire(VideoSource source) async {
    _ensureInitialized();
    final pool = _instance._controllerPool;
    final controller = await pool.acquireSource(source);
    _checkPoolCurrent(pool, source.key);
    return VideoSession._(source.key, controller, source, pool);
  }

  /// Joins an already-surfaced or warm [key] without re-supplying the
  /// source — the natural way to hand a video off to another screen:
  ///
  /// ```dart
  /// // Fullscreen page, given only the key of the inline video:
  /// final session = await VideoStream.attach(key);
  /// ```
  ///
  /// Resolution order: a live or warm pooled controller (or an acquisition
  /// already in flight) is joined; otherwise the content is
  /// re-materialized from the cache, or — when [key] itself is an http(s)
  /// URL — over the network. Throws [VideoSourceNotCachedException] if the
  /// key is unknown (no live session, no warm controller, no
  /// re-materializable cache entry).
  static Future<VideoSession> attach(String key) async {
    _ensureInitialized();
    final pool = _instance._controllerPool;
    final controller = await pool.attachKey(key);
    _checkPoolCurrent(pool, key);
    return VideoSession._(key, controller, null, pool);
  }

  /// Guards against [dispose] (or dispose+[initialize]) racing an
  /// acquisition: a session must never be handed out for a pool that is no
  /// longer the live one, or its controller would leak unreleased.
  static void _checkPoolCurrent(ControllerPool pool, String key) {
    if (_instance._isInitialized &&
        identical(pool, _instance._controllerPool)) {
      return;
    }
    pool.release(key);
    pool.dropWarm(key);
    throw StateError(
        'VideoStream was disposed while acquiring "$key". Re-initialize and '
        'acquire again.');
  }

  /// Pauses every pooled controller whose key differs from [key] and is
  /// currently playing.
  ///
  /// This is the exclusion primitive behind `VideoSession.play(exclusive:
  /// true)` and [VideoStreamPlayer]'s play path, so session-based and
  /// widget-based playback never overlap. Sessions on the same key share
  /// one controller and are never paused by each other.
  static Future<void> pauseAllExcept(String key) async {
    _ensureInitialized();
    await _instance._controllerPool.pauseAllExcept(key);
  }

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

    // The size cap only evicts videos that are out of view: the cache asks
    // the pool which keys are surfaced, and a video leaving view triggers a
    // deferred eviction pass.
    _instance._cacheManager.activeKeysProvider =
        () => _instance._controllerPool.activeKeys;
    _instance._controllerPool.onKeyReleased = (_) {
      _instance._cacheManager.evictIfNeeded();
    };
    // When cached content disappears, its warm pooled controller must go
    // too - otherwise a re-acquire would return a controller pointing at a
    // deleted file / revoked blob instead of re-materializing.
    _instance._cacheManager.onEvicted = (key) {
      _instance._controllerPool.dropWarm(key);
    };

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

  /// Push caller-supplied [bytes] into the cache under [key] before a
  /// player exists (e.g. right after a background download + decrypt
  /// completes).
  ///
  /// The content participates in the cache exactly like fetched content:
  /// counted by [getCacheSize], evicted by the size cap, removable via
  /// [removeFromCache] and [clearCache]. A later
  /// `VideoStreamPlayer(source: VideoSource.bytes(...))` (or any source
  /// with the same [key]) plays straight from the cache.
  ///
  /// [mimeType] / [filename] are optional hints used to pick a file
  /// extension (mobile) or blob type (web); `video/mp4` is assumed when
  /// absent.
  ///
  /// The size cap never evicts a video that is currently surfaced (acquired
  /// by a player), and content larger than the cap is still stored so it
  /// can play - it is reclaimed by the eviction pass that runs once the
  /// video leaves view.
  ///
  /// Throws [ArgumentError] if [bytes] is empty.
  static Future<void> precacheBytes(
    String key,
    Uint8List bytes, {
    String? mimeType,
    String? filename,
  }) async {
    _ensureInitialized();
    await _instance._cacheManager
        .putBytes(key, bytes, mimeType: mimeType, filename: filename);
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
    // Warm controllers point at content that no longer exists
    _instance._controllerPool.dropAllWarm();
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

/// A handle to one acquired reference of a pooled video controller.
///
/// Created by [VideoStream.acquire] / [VideoStream.attach] — the API for
/// apps that bring their own player UI. The session owns exactly one pool
/// reference: the underlying controller is shared with every other session
/// (and [VideoStreamPlayer]) on the same [key], and is kept alive until all
/// of them release.
///
/// Sessions remember the [VideoSource] they were acquired with (see
/// [source]), so after an eviction error the app can re-acquire without
/// keeping key→source maps of its own.
///
/// ## Lifecycle
///
/// ```dart
/// final session = await VideoStream.acquire(VideoSource.url(url));
/// VideoPlayer(session.controller);   // your own chrome around it
/// await session.play();              // exclusive by default
/// ...
/// session.release();                 // exactly once
/// ```
///
/// After [release], every other member throws [StateError]; calling
/// [release] again is a no-op (and an assertion failure in debug builds).
class VideoSession {
  VideoSession._(this.key, this._controller, this._source, this._pool);

  /// The pool key this session joined ([VideoSource.key]; the URL for URL
  /// sources).
  final String key;

  final VideoPlayerController _controller;

  /// The pool this session's reference was taken from, captured at
  /// creation so a stale session can never touch a pool created by a later
  /// re-initialize.
  final ControllerPool _pool;

  final VideoSource? _source;

  /// The source this session was acquired with, or null for
  /// [VideoStream.attach].
  ///
  /// Retained by the session so the app can re-acquire after an eviction
  /// error without keeping key→source maps of its own — for a
  /// [VideoSource.bytes] source this also keeps the bytes reachable:
  ///
  /// ```dart
  /// // Content evicted while off-screen? Just re-acquire:
  /// final again = await VideoStream.acquire(old.source!);
  /// ```
  ///
  /// Readable even after [release].
  VideoSource? get source => _source;

  bool _released = false;

  /// Whether [release] has been called. Never throws.
  bool get isReleased => _released;

  /// The raw pooled controller, initialized and ready to render.
  ///
  /// Shared with all other sessions on [key] — dispose is managed by the
  /// pool, never call `controller.dispose()` yourself.
  VideoPlayerController get controller {
    _checkNotReleased();
    return _controller;
  }

  /// Starts playback.
  ///
  /// With [exclusive] true (the default), every other pooled video that is
  /// currently playing is paused first — sessions and [VideoStreamPlayer]s
  /// on the same [key] are siblings sharing this controller and are never
  /// paused. With [exclusive] false this is a plain `controller.play()`.
  Future<void> play({bool exclusive = true}) async {
    _checkNotReleased();
    if (!exclusive) {
      await _controller.play();
      return;
    }
    // The pool serializes exclusive plays (last one wins) and skips the
    // start if this session was released during the pause round-trip - a
    // released session must never start an ownerless controller.
    await _pool.playExclusive(key, _controller, isCancelled: () => _released);
  }

  /// Pauses playback (plain `controller.pause()`).
  Future<void> pause() async {
    _checkNotReleased();
    await _controller.pause();
  }

  /// Releases this session's pool reference — exactly once.
  ///
  /// When the last reference for [key] is released the controller stays
  /// warm for quick re-attach and its content becomes evictable. Calling
  /// release twice is a no-op (assertion failure in debug builds); after
  /// release, the other members throw [StateError].
  void release() {
    if (_released) {
      assert(false,
          'VideoSession.release() called more than once for key "$key"');
      return;
    }
    _released = true;
    _pool.release(key);
  }

  void _checkNotReleased() {
    if (_released) {
      throw StateError(
          'VideoSession for key "$key" has been released and can no longer '
          'be used. Acquire a new session with VideoStream.acquire/attach.');
    }
  }
}
