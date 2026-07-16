import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'source/video_source.dart';
import 'video_stream.dart';
import 'controller/video_stream_controller.dart';

/// Types of errors that can occur during video playback
enum VideoStreamErrorType {
  /// Network-related error (connection failed, timeout, etc.)
  network,

  /// Server returned an error status code
  server,

  /// Video format is unsupported or corrupted
  format,

  /// Video source not found (404)
  notFound,

  /// An injected ([VideoSource.bytes] / [VideoSource.file]) source's content
  /// is not in the cache (e.g. it was evicted) and cannot be re-materialized
  /// locally. The app owns fetching: re-download, re-decrypt, and re-inject
  /// via [VideoStream.precacheBytes] — the package never fetches injected
  /// keys over HTTP.
  sourceNotCached,

  /// General playback error
  playback,

  /// Unknown error
  unknown,
}

/// Detailed error information for video playback failures
class VideoStreamError {
  /// The type of error
  final VideoStreamErrorType type;

  /// Human-readable error message
  final String message;

  /// The URL (or [VideoSource.key] for injected sources) that failed
  final String url;

  /// The underlying exception, if any
  final Object? exception;

  /// HTTP status code, if applicable
  final int? statusCode;

  const VideoStreamError({
    required this.type,
    required this.message,
    required this.url,
    this.exception,
    this.statusCode,
  });

  @override
  String toString() => 'VideoStreamError($type): $message';
}

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
  ///
  /// Exactly one of [url] and [source] must be provided. Passing a URL here
  /// is equivalent to `source: VideoSource.url(url, headers: headers)`.
  final String? url;

  /// The source of the video to play — an alternative to [url] that also
  /// supports caller-supplied content:
  ///
  /// ```dart
  /// VideoStreamPlayer(
  ///   source: VideoSource.bytes(decryptedBytes, key: eventId),
  /// )
  /// ```
  ///
  /// See [VideoSource.url], [VideoSource.bytes], and [VideoSource.file].
  final VideoSource? source;

  /// Optional HTTP headers for the video request.
  ///
  /// Only used with [url]; when providing a [source], pass headers via
  /// [VideoSource.url] instead.
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

  /// Called when an error occurs during video loading or playback.
  ///
  /// Provides detailed error information including error type, message,
  /// and underlying exception for debugging and user feedback.
  final void Function(VideoStreamError)? onError;

  /// The index of this video in a list/feed for preload prioritization.
  ///
  /// When set, the preload manager will automatically cache nearby videos.
  /// Lower indices have higher priority.
  final int? priorityIndex;

  /// Creates a video stream player widget.
  ///
  /// Exactly one of [url] or [source] must be provided.
  const VideoStreamPlayer({
    super.key,
    this.url,
    this.source,
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
    this.onError,
    this.priorityIndex,
  }) : assert((url == null) != (source == null),
            'Provide exactly one of url or source');

  @override
  State<VideoStreamPlayer> createState() => _VideoStreamPlayerState();
}

class _VideoStreamPlayerState extends State<VideoStreamPlayer> {
  /// The session owning this widget's pool reference. The controller is
  /// shared with other sessions/players on the same key.
  VideoSession? _session;
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isBuffering = false;
  Object? _error;

  /// Guard to prevent concurrent initialization
  bool _isInitializing = false;
  String? _initializingKey;

  /// Bumped on every init request; a completing acquire only commits when
  /// its generation is still current. Catches A->B->A source flips that a
  /// key comparison alone would miss.
  int _initGeneration = 0;

  /// The effective source: [VideoStreamPlayer.source], or the legacy
  /// [VideoStreamPlayer.url] wrapped in a [VideoSource.url].
  VideoSource get _source =>
      widget.source ?? VideoSource.url(widget.url!, headers: widget.headers);

  /// Identity for caching, pooling and preload registration.
  String get _sourceKey => _source.key;

  static String _keyOf(VideoStreamPlayer w) =>
      (w.source ?? VideoSource.url(w.url!)).key;

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
    VideoStreamController.instance.setActiveController(_controller, _sourceKey);

    // Hide the play button immediately
    setState(() {});

    // Small delay to let the UI update before play
    await Future.delayed(const Duration(milliseconds: 50));

    if (!mounted || _session == null) return;

