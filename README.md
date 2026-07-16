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
- **Bring Your Own Bytes** - Inject decrypted/local content via `VideoSource.bytes` (e.g. E2EE attachments)
- **Web Support** - Browser autoplay policy handling with user interaction detection
- **Cross-Platform** - Works on Android, iOS, and Web

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_video_stream: ^0.3.0
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

### Bring your own bytes (encrypted content)

Some content can't be fetched by the package over HTTP — for example
end-to-end encrypted attachments (Matrix, Signal-style protocols) that your
app must download and decrypt itself. Hand the plaintext bytes over with
`VideoSource.bytes` and the package takes care of caching, controller
pooling, and playback from there. The package stays protocol-agnostic: it
never sees ciphertext, keys, or your transport.

```dart
// 1. Your app downloads and decrypts (you own this part)
final encrypted = await myTransport.download(attachmentUrl);
final bytes = await myCrypto.decrypt(encrypted);

// 2. Hand the plaintext to the player. `key` is any stable unique id
//    (e.g. the message/event ID) — it plays the same role a URL plays for
//    fetched videos: caching, pooling, and dedup are all keyed by it.
VideoStreamPlayer(
  source: VideoSource.bytes(
    bytes,
    key: message.id,
    mimeType: 'video/mp4', // optional hint
  ),
);
```

You can also push content into the cache before any player exists, e.g.
after a background download completes:

```dart
await VideoStream.precacheBytes(message.id, bytes);
```

Content that is already on disk skips the copy in memory:

```dart
VideoStreamPlayer(
  source: VideoSource.file('/path/to/decrypted.mp4', key: message.id),
);
```

Injected content participates in the cache like fetched content — it counts
toward `getCacheSize()`, is evicted by the size cap once out of view, and can
be removed with `removeFromCache(key)`. The package **never** fetches an
injected key over HTTP, so if its cache entry was evicted and it can't be
re-materialized locally (evicted `VideoSource.file` whose file is gone), the
player surfaces `VideoStreamErrorType.sourceNotCached`. Your app re-downloads,
re-decrypts, and re-injects:

```dart
VideoStreamPlayer(
  source: VideoSource.file(cachePath, key: message.id),
  onError: (error) async {
    if (error.type == VideoStreamErrorType.sourceNotCached) {
      final bytes = await myApp.redownloadAndDecrypt(message.id);
      await VideoStream.precacheBytes(message.id, bytes);
      // rebuild the player (e.g. via setState) to retry
    }
  },
);
```

`VideoSource.bytes` self-heals: if its cache entry was evicted, the bytes it
carries are transparently re-injected on the next acquire — no error, no
network.

### Bring your own UI (VideoSession)

If you build your own player chrome instead of using `VideoStreamPlayer`,
acquire a `VideoSession`: a handle that owns exactly one reference to the
shared pooled controller. No key→source maps, no refcount bookkeeping, no
registry of "other videos I must pause" — the package does all of that.

```dart
class _MyPlayerState extends State<MyPlayer> {
  VideoSession? _session;

  Future<void> _init() async {
    final session = await VideoStream.acquire(
      VideoSource.bytes(decryptedBytes, key: message.id),
    );
    if (!mounted) {
      session.release();
      return;
    }
    setState(() => _session = session);
    await session.play(); // exclusive: pauses every other video first
  }

  @override
  Widget build(BuildContext context) => _session == null
      ? const CircularProgressIndicator()
      : VideoPlayer(_session!.controller); // your own controls around it

  @override
  void dispose() {
    _session?.release(); // exactly once; the pool keeps it warm for reuse
    super.dispose();
  }
}
```

Opening the same video on another screen (e.g. fullscreen) joins the same
controller by key — playback continues seamlessly, no second player:

```dart
// Fullscreen page: only the key travels through the route.
final session = await VideoStream.attach(key);
// session.controller is the SAME controller the inline tile uses.
```

`attach(key)` joins a live or warm controller, re-materializes from the
cache, or — for http(s) URL keys — refetches. For an injected key with
nothing recoverable it throws `VideoSourceNotCachedException`, so the app
can re-download/re-inject.

`session.play()` is exclusive by default and shares its exclusion primitive
(`VideoStream.pauseAllExcept`) with `VideoStreamPlayer` — a session video
and a widget video never play at the same time.

When two widgets share one controller during a handoff, only one should
render the texture. `VideoStream.surfaceArbiter` is a canonical
`ChangeNotifier` answering who:

```dart
VideoStream.surfaceArbiter.claim('fullscreen:$key');   // page takes over
// inline tile listens and renders a thumbnail while it is not the owner
VideoStream.surfaceArbiter.release('fullscreen:$key'); // page pops
```

Need iOS videos to survive route pushes (or other `VideoPlayerOptions`)?
Set them globally or per source; with a shared controller, the first
creation for a key wins:

```dart
await VideoStream.initialize(
  config: VideoStreamConfig(
    playerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
  ),
);
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
| `precacheBytes()` | Push caller-supplied bytes into the cache by key |
| `getCacheStatus()` | Get cache status for a URL or source key |
| `getCacheSize()` | Get total cache size in bytes |
| `clearCache()` | Clear all cached videos |
| `removeFromCache()` | Remove specific video from cache |
| `dispose()` | Dispose all resources |

### VideoStreamPlayer

The main widget for video playback.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `url` | `String?` | – | Video URL (MP4 or HLS); or use `source` |
| `source` | `VideoSource?` | – | URL, caller-supplied bytes, or file |
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
