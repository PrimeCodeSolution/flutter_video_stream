# flutter_video_stream

[![pub package](https://img.shields.io/pub/v/flutter_video_stream.svg)](https://pub.dev/packages/flutter_video_stream)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

High-performance video streaming package for Flutter with intelligent caching, controller pooling, and preloading. Build TikTok-style video feeds with smooth scrolling and instant playback.

## Features

- **Intelligent Caching** - LRU disk and memory cache with configurable size limits
- **Controller Pooling** - Efficient video controller reuse to minimize memory usage
- **Smart Preloading** - Automatically preloads upcoming videos for seamless playback
- **Play-While-Download** - Localhost proxy server streams video while caching (mobile)
- **HLS Support** - Adaptive bitrate streaming with quality selection
- **MP4 Chunking** - Range request support for efficient streaming
- **Web Support** - Browser autoplay policy handling with user interaction detection
- **Cross-Platform** - Works on Android, iOS, and Web

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_video_stream: ^0.1.0
```

## Quick Start

```dart
import 'package:flutter_video_stream/flutter_video_stream.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize with default config
  await VideoStream.initialize();

  runApp(MyApp());
}
```

```dart
// Use the VideoStreamPlayer widget
VideoStreamPlayer(
  url: 'https://example.com/video.mp4',
  autoPlay: true,
  looping: true,
)
```

## Usage

### Basic Video Player

```dart
VideoStreamPlayer(
  url: 'https://example.com/video.mp4',
  autoPlay: true,
  looping: true,
  muted: false,
  fit: BoxFit.cover,
  placeholder: Center(child: CircularProgressIndicator()),
  errorBuilder: (context, error) => Center(
    child: Text('Error: $error'),
  ),
  onInitialized: (controller) {
    print('Video initialized');
  },
  onCompleted: () {
    print('Video completed');
  },
)
```

### Custom Configuration

```dart
await VideoStream.initialize(
  config: VideoStreamConfig(
    maxCacheSize: 500 * 1024 * 1024,      // 500MB disk cache
    maxMemoryCacheSize: 100 * 1024 * 1024, // 100MB memory cache
    preloadCount: 2,                       // Preload 2 videos ahead
    preloadBytes: 2 * 1024 * 1024,         // Preload 2MB per video
    poolSize: 3,                           // Max 3 concurrent controllers
    useProxy: true,                        // Enable proxy (mobile only)
    precacheMobile: true,                  // Enable precaching on mobile
    precacheWeb: false,                    // Disable precaching on web
  ),
);
```

### TikTok-Style Feed

```dart
class VideoFeed extends StatelessWidget {
  final List<String> videoUrls;

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      scrollDirection: Axis.vertical,
      itemCount: videoUrls.length,
      itemBuilder: (context, index) {
        return VideoStreamPlayer(
          url: videoUrls[index],
          autoPlay: true,
          looping: true,
          priorityIndex: index, // Enables smart preloading
          fit: BoxFit.cover,
        );
      },
    );
  }
}
```

### Precaching Videos

```dart
// Precache a list of videos
await VideoStream.precache([
  'https://example.com/video1.mp4',
  'https://example.com/video2.mp4',
]);

// Check cache status
final status = await VideoStream.getCacheStatus(url);
if (status == CacheStatus.complete) {
  print('Video is fully cached');
}
```

### Controlling Playback

```dart
// Access the global controller for the active video
final controller = VideoStream.controller;

// Play/Pause
controller.play();
controller.pause();
controller.togglePlayPause();

// Mute/Unmute
controller.mute();
controller.unmute();
controller.toggleMute();

// Seek
controller.seekTo(Duration(seconds: 30));
```

### Cache Management

```dart
// Get total cache size
final size = await VideoStream.getCacheSize();
print('Cache size: ${size / 1024 / 1024} MB');

// Remove specific video from cache
await VideoStream.removeFromCache(url);

// Clear all cache
await VideoStream.clearCache();
```

### Cleanup

```dart
// Dispose when done (e.g., in app lifecycle)
await VideoStream.dispose();
```

## Platform Setup

### Android (Proxy Server)

If using `useProxy: true`, add network security config for localhost traffic.

Create `android/app/src/main/res/xml/network_security_config.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

Reference it in `android/app/src/main/AndroidManifest.xml`:

```xml
<application
    android:networkSecurityConfig="@xml/network_security_config"
    ...>
```

### iOS (Proxy Server)

If using `useProxy: true`, add to `ios/Runner/Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

## API Reference

### VideoStream

The main singleton class for package initialization and control.

| Method | Description |
|--------|-------------|
| `initialize()` | Initialize the package with optional config |
| `precache()` | Precache a list of video URLs |
| `getCacheStatus()` | Get cache status for a URL |
| `getCacheSize()` | Get total cache size in bytes |
| `clearCache()` | Clear all cached videos |
| `removeFromCache()` | Remove specific video from cache |
| `dispose()` | Dispose all resources |

### VideoStreamPlayer

The main widget for video playback.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `url` | `String` | required | Video URL (MP4 or HLS) |
| `autoPlay` | `bool` | `true` | Auto-start playback |
| `looping` | `bool` | `true` | Loop video |
| `muted` | `bool` | `false` | Start muted |
| `fit` | `BoxFit` | `contain` | Video fit mode |
| `priorityIndex` | `int?` | `null` | Index for preload priority |
| `placeholder` | `Widget?` | `null` | Loading placeholder |
| `errorBuilder` | `Function?` | `null` | Error widget builder |
| `onInitialized` | `Function?` | `null` | Called when ready |
| `onCompleted` | `Function?` | `null` | Called when finished |

### VideoStreamConfig

Configuration options for the package.

| Option | Default | Description |
|--------|---------|-------------|
| `maxCacheSize` | 500MB | Maximum disk cache size |
| `maxMemoryCacheSize` | 100MB | Maximum memory cache size |
| `preloadCount` | 2 | Videos to preload ahead |
| `preloadBytes` | 2MB | Bytes to preload per video |
| `poolSize` | 3 | Max concurrent controllers |
| `useProxy` | false | Enable localhost proxy |
| `precache` | true | Enable precaching |
| `keepCache` | true | Persist cache between sessions |
| `cacheTTL` | 7 days | Cache time-to-live |

## License

MIT License - see [LICENSE](LICENSE) for details.
