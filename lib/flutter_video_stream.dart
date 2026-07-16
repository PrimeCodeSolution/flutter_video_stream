/// High-performance video streaming package for Flutter.
///
/// This library provides intelligent caching, controller pooling, and preloading
/// for smooth video playback in feed-style applications.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:flutter_video_stream/flutter_video_stream.dart';
///
/// // Initialize in main()
/// await VideoStream.initialize();
///
/// // Use in your widget tree
/// VideoStreamPlayer(
///   url: 'https://example.com/video.mp4',
///   autoPlay: true,
/// )
/// ```
///
/// ## Main Components
///
/// - [VideoStream] - Singleton for initialization and cache management
/// - [VideoStreamPlayer] - Widget for video playback
/// - [VideoSession] - Handle-based controller access for custom player UIs
/// - [VideoSource] - Video content descriptor (URL, caller-supplied bytes, or file)
/// - [VideoSurfaceArbiter] - Who-renders-the-texture arbiter for surface handoff
/// - [VideoStreamConfig] - Configuration options
/// - [VideoStreamController] - Global playback controller
/// - [CacheManager] - Cache interface and status
/// - [VideoStreamError] - Detailed error information
/// - [VideoStreamErrorType] - Error type classification
///
/// ## Bring your own bytes
///
/// For content the package cannot fetch itself (e.g. end-to-end encrypted
/// attachments the app downloads and decrypts), hand over plaintext bytes:
///
/// ```dart
/// await VideoStream.precacheBytes(eventId, decryptedBytes);
/// VideoStreamPlayer(source: VideoSource.bytes(decryptedBytes, key: eventId));
/// ```
library;

export 'src/session/video_surface_arbiter.dart';
export 'src/source/video_source.dart';
export 'src/video_stream.dart';
export 'src/video_stream_player.dart';
export 'src/config/video_stream_config.dart';
export 'src/cache/cache_manager.dart';
export 'src/controller/video_stream_controller.dart';
export 'src/lifecycle/lifecycle_observer.dart' show MemoryPressureLevel;
export 'src/utils/metrics.dart';
export 'src/utils/retry_helper.dart' show RetryConfig, RetryHelper;
export 'src/utils/bandwidth_throttler.dart' show BandwidthThrottler;
