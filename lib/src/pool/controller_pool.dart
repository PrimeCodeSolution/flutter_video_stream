import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import '../video_stream.dart';

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

  /// Creates a controller pool with the specified maximum size.
  ControllerPool({this.maxSize = 3});

  Future<VideoPlayerController> acquire(String url,
      {Map<String, String>? headers}) async {
    // Check if already active
    if (_activeControllers.containsKey(url)) {
      final pooled = _activeControllers[url]!;
      pooled.refCount++;
      // If was just released but not collected, mark active
      pooled.lastReleased = null;
      return pooled.controller;
    }

    // On web, check if we have a pre-warmed controller ready
    if (kIsWeb) {
      final warmedController =
          VideoStream.instance.webPreloader?.getWarmedController(url);
      if (warmedController != null) {
        debugPrint('ControllerPool: Using pre-warmed controller for $url');
        final pooled = _PooledController(
          url: url,
          controller: warmedController,
          createdAt: DateTime.now(),
        );
        _activeControllers[url] = pooled;
        _pool.add(pooled);
        _evictIfNeeded();
        return warmedController;
      }
    }

    // Create new controller
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

    // We need to support platform specific controller creation or just standard
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(playbackUrl),
      httpHeaders: headers ?? {},
    );

    // Initialize is usually called by the user widget, but we can do it here to "warm up"
    // However, VideoStreamPlayer will call initialize.
    // But if we want instant playback, we might want to initialize here.
    // The prompt says "Abstract away complexity... instant playback".
    try {
      await controller.initialize();
    } catch (e) {
      // Clean up failed controller and rethrow
      controller.dispose();
      debugPrint('ControllerPool: Failed to initialize controller for $url: $e');
      rethrow;
    }

    final pooled = _PooledController(
      url: url,
      controller: controller,
      createdAt: DateTime.now(),
    );

    _activeControllers[url] = pooled;
    _pool.add(pooled);

    // Evict if over limit
    _evictIfNeeded();

    return controller;
  }

  void release(String url) {
    final pooled = _activeControllers[url];
    if (pooled == null) return;

    pooled.refCount--;

    // Don't dispose immediately - keep warm for quick re-access
    if (pooled.refCount <= 0) {
      pooled.lastReleased = DateTime.now();
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
      _activeControllers.remove(candidate.url);
    }
  }

  void dispose() {
    for (final pooled in _pool) {
      pooled.controller.dispose();
    }
    _pool.clear();
    _activeControllers.clear();
  }

  /// Dispose all controllers (alias for dispose)
  void disposeAll() => dispose();
}

class _PooledController {
  final String url;
  final VideoPlayerController controller;
  final DateTime createdAt;
  DateTime? lastReleased;
  int refCount = 1;

  _PooledController({
    required this.url,
    required this.controller,
    required this.createdAt,
  });
}
