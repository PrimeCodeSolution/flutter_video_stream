import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'video_stream.dart';
import 'controller/video_stream_controller.dart';

/// A widget that displays a video player with automatic caching and pooling.
///
/// [VideoStreamPlayer] integrates with the [VideoStream] singleton to provide
/// efficient video playback with features like:
/// - Automatic caching of video data
/// - Controller pooling for memory efficiency
/// - Smart preloading based on [priorityIndex]
/// - Web autoplay policy handling
///
/// ## Example
///
/// ```dart
/// VideoStreamPlayer(
///   url: 'https://example.com/video.mp4',
///   autoPlay: true,
///   looping: true,
///   fit: BoxFit.cover,
///   priorityIndex: 0, // Position in feed for preload priority
///   onInitialized: (controller) {
///     print('Video ready to play');
///   },
/// )
/// ```
///
/// ## Feed Usage
///
/// When using in a scrollable feed (like TikTok), set [priorityIndex] to enable
/// smart preloading of nearby videos:
///
/// ```dart
/// PageView.builder(
///   itemBuilder: (context, index) {
///     return VideoStreamPlayer(
///       url: videoUrls[index],
///       priorityIndex: index,
///     );
///   },
/// )
/// ```
class VideoStreamPlayer extends StatefulWidget {
  /// The URL of the video to play (MP4 or HLS).
  final String url;

  /// Optional HTTP headers for the video request.
  final Map<String, String>? headers;

  /// Whether to start playing automatically when initialized.
  ///
  /// On web, autoplay only works after the user has interacted with a video.
  /// The first video will show a play button overlay.
  final bool autoPlay;

  /// Whether to loop the video continuously.
  final bool looping;

  /// Whether to start with audio muted.
  final bool muted;

  /// How to fit the video within its bounds.
  final BoxFit fit;

  /// Widget to display while the video is loading.
  final Widget? placeholder;

  /// Builder for custom error display.
  final Widget Function(BuildContext, Object)? errorBuilder;

  /// Called when the video controller is initialized and ready.
  final void Function(VideoPlayerController)? onInitialized;

  /// Called when buffering state changes.
  final void Function(bool)? onBuffering;

  /// Called periodically with current position and total duration.
  final void Function(Duration, Duration)? onProgress;

  /// Called when the video finishes playing (not called when looping).
  final VoidCallback? onCompleted;

  /// The index of this video in a list/feed for preload prioritization.
  ///
  /// When set, the preload manager will automatically cache nearby videos.
  /// Lower indices have higher priority.
  final int? priorityIndex;

  /// Creates a video stream player widget.
  const VideoStreamPlayer({
    super.key,
    required this.url,
    this.headers,
    this.autoPlay = true,
    this.looping = true,
    this.muted = false,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorBuilder,
    this.onInitialized,
    this.onBuffering,
    this.onProgress,
    this.onCompleted,
    this.priorityIndex,
  });

  @override
  State<VideoStreamPlayer> createState() => _VideoStreamPlayerState();
}

