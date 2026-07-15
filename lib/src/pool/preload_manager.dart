import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../cache/cache_manager.dart';
import '../video_stream.dart';
import '../lifecycle/lifecycle_observer.dart';

/// Manages intelligent preloading of videos based on user scroll position.
///
/// The preload manager tracks which videos are registered in the current view
/// and automatically caches nearby videos for smooth playback when scrolling.
///
/// ## How It Works
///
/// 1. Videos register themselves with a [priorityIndex] via [VideoStreamPlayer]
/// 2. When the active video changes, nearby videos are queued for preloading
/// 3. Videos ahead of the current position have priority
/// 4. Preloading respects platform settings ([precacheWeb], [precacheMobile])
///
/// ## Configuration
///
/// Configure via [VideoStreamConfig]:
///
/// ```dart
/// VideoStreamConfig(
///   preloadCount: 2,        // Preload 2 videos ahead
///   preloadBytes: 2 * 1024 * 1024,  // Cache first 2MB
///   precacheMobile: true,
///   precacheWeb: false,
/// )
/// ```
class PreloadManager with LifecycleAware {
  final CacheManager _cacheManager;

  /// Number of videos to preload ahead of the current position.
  final int preloadCount;

  /// Number of bytes to preload for each video.
  final int preloadBytes;

  /// Master switch for precaching functionality.
  final bool precacheEnabled;

  /// Whether to enable precaching on web platform.
  final bool precacheWeb;

  /// Whether to enable precaching on mobile platforms.
  final bool precacheMobile;

  final Queue<String> _preloadQueue = Queue();
  final Set<String> _preloadQueueSet = {}; // O(1) lookup for duplicates
  final Map<String, int> _registeredUrls = {};

  /// Keys of injected (bytes/file) sources. They are already local, so
  /// preloading is a no-op for them — and they must never be fetched over
  /// HTTP. They still occupy their feed index so neighboring URL sources
  /// preload normally.
  final Set<String> _localKeys = {};
  int? _activeIndex;
  bool _isProcessing = false;
  bool _isDisposed = false;
  bool _isPaused = false;

  /// Creates a preload manager with the specified configuration.
  PreloadManager({
    required CacheManager cacheManager,
    this.preloadCount = 2,
    this.preloadBytes = 2 * 1024 * 1024,
    this.precacheEnabled = true,
    this.precacheWeb = true,
    this.precacheMobile = true,
  }) : _cacheManager = cacheManager;

  /// Registers a video key (the URL in the URL flow) with an optional
  /// priority index. This is called automatically by VideoStreamPlayer.
  ///
  /// Pass `preloadable: false` for injected (bytes/file) sources: their
  /// index still counts for neighbor lookups, but they are never fetched.
  void register(String url, int? index, {bool preloadable = true}) {
    if (preloadable) {
      _localKeys.remove(url);
    } else {
      _localKeys.add(url);
    }
    if (index != null) {
      _registeredUrls[url] = index;
      _recalculatePriorities();
    }
  }

  /// Unregisters a video key.
  void unregister(String url) {
    _registeredUrls.remove(url);
    _localKeys.remove(url);
    // No need to aggressively recalculate on remove, just let queue drain or next update handle it.
  }

  /// Notifies the manager which index is currently playing/active.
  void notifyActive(int index) {
    if (_activeIndex != index) {
      final previousIndex = _activeIndex;
      _activeIndex = index;

      // Log scroll direction and context
      if (previousIndex != null) {
        final direction = index > previousIndex ? 'DOWN' : 'UP';
        debugPrint('PreloadManager: Scrolled $direction (index $previousIndex → $index)');
      } else {
        debugPrint('PreloadManager: Initial active index: $index');
      }

      _recalculatePriorities();

      // On web, notify the web preloader to warm up nearby videos.
      // Injected keys are filtered out - they cannot be network-warmed.
      if (kIsWeb) {
        final warmable = Map<String, int>.fromEntries(_registeredUrls.entries
            .where((e) => !_localKeys.contains(e.key)));
        VideoStream.instance.webPreloader?.notifyActive(index, warmable);
      }
    }
  }

