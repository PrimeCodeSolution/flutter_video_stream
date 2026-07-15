import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import '../source/video_source.dart';
import '../video_stream.dart';
import 'local_media.dart';

/// Manages a pool of [VideoPlayerController] instances for efficient reuse.
///
/// The controller pool limits the number of active video controllers to reduce
/// memory usage while keeping recently-used controllers warm for instant replay.
///
/// ## How It Works
///
/// 1. When a video is requested, the pool first checks for an existing controller
/// 2. If found, increments the reference count and returns it
/// 3. If not found, creates a new controller and initializes it
/// 4. When released, controllers are kept warm for quick re-access
/// 5. When the pool exceeds [maxSize], least-recently-used controllers are disposed
///
/// ## Usage
///
/// Users typically don't interact with this directly - [VideoStreamPlayer]
/// handles controller acquisition and release automatically.
class ControllerPool {
  /// Maximum number of controllers to keep in the pool.
  final int maxSize;

  final List<_PooledController> _pool = [];
  final Map<String, _PooledController> _activeControllers = {};

  /// In-flight acquisitions, so concurrent acquires of the same key (e.g.
  /// an inline player and a fullscreen page mounting together) share one
  /// controller instead of creating two.
  final Map<String, Future<VideoPlayerController>> _inFlight = {};

  /// Keys currently inside acquireSource (with overlap counts). They are
  /// part of [activeKeys] so just-materialized content cannot be evicted
  /// in the window before the pooled entry is registered.
  final Map<String, int> _acquiringKeys = {};

  /// Called when a key's last reference is released (the video left view).
  /// Used to trigger a deferred cache eviction pass.
  void Function(String key)? onKeyReleased;

  /// Creates a controller pool with the specified maximum size.
  ControllerPool({this.maxSize = 3});

  /// Keys that are currently surfaced: acquired by at least one player, or
  /// mid-acquisition.
  ///
  /// The cache never evicts content for these keys - eviction only applies
  /// to videos that are out of view.
  Set<String> get activeKeys => {
        for (final entry in _activeControllers.entries)
          if (entry.value.refCount > 0) entry.key,
        ..._acquiringKeys.keys,
      };

  /// Disposes the warm (released) pooled controller for [key], if any.
  ///
  /// Called when [key]'s cached content is evicted, removed, or replaced:
  /// the warm controller points at content that is gone, so the next
  /// acquire must re-materialize instead of reusing it. Controllers still
  /// in use (refCount > 0) are left alone.
  void dropWarm(String key) {
    final pooled = _activeControllers[key];
    if (pooled == null || pooled.refCount > 0) return;
    debugPrint('ControllerPool: Dropping warm controller for evicted $key');
    pooled.controller.dispose();
    _pool.remove(pooled);
    _activeControllers.remove(key);
  }

  /// Disposes every warm (released) pooled controller. Used when the whole
  /// cache is cleared and per-key eviction callbacks are unavailable.
  void dropAllWarm() {
    for (final key in _activeControllers.keys.toList()) {
      dropWarm(key);
    }
  }

  /// Acquires a controller for a URL. Equivalent to
  /// `acquireSource(VideoSource.url(url, headers: headers))`.
  Future<VideoPlayerController> acquire(String url,
          {Map<String, String>? headers}) =>
      acquireSource(VideoSource.url(url, headers: headers));

  /// Acquires a controller for [source], pooled by [VideoSource.key].
  ///
  /// Acquiring the same key twice (e.g. an inline player and a fullscreen
  /// page) reuses one controller. Injected ([VideoSource.bytes] /
  /// [VideoSource.file]) sources play from the local cache and never touch
  /// the HTTP proxy; if their cached content is gone and cannot be
  /// re-materialized locally, a [VideoSourceNotCachedException] is thrown.
  Future<VideoPlayerController> acquireSource(VideoSource source) async {
    final key = source.key;

    // Pin the key for the whole acquisition so just-materialized content
    // cannot be evicted before the pooled entry registers as surfaced.
    _acquiringKeys[key] = (_acquiringKeys[key] ?? 0) + 1;
    try {
      // Check if already active
      if (_activeControllers.containsKey(key)) {
        final pooled = _activeControllers[key]!;
        pooled.refCount++;
        // If was just released but not collected, mark active
        pooled.lastReleased = null;
        return pooled.controller;
      }

      // Join an acquisition already in flight for this key
      final inFlight = _inFlight[key];
      if (inFlight != null) {
        final controller = await inFlight;
        final pooled = _activeControllers[key];
        if (pooled != null) {
          pooled.refCount++;
          pooled.lastReleased = null;
          return pooled.controller;
        }
        // Pooled entry already evicted between completion and this await
        return controller;
      }

      final acquisition = _acquireNew(source);
      _inFlight[key] = acquisition;
      try {
        return await acquisition;
      } finally {
        _inFlight.remove(key);
      }
    } finally {
      final remaining = (_acquiringKeys[key] ?? 1) - 1;
      if (remaining <= 0) {
        _acquiringKeys.remove(key);
      } else {
        _acquiringKeys[key] = remaining;
      }
    }
  }