    try {
      // Exclusive: pauses any other playing video (session- or widget-based)
      await _session!.play();
    } catch (e) {
      debugPrint('Play failed after interaction: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    // Register this video with the manager. Injected (bytes/file) sources
    // are already local: they keep their feed index for neighbor lookups
    // but are never preloaded over HTTP.
    VideoStream.instance.preloadManager.register(
        _sourceKey, widget.priorityIndex,
        preloadable: _source is UrlVideoSource);

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
    final oldKey = _keyOf(oldWidget);
    if (oldKey != _sourceKey) {
      // Move the preload registration to the new source
      VideoStream.instance.preloadManager.unregister(oldKey);
      VideoStream.instance.preloadManager.register(
          _sourceKey, widget.priorityIndex,
          preloadable: _source is UrlVideoSource);
      // The old session is bound to the old key; releasing it is all the
      // bookkeeping a key change needs.
      _disposeController();
      _initializePlayer();
    } else {
      // Handle autoPlay toggle (e.g. scrolling in feed)
      // Note: On web, autoplay is disabled so this only affects pause
      if (oldWidget.autoPlay != widget.autoPlay) {
        // Defer play/pause to after the build phase to avoid setState during build
        WidgetsBinding.instance.addPostFrameCallback((_) async {
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
                .setActiveController(_controller, _sourceKey);

            // Exclusive play: pauses any other playing video
            await _session?.play();
            // A fast scroll can deactivate this item while the exclusion
            // round-trip above was in flight - don't leave it playing
            // offscreen.
            if (!mounted || !_effectiveAutoPlay) {
              _controller?.pause();
            }
          } else if (!widget.autoPlay) {
            // Changed to false -> Pause (works on all platforms)
            _controller?.pause();
          }
        });
      }

      // Update registration if index changes
      if (oldWidget.priorityIndex != widget.priorityIndex) {
        VideoStream.instance.preloadManager.register(
            _sourceKey, widget.priorityIndex,
            preloadable: _source is UrlVideoSource);
      }
    }
  }

  Future<void> _initializePlayer() async {
    final source = _source;
    final key = source.key;

    // Guard against concurrent initialization for the same source
    if (_isInitializing && _initializingKey == key) return;

    _isInitializing = true;
    _initializingKey = key;
    final generation = ++_initGeneration;

    try {
      // Reset state
      setState(() {
        _isInitialized = false;
        _error = null;
      });

      final session = await VideoStream.acquire(source);

      // Only commit if this is still the newest init request for the
      // current source - otherwise release and let the newer one take over
      if (!mounted || generation != _initGeneration || _sourceKey != key) {
        session.release();
        return;
      }
      _session = session;
      _controller = session.controller;

      _controller!.addListener(_onPlayerUpdate);

      if (_controller!.value.isInitialized) {
        await _onInitialized();
      } else {
        // Should be initialized by acquire, but just in case
        await _controller!.initialize();
        await _onInitialized();
      }
    } catch (e) {
      // A stale init's failure must not clobber the current source's state
      if (mounted && generation == _initGeneration && _sourceKey == key) {
        final error = _createError(e, key);
        setState(() => _error = error);
        widget.onError?.call(error);
      }
    } finally {
      if (_initializingKey == key) {
        _isInitializing = false;
      }
    }
  }

  /// Get icon for error type
  IconData _getErrorIcon(VideoStreamErrorType type) {
    switch (type) {
      case VideoStreamErrorType.network:
        return Icons.wifi_off;
      case VideoStreamErrorType.server:
        return Icons.cloud_off;
      case VideoStreamErrorType.notFound:
        return Icons.search_off;
      case VideoStreamErrorType.sourceNotCached:
        return Icons.file_download_off;
      case VideoStreamErrorType.format:
        return Icons.videocam_off;
      case VideoStreamErrorType.playback:
        return Icons.error_outline;
      case VideoStreamErrorType.unknown:
        return Icons.error;
    }
  }

  /// Get title for error type
  String _getErrorTitle(VideoStreamErrorType type) {
    switch (type) {
      case VideoStreamErrorType.network:
        return 'Network Error';
      case VideoStreamErrorType.server:
        return 'Server Error';
      case VideoStreamErrorType.notFound:
        return 'Video Not Found';
      case VideoStreamErrorType.sourceNotCached:
        return 'Content Not Available';
      case VideoStreamErrorType.format:
        return 'Unsupported Format';
      case VideoStreamErrorType.playback:
        return 'Playback Error';
      case VideoStreamErrorType.unknown:
        return 'Error';
    }
  }