  void _recalculatePriorities() {
    if (_activeIndex == null) return;

    _preloadQueue.clear();
    _preloadQueueSet.clear();

    // Find neighbors: active + 1 to active + N
    final targets = <String>[];

    // We want to prioritize based on distance from active index
    // Currently simpler: just look ahead N items
    for (int i = 1; i <= preloadCount; i++) {
      final targetIndex = _activeIndex! + i;
      // Find url with this index
      // (This is O(N) where N is number of videos on screen, which is small)
      final url = _registeredUrls.entries
          .firstWhere((e) => e.value == targetIndex,
              orElse: () => MapEntry('', -1))
          .key;

      if (url.isNotEmpty &&
          !_localKeys.contains(url) &&
          !_preloadQueueSet.contains(url)) {
        targets.add(url);
        _preloadQueueSet.add(url);
      }
    }

    // Also look behind 1 item for back navigation
    final prevIndex = _activeIndex! - 1;
    final prevUrl = _registeredUrls.entries
        .firstWhere((e) => e.value == prevIndex, orElse: () => MapEntry('', -1))
        .key;
    if (prevUrl.isNotEmpty &&
        !_localKeys.contains(prevUrl) &&
        !_preloadQueueSet.contains(prevUrl)) {
      targets.add(prevUrl);
      _preloadQueueSet.add(prevUrl);
    }

    _preloadQueue.addAll(targets);
    _processQueue();
  }

  /// Legacy method for manual page change notification.
  ///
  /// Use [VideoStreamPlayer.priorityIndex] instead for automatic tracking.
  @Deprecated(
      'Use VideoStreamPlayer.priorityIndex for automatic preload tracking')
  void onPageChanged(int currentIndex, List<String> urls) {
    for (int i = 0; i < urls.length; i++) {
      register(urls[i], i);
    }
    notifyActive(currentIndex);
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _isDisposed) return;
    _isProcessing = true;

    try {
      while (_preloadQueue.isNotEmpty && !_isDisposed) {
        // Pause processing when app is in background
        if (_isPaused) {
          debugPrint('PreloadManager: Paused - waiting for resume');
          break;
        }

        if (!precacheEnabled) {
          _preloadQueue.clear();
          _preloadQueueSet.clear();
          break;
        }

        if (kIsWeb && !precacheWeb) {
          _preloadQueue.clear();
          _preloadQueueSet.clear();
          break;
        }

        if (!kIsWeb && !precacheMobile) {
          _preloadQueue.clear();
          _preloadQueueSet.clear();
          break;
        }

        final url = _preloadQueue.removeFirst();
        _preloadQueueSet.remove(url);

        // Never fetch injected (bytes/file) keys over HTTP
        if (_localKeys.contains(url)) continue;

        // Check if we should still preload this (is it still near active index?)
        // If user scrolled fast, this URL might now be far away
        final index = _registeredUrls[url];
        if (index != null && _activeIndex != null) {
          if ((index - _activeIndex!).abs() > preloadCount + 1) {
            continue; // Skip, too far now
          }
        }

        try {
          final status = await _cacheManager.getStatus(url);
          if (status == CacheStatus.none) {
            debugPrint('PreloadManager: Starting precache for $url');
            await _cacheManager.precache(url, bytes: preloadBytes);
          }
        } catch (e) {
          debugPrint('PreloadManager: Error precaching $url: $e');
          // Continue with next URL
        }
      }
    } finally {
      _isProcessing = false;
    }
  }

  void precache(List<String> urls) {
    if (_isDisposed) return;
    for (final url in urls) {
      if (!_preloadQueueSet.contains(url)) {
        _preloadQueue.add(url);
        _preloadQueueSet.add(url);
      }
    }
    _processQueue();
  }

  // ============ Lifecycle Methods ============

  @override
  void onPaused() {
    if (_isPaused) return;
    _isPaused = true;
    debugPrint('PreloadManager: Paused (app in background)');
  }

  @override
  void onResumed() {
    if (!_isPaused) return;
    _isPaused = false;
    debugPrint('PreloadManager: Resumed (app in foreground)');
    // Resume processing if there are queued items
    if (_preloadQueue.isNotEmpty) {
      _processQueue();
    }
  }

  /// Whether preloading is currently paused.
  bool get isPaused => _isPaused;

  /// Dispose and clean up resources.
  void dispose() {
    _isDisposed = true;
    _preloadQueue.clear();
    _preloadQueueSet.clear();
    _registeredUrls.clear();
    _localKeys.clear();
    _activeIndex = null;

    // Unregister from lifecycle observer
    VideoStreamLifecycleObserver.instance.removeListener(this);
  }
}
