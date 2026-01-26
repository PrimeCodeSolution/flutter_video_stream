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
/// - [VideoStreamConfig] - Configuration options
/// - [VideoStreamController] - Global playback controller
/// - [CacheManager] - Cache interface and status
library;

export 'src/video_stream.dart';
export 'src/video_stream_player.dart';
export 'src/config/video_stream_config.dart';
export 'src/cache/cache_manager.dart';
export 'src/controller/video_stream_controller.dart';
export 'src/lifecycle/lifecycle_observer.dart' show MemoryPressureLevel;
export 'src/utils/metrics.dart';
export 'src/utils/retry_helper.dart' show RetryConfig, RetryHelper;
export 'src/utils/bandwidth_throttler.dart' show BandwidthThrottler;