  /// Create a VideoStreamError from an exception
  VideoStreamError _createError(Object e, String url) {
    // Typed errors first - no message sniffing needed
    if (e is VideoSourceNotCachedException) {
      return VideoStreamError(
        type: VideoStreamErrorType.sourceNotCached,
        message: e.message,
        url: url,
        exception: e,
      );
    }

    final message = e.toString();
    final lowerMessage = message.toLowerCase();

    VideoStreamErrorType type = VideoStreamErrorType.unknown;
    int? statusCode;

    // Detect error type from message
    if (lowerMessage.contains('socket') ||
        lowerMessage.contains('connection') ||
        lowerMessage.contains('network') ||
        lowerMessage.contains('timeout') ||
        lowerMessage.contains('host lookup')) {
      type = VideoStreamErrorType.network;
    } else if (lowerMessage.contains('404') || lowerMessage.contains('not found')) {
      type = VideoStreamErrorType.notFound;
      statusCode = 404;
    } else if (lowerMessage.contains('500') || lowerMessage.contains('server error')) {
      type = VideoStreamErrorType.server;
      statusCode = 500;
    } else if (lowerMessage.contains('format') ||
        lowerMessage.contains('codec') ||
        lowerMessage.contains('unsupported') ||
        lowerMessage.contains('invalid')) {
      type = VideoStreamErrorType.format;
    } else if (lowerMessage.contains('playback') || lowerMessage.contains('player')) {
      type = VideoStreamErrorType.playback;
    }

    // Try to extract status code from message
    final statusMatch = RegExp(r'(\d{3})').firstMatch(message);
    if (statusMatch != null && statusCode == null) {
      final code = int.tryParse(statusMatch.group(1)!);
      if (code != null && code >= 400 && code < 600) {
        statusCode = code;
        if (code >= 500) {
          type = VideoStreamErrorType.server;
        } else if (code == 404) {
          type = VideoStreamErrorType.notFound;
        }
      }
    }

    return VideoStreamError(
      type: type,
      message: message,
      url: url,
      exception: e,
      statusCode: statusCode,
    );
  }

  Future<void> _onInitialized() async {
    // Capture locally: the widget can be disposed (nulling the fields)
    // while the awaits below are in flight.
    final session = _session;
    if (!mounted || _controller == null || session == null) return;

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
            .setActiveController(_controller, _sourceKey);

        // Exclusive play: widget-based and session-based playback share
        // the same exclusion primitive and never overlap. Throws
        // StateError if the widget was disposed (session released) during
        // the awaits above - caught below like any init failure.
        await session.play();
        // Deactivated while initialization/exclusion was in flight (fast
        // feed scroll): don't leave this item playing offscreen.
        if (!mounted || !_effectiveAutoPlay) {
          await _controller?.pause();
        }
      }

      if (mounted) {
        setState(() => _isInitialized = true);
        widget.onInitialized?.call(_controller!);
      }
    } catch (e) {
      debugPrint('VideoStreamPlayer: Error in _onInitialized: $e');
      if (mounted) {
        final error = _createError(e, _sourceKey);
        setState(() => _error = error);
        widget.onError?.call(error);
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
    if (value.hasError && _error == null) {
      final error = VideoStreamError(
        type: VideoStreamErrorType.playback,
        message: value.errorDescription ?? 'Unknown playback error',
        url: _sourceKey,
      );
      setState(() => _error = error);
      widget.onError?.call(error);
    }
  }

  void _disposeController() {
    if (_controller != null) {
      _controller!.removeListener(_onPlayerUpdate);
      _controller = null;
    }
    _session?.release();
    _session = null;
  }

  @override
  void dispose() {
    // Clear active controller if this was the active video
    if (VideoStreamController.instance.activeUrl == _sourceKey) {
      VideoStreamController.instance.setActiveController(null, null);
    }

    VideoStream.instance.preloadManager.unregister(_sourceKey);
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      final errorObj = _error is VideoStreamError
          ? _error as VideoStreamError
          : VideoStreamError(
              type: VideoStreamErrorType.unknown,
              message: _error.toString(),
              url: _sourceKey,
            );

      return widget.errorBuilder?.call(context, errorObj) ??
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _getErrorIcon(errorObj.type),
                  color: Colors.red,
                  size: 48,
                ),
                const SizedBox(height: 8),
                Text(
                  _getErrorTitle(errorObj.type),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    errorObj.message,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