class _VideoStreamPlayerState extends State<VideoStreamPlayer> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isBuffering = false;
  Object? _error;

  /// Guard to prevent concurrent initialization
  bool _isInitializing = false;
  String? _initializingUrl;

  /// On web, autoplay only works after user has interacted with video.
  /// First video needs manual play, subsequent videos can autoplay.
  bool get _effectiveAutoPlay {
    if (!kIsWeb) return widget.autoPlay;
    // On web: autoplay works after first user interaction
    return widget.autoPlay &&
        VideoStreamController.instance.webUserHasInteracted;
  }

  /// Whether this video needs a play button (web first video only)
  bool get _needsPlayButton =>
      kIsWeb &&
      widget.autoPlay &&
      !VideoStreamController.instance.webUserHasInteracted &&
      _isInitialized;

  /// Play the video and mark user interaction for web autoplay policy
  Future<void> _playWithInteraction() async {
    if (_controller == null) return;

    // Mark interaction FIRST - this is the user gesture that unlocks autoplay
    VideoStreamController.instance.markWebUserInteracted();
    VideoStreamController.instance.setActiveController(_controller, widget.url);

    // Hide the play button immediately
    setState(() {});

    // Small delay to let the UI update before play
    await Future.delayed(const Duration(milliseconds: 50));

    if (!mounted || _controller == null) return;

    try {
      await _controller!.play();
    } catch (e) {
      debugPrint('Play failed after interaction: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    // Register this video with the manager
    VideoStream.instance.preloadManager
        .register(widget.url, widget.priorityIndex);

    // If we start as autoPlay, we are the active video (not on web)
    if (_effectiveAutoPlay && widget.priorityIndex != null) {
      VideoStream.instance.preloadManager.notifyActive(widget.priorityIndex!);
    }

    // Active videos initialize immediately, others are deferred to avoid
    // blocking the main thread with multiple simultaneous initializations
    if (widget.autoPlay) {
      _initializePlayer();
    } else {
      // Defer non-active video initialization with staggered delay
      // based on distance from active position to spread out the load
      final delay = Duration(milliseconds: 100 * (widget.priorityIndex ?? 1));
      Future.delayed(delay, () {
        if (mounted) {
          _initializePlayer();
        }
      });
    }
  }

  @override
  void didUpdateWidget(VideoStreamPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _disposeController();
      _initializePlayer();
    } else {
      // Handle autoPlay toggle (e.g. scrolling in feed)
      // Note: On web, autoplay is disabled so this only affects pause
      if (oldWidget.autoPlay != widget.autoPlay) {
        // Defer play/pause to after the build phase to avoid setState during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_effectiveAutoPlay) {
            // Changed to true -> Play (mobile only, never happens on web)
            // Notify manager we are now active
            if (widget.priorityIndex != null) {
              VideoStream.instance.preloadManager
                  .notifyActive(widget.priorityIndex!);
            }

            // Notify global controller this is now the active video
            VideoStreamController.instance
                .setActiveController(_controller, widget.url);

            _controller?.play();
          } else if (!widget.autoPlay) {
            // Changed to false -> Pause (works on all platforms)
            _controller?.pause();
          }
        });
      }

      // Update registration if index changes
      if (oldWidget.priorityIndex != widget.priorityIndex) {
        VideoStream.instance.preloadManager
            .register(widget.url, widget.priorityIndex);
      }
    }
  }

  Future<void> _initializePlayer() async {
    final url = widget.url;

    // Guard against concurrent initialization for the same URL
    if (_isInitializing && _initializingUrl == url) return;

    _isInitializing = true;
    _initializingUrl = url;

    try {
      // Reset state
      setState(() {
        _isInitialized = false;
        _error = null;
      });

      _controller = await VideoStream.instance.controllerPool.acquire(
        url,
        headers: widget.headers,
      );

      // Check if URL changed during async operation
      if (!mounted || widget.url != url) {
        // URL changed, release this controller and let the new one take over
        VideoStream.instance.controllerPool.release(url);
        return;
      }

      _controller!.addListener(_onPlayerUpdate);

      if (_controller!.value.isInitialized) {
        await _onInitialized();
      } else {
        // Should be initialized by acquire, but just in case
        await _controller!.initialize();
        await _onInitialized();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e);
      }
    } finally {
      if (_initializingUrl == url) {
        _isInitializing = false;
      }
    }
  }

  Future<void> _onInitialized() async {
    if (!mounted || _controller == null) return;

    try {
      if (widget.looping) {
        await _controller!.setLooping(true);
      }

      // Set volume based on muted setting
      if (widget.muted) {
        await _controller!.setVolume(0);
      } else {
        await _controller!.setVolume(1.0);
      }

      // Autoplay is completely disabled on web - users must tap to play
      if (_effectiveAutoPlay) {
        // Notify global controller this is now the active video
        VideoStreamController.instance
            .setActiveController(_controller, widget.url);

        await _controller!.play();
      }

      if (mounted) {
        setState(() => _isInitialized = true);
        widget.onInitialized?.call(_controller!);
      }
    } catch (e) {
      debugPrint('VideoStreamPlayer: Error in _onInitialized: $e');
      if (mounted) {
        setState(() => _error = e);
      }
    }
  }

  void _onPlayerUpdate() {
    if (_controller == null || !mounted) return;

    final value = _controller!.value;

    // Buffering state
    final isBuffering = value.isBuffering;
    if (isBuffering != _isBuffering) {
      _isBuffering = isBuffering;
      widget.onBuffering?.call(isBuffering);
    }

    // Progress
    widget.onProgress?.call(value.position, value.duration);

    // Completion
    if (value.position >= value.duration && value.duration > Duration.zero) {
      // If looping is handled by controller, we might just get a loop event essentially?
      // But if not looping, this fires one time.
      // If looping, position resets.
      // We can just rely on value.isCompleted only if not looping?
      // VideoPlayerController doesn't have isCompleted easily exposed for looping videos continuously firing.
      // But let's fire onCompleted when we hit end.
      if (!value.isPlaying && !value.isLooping) {
        widget.onCompleted?.call();
      }
    }

    // Error
    if (value.hasError) {
      setState(() => _error = value.errorDescription);
    }
  }

  void _disposeController() {
    if (_controller != null) {
      _controller!.removeListener(_onPlayerUpdate);
      VideoStream.instance.controllerPool.release(widget.url);
      _controller = null;
    }
  }

  @override
  void dispose() {
    // Clear active controller if this was the active video
    if (VideoStreamController.instance.activeUrl == widget.url) {
      VideoStreamController.instance.setActiveController(null, null);
    }

    VideoStream.instance.preloadManager.unregister(widget.url);
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return widget.errorBuilder?.call(context, _error!) ??
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error, color: Colors.red),
                Text('Error: $_error',
                    style: const TextStyle(color: Colors.white)),
              ],
            ),
          );
    }

    if (!_isInitialized || _controller == null) {
      return widget.placeholder ??
          const Center(child: CircularProgressIndicator());
    }

    final videoWidget = ClipRect(
      child: FittedBox(
        fit: widget.fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: _controller!.value.size.width,
          height: _controller!.value.size.height,
          child: VideoPlayer(_controller!),
        ),
      ),
    );

    // On web, show play button overlay for first video before user interaction
    if (_needsPlayButton) {
      return Stack(
        fit: StackFit.expand,
        children: [
          videoWidget,
          // Play button overlay
          Positioned.fill(
            child: GestureDetector(
              onTap: _playWithInteraction,
              child: Container(
                color: Colors.black38,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow,
                      size: 64,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return videoWidget;
  }
}
