import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// Factory function for conditional import
WebPreloader getWebPreloader() => WebPreloader._();

/// Web-specific video preloader.
/// Pre-initializes VideoPlayerControllers for upcoming videos.
/// When a controller is initialized on web, the browser starts buffering.
class WebPreloader {
  WebPreloader._();

  /// Pre-warmed controllers ready for instant playback
  final Map<String, _WarmController> _warmControllers = {};

  /// How many videos to pre-warm ahead
  final int warmCount = 2;

  /// Maximum controllers to keep warm (memory limit)
  final int maxWarmControllers = 4;

  /// Warm up a video URL by pre-initializing its controller
  void warmUp(String url, {Map<String, String>? headers}) {
    if (_warmControllers.containsKey(url)) return;

    debugPrint('WebPreloader: Warming up $url');
    _initializeController(url, headers);
  }

  /// Called when active video changes - warms up nearby videos
  void notifyActive(int index, Map<String, int> registeredUrls) {
    // Find URLs to warm: next N videos
    final urlsToWarm = <String>[];

    for (int i = 1; i <= warmCount; i++) {
      final targetIndex = index + i;
      final entry = registeredUrls.entries
          .where((e) => e.value == targetIndex)
          .firstOrNull;
      if (entry != null) {
        urlsToWarm.add(entry.key);
      }
    }

    // Also warm previous video for back navigation
    final prevEntry =
        registeredUrls.entries.where((e) => e.value == index - 1).firstOrNull;
    if (prevEntry != null) {
      urlsToWarm.add(prevEntry.key);
    }

    // Warm up the URLs
    for (final url in urlsToWarm) {
      warmUp(url);
    }

    // Evict controllers that are too far from current position
    _evictDistant(index, registeredUrls);
  }

  /// Get a pre-warmed controller if available
  VideoPlayerController? getWarmedController(String url) {
    final warm = _warmControllers[url];
    if (warm != null && warm.isReady) {
      debugPrint('WebPreloader: Using warmed controller for $url');
      // Remove from warm pool - it's now being used
      _warmControllers.remove(url);
      return warm.controller;
    }
    return null;
  }

  Future<void> _initializeController(
      String url, Map<String, String>? headers) async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: headers ?? {},
      );

      final warm = _WarmController(
        url: url,
        controller: controller,
        createdAt: DateTime.now(),
      );

      _warmControllers[url] = warm;

      await controller.initialize();
      warm.isReady = true;

      debugPrint('WebPreloader: Warmed up $url');

      // Evict if over limit
      _evictIfNeeded();
    } catch (e) {
      debugPrint('WebPreloader: Failed to warm $url: $e');
      _warmControllers.remove(url);
    }
  }

  void _evictIfNeeded() {
    if (_warmControllers.length <= maxWarmControllers) return;

    // Remove oldest controllers
    final sorted = _warmControllers.entries.toList()
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));

    while (_warmControllers.length > maxWarmControllers && sorted.isNotEmpty) {
      final oldest = sorted.removeAt(0);
      debugPrint('WebPreloader: Evicting ${oldest.key}');
      oldest.value.controller.dispose();
      _warmControllers.remove(oldest.key);
    }
  }

  void _evictDistant(int currentIndex, Map<String, int> registeredUrls) {
    // Remove controllers that are too far from current position
    final toRemove = <String>[];

    for (final url in _warmControllers.keys) {
      final index = registeredUrls[url];
      if (index == null) continue;

      final distance = (index - currentIndex).abs();
      if (distance > warmCount + 2) {
        toRemove.add(url);
      }
    }

    for (final url in toRemove) {
      debugPrint('WebPreloader: Evicting distant $url');
      _warmControllers[url]?.controller.dispose();
      _warmControllers.remove(url);
    }
  }

  void dispose() {
    for (final warm in _warmControllers.values) {
      warm.controller.dispose();
    }
    _warmControllers.clear();
  }
}

class _WarmController {
  final String url;
  final VideoPlayerController controller;
  final DateTime createdAt;
  bool isReady = false;

  _WarmController({
    required this.url,
    required this.controller,
    required this.createdAt,
  });
}