  Future<VideoPlayerController> _acquireNew(VideoSource source) async {
    final key = source.key;

    // On web, check if we have a pre-warmed controller ready (URL flow only)
    if (kIsWeb && source is UrlVideoSource) {
      final warmedController =
          VideoStream.instance.webPreloader?.getWarmedController(key);
      if (warmedController != null) {
        debugPrint('ControllerPool: Using pre-warmed controller for $key');
        final pooled = _PooledController(
          key: key,
          controller: warmedController,
          createdAt: DateTime.now(),
        );
        _activeControllers[key] = pooled;
        _pool.add(pooled);
        _evictIfNeeded();
        return warmedController;
      }
    }

    final controller = await _createController(source);

    // Initialize is usually called by the user widget, but we can do it here to "warm up"
    // However, VideoStreamPlayer will call initialize.
    // But if we want instant playback, we might want to initialize here.
    // The prompt says "Abstract away complexity... instant playback".
    try {
      await controller.initialize();
    } catch (e) {
      // Clean up failed controller and rethrow
      controller.dispose();
      debugPrint('ControllerPool: Failed to initialize controller for $key: $e');
      rethrow;
    }

    final pooled = _PooledController(
      key: key,
      controller: controller,
      createdAt: DateTime.now(),
    );

    _activeControllers[key] = pooled;
    _pool.add(pooled);

    // Evict if over limit
    _evictIfNeeded();

    return controller;
  }

  Future<VideoPlayerController> _createController(VideoSource source) async {
    switch (source) {
      case UrlVideoSource(:final url, :final headers):
        // First check if we have a complete cache file
        final cacheUrl = await VideoStream.instance.cacheManager
            .getCacheUrl(url, headers: headers);

        // Determine the URL to use:
        // 1. If cacheUrl is a file path (different from url), use it directly
        // 2. If proxy is running, use proxy URL for streaming with cache
        // 3. Otherwise use original URL
        String playbackUrl;
        if (cacheUrl != url) {
          // Have cached file, use it directly
          playbackUrl = cacheUrl;
        } else if (VideoStream.isProxyRunning) {
          // Use proxy for play-while-download
          playbackUrl = VideoStream.getProxyUrl(url);
        } else {
          // Direct streaming
          playbackUrl = url;
        }

        return VideoPlayerController.networkUrl(
          Uri.parse(playbackUrl),
          httpHeaders: headers ?? {},
        );

      case BytesVideoSource():
        return createLocalController(await _materializeInjected(
          source.key,
          () async => source.bytes,
          mimeType: source.mimeType,
          filename: source.filename,
        ));

      case FileVideoSource():
        return createLocalController(await _materializeInjected(
          source.key,
          () => readSourceFile(source.path),
        ));
    }
  }

  /// Resolves an injected source key to a locally playable path/URL.
  ///
  /// On cache miss the content is re-injected from [loadBytes] (in-hand
  /// bytes, or the source file on disk). If that's not possible — evicted
  /// cache and no local copy — throws [VideoSourceNotCachedException]; the
  /// package never fetches injected keys over HTTP.
  Future<String> _materializeInjected(
    String key,
    Future<Uint8List?> Function() loadBytes, {
    String? mimeType,
    String? filename,
  }) async {
    final cacheManager = VideoStream.instance.cacheManager;

    var playbackUrl = await cacheManager.getCacheUrl(key);
    if (playbackUrl != key) return playbackUrl;

    final bytes = await loadBytes();
    if (bytes == null || bytes.isEmpty) {
      throw VideoSourceNotCachedException(key);
    }
    await cacheManager.putBytes(key, bytes,
        mimeType: mimeType, filename: filename);

    playbackUrl = await cacheManager.getCacheUrl(key);
    if (playbackUrl == key) {
      // Defensive: putBytes succeeded but the entry is not servable.
      throw VideoSourceNotCachedException(key);
    }
    return playbackUrl;
  }

  /// Releases a previously acquired controller by its source [key]
  /// (the URL in the URL flow).
  void release(String key) {
    final pooled = _activeControllers[key];
    if (pooled == null) return;

    pooled.refCount--;

    // Don't dispose immediately - keep warm for quick re-access
    if (pooled.refCount <= 0) {
      pooled.lastReleased = DateTime.now();
      // The video left view: over-cap content may now be reclaimed
      onKeyReleased?.call(key);
    }
  }

  void _evictIfNeeded() {
    if (_pool.length <= maxSize) return;

    // Sort by priority to remove (least valuable first):
    // 1. Released controllers (refCount <= 0) - oldest released first
    // 2. Active controllers - oldest created first (only if forced)
    final candidates = List<_PooledController>.from(_pool);
    candidates.sort((a, b) {
      // Active ones come last (so they are removed last)
      if (a.refCount > 0 && b.refCount <= 0) return 1;
      if (a.refCount <= 0 && b.refCount > 0) return -1;

      // If both released, remove oldest released
      if (a.refCount <= 0 && b.refCount <= 0) {
        return (a.lastReleased ?? a.createdAt)
            .compareTo(b.lastReleased ?? b.createdAt);
      }

      // If both active, remove oldest created (if forced)
      return a.createdAt.compareTo(b.createdAt);
    });

    // Remove candidates until under limit
    for (final candidate in candidates) {
      if (_pool.length <= maxSize) break;
      if (candidate.refCount > 0) break; // Don't remove active controllers

      candidate.controller.dispose();
      _pool.remove(candidate);
      _activeControllers.remove(candidate.key);
    }
  }

  void dispose() {
    for (final pooled in _pool) {
      pooled.controller.dispose();
    }
    _pool.clear();
    _activeControllers.clear();
    _inFlight.clear();
    _acquiringKeys.clear();
  }

  /// Dispose all controllers (alias for dispose)
  void disposeAll() => dispose();
}

class _PooledController {
  final String key;
  final VideoPlayerController controller;
  final DateTime createdAt;
  DateTime? lastReleased;
  int refCount = 1;

  _PooledController({
    required this.key,
    required this.controller,
    required this.createdAt,
  });
}
