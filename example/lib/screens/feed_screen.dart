import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import '../data/sample_videos.dart';
import '../widgets/video_feed_item.dart';
import '../widgets/cache_status_overlay.dart';
import '../widgets/global_controls.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final PageController _pageController = PageController();
  final FocusNode _focusNode = FocusNode();
  int _currentPage = 0;

  // Cache status display (for demo purposes)
  final Map<String, String> _cacheStatuses = {};

  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _updateCacheStatuses();

    // Poll for cache status updates since downloads happen in background
    // Use a longer interval to reduce main thread load
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _updateCacheStatuses();
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _goToPrevious() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToNext() {
    if (_currentPage < sampleVideos.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _goToPrevious();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _goToNext();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _updateCacheStatuses() async {
    // Batch all status checks, then do ONE setState
    final newStatuses = <String, String>{};
    for (final video in sampleVideos) {
      final status = await VideoStream.getCacheStatus(video.url);
      newStatuses[video.url] = status.name;
    }
    if (mounted) {
      setState(() {
        _cacheStatuses.addAll(newStatuses);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Video PageView
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: sampleVideos.length,
              onPageChanged: (index) {
                final direction = index > _currentPage ? 'DOWN' : 'UP';
                final video = sampleVideos[index];
                debugPrint('FeedScreen: Scrolled $direction to index $index (${video.username})');

                setState(() => _currentPage = index);

                // Update cache status display
                _updateCacheStatuses();
              },
              itemBuilder: (context, index) {
                final video = sampleVideos[index];
                return VideoFeedItem(
                  video: video,
                  index: index,
                  isActive: index == _currentPage,
                  cacheStatus: _cacheStatuses[video.url] ?? 'unknown',
                );
              },
            ),

            // Fixed Navigation Buttons (overlay)
            Positioned(
              right: 16,
              bottom: 100,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_currentPage > 0)
                    FloatingActionButton(
                      heroTag: "nav_prev",
                      mini: true,
                      backgroundColor: Colors.black54,
                      onPressed: _goToPrevious,
                      child: const Icon(Icons.keyboard_arrow_up,
                          color: Colors.white, size: 28),
                    ),
                  if (_currentPage > 0 &&
                      _currentPage < sampleVideos.length - 1)
                    const SizedBox(height: 16),
                  if (_currentPage < sampleVideos.length - 1)
                    FloatingActionButton(
                      heroTag: "nav_next",
                      mini: true,
                      backgroundColor: Colors.black54,
                      onPressed: _goToNext,
                      child: const Icon(Icons.keyboard_arrow_down,
                          color: Colors.white, size: 28),
                    ),
                ],
              ),
            ),

            // Cache Status Overlay (demo only)
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 10,
              child: CacheStatusOverlay(
                statuses: _cacheStatuses,
                currentUrl: sampleVideos[_currentPage].url,
              ),
            ),

            // Global Controls
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              right: 10,
              child: const GlobalControls(),
            ),

            // Video Counter
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${_currentPage + 1} / ${sampleVideos.length}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
