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
  Future<VideoPlayerController> acquireSource(VideoSource source) =>
      _acquireShared(source.key, () => _acquireNew(source));

  /// Joins the controller for [key] without re-supplying its source.
  ///
  /// Joins a live or warm pooled controller (or an acquisition in flight).
  /// If the pool has nothing for [key], the content is re-materialized:
  /// from the cache when it holds an entry for [key], or over the network
  /// when [key] itself is an http(s) URL. Otherwise throws
  /// [VideoSourceNotCachedException].
  Future<VideoPlayerController> attachKey(String key) =>
      _acquireShared(key, () => _attachNew(key));

  /// The shared acquisition discipline: pin the key for the whole
  /// operation, join a pooled or in-flight controller, otherwise run
  /// [acquireNew] as the single in-flight acquisition for the key.
  Future<VideoPlayerController> _acquireShared(
    String key,
    Future<VideoPlayerController> Function() acquireNew,
  ) async {
    // Pin the key for the whole acquisition so just-materialized content
    // cannot be evicted before the pooled entry registers as surfaced.
    _acquiringKeys[key] = (_acquiringKeys[key] ?? 0) + 1;
    try {
      while (true) {
        // Check if already active
        final active = _activeControllers[key];
        if (active != null) {
          active.refCount++;
          // If was just released but not collected, mark active
          active.lastReleased = null;
          return active.controller;
        }

        // Join an acquisition already in flight for this key
        final inFlight = _inFlight[key];
        if (inFlight != null) {
          try {
            await inFlight;
          } catch (_) {
            // The creator's acquisition failed, but this caller may succeed
            // with its own creation path (e.g. an acquire holding bytes
            // that joined a doomed attach). Clear the failed future if the
            // creator's cleanup hasn't run yet, then retry ourselves.
            if (identical(_inFlight[key], inFlight)) {
              _inFlight.remove(key);
            }
            continue;
          }
          // Loop: normally the pooled entry now exists and is joined above.
          // If it was already evicted again (creator released instantly and
          // the pool overflowed), retry rather than hand out a reference
          // the pool no longer tracks.
          continue;
        }

        final acquisition = acquireNew();
        _inFlight[key] = acquisition;
        try {
          return await acquisition;
        } finally {
          _inFlight.remove(key);
        }
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
    return _register(key, controller);
  }

  /// Create-and-register path for [attachKey] when nothing is pooled.
  Future<VideoPlayerController> _attachNew(String key) async {
    // Cache hit (injected content or a fully cached URL): play locally.
    final cacheUrl = await VideoStream.instance.cacheManager.getCacheUrl(key);
    if (cacheUrl != key) {
      final controller = createLocalController(cacheUrl,
          options: VideoStream.instance.config.playerOptions);
      return _register(key, controller);
    }

    // A URL key fully describes its source, so it is always
    // re-materializable over the network.
    final uri = Uri.tryParse(key);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      return _acquireNew(VideoSource.url(key));
    }

    throw VideoSourceNotCachedException(key);
  }

  /// Initializes [controller] and registers it in the pool under [key].
  Future<VideoPlayerController> _register(
      String key, VideoPlayerController controller) async {

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
    // Per-source options win over the global config value. Same-key sources
    // share one controller, so the first creation's options stick.
    final options =
        source.playerOptions ?? VideoStream.instance.config.playerOptions;

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
          videoPlayerOptions: options,
        );

      case BytesVideoSource():
        return createLocalController(
          await _materializeInjected(
            source.key,
            () async => source.bytes,
            mimeType: source.mimeType,
            filename: source.filename,
          ),
          options: options,
        );

      case FileVideoSource():
        return createLocalController(
          await _materializeInjected(
            source.key,
            () => readSourceFile(source.path),
          ),
          options: options,
        );
    }
  }

  /// Pauses every pooled controller whose key differs from [key] and whose
  /// video is currently playing. Sessions/players on the same key are
  /// siblings sharing one controller and are never paused by this.
  Future<void> pauseAllExcept(String key) async {
    for (final pooled in List<_PooledController>.from(_pool)) {
      if (pooled.key == key) continue;
      final controller = pooled.controller;
      if (!controller.value.isPlaying) continue;
      try {
        await controller.pause();
      } catch (e) {
        debugPrint('ControllerPool: Failed to pause ${pooled.key}: $e');
      }
    }
  }

  /// Monotonic ticket serializing exclusive plays: when two exclusive plays
  /// race, only the most recent one actually starts (last wins) - so
  /// "playback never overlaps" holds even across the pause round-trips.
  int _exclusiveTicket = 0;

  /// The exclusive-play primitive: pause everything but [key], then start
  /// [controller] - unless a newer exclusive play superseded this one during
  /// the pause round-trip, or [isCancelled] reports the caller no longer
  /// wants playback (e.g. its session was released mid-await).
  Future<void> playExclusive(
    String key,
    VideoPlayerController controller, {
    bool Function()? isCancelled,
  }) async {
    final ticket = ++_exclusiveTicket;
    await pauseAllExcept(key);
    if (ticket != _exclusiveTicket || (isCancelled?.call() ?? false)) {
      // Superseded or cancelled while pausing others: starting now would
      // resurrect a video that should stay paused (or has no owner).
      return;
    }
    await controller.play();
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
      // Nobody references this controller anymore: a still-playing video
      // would be ownerless ghost audio, so stop it (fire-and-forget).
      if (pooled.controller.value.isPlaying) {
        pooled.controller.pause().catchError((Object e) {
          debugPrint('ControllerPool: Pause on release failed for $key: $e');
        });
      }
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
