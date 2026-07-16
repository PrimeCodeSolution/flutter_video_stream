## 0.3.0

- **`VideoSession` — handle-based API for custom player UIs**
  - `VideoStream.acquire(source)` returns a session owning exactly one pool
    reference; same-key acquisitions join one shared controller (racing
    acquisitions share a single creation)
  - `VideoStream.attach(key)` joins a live/warm key without re-supplying the
    source; re-materializes from cache (or network for URL keys); throws
    `VideoSourceNotCachedException` for unknown keys
  - `session.release()` is exactly-once and idempotent (debug assert on
    double release); using a released session throws `StateError`
  - No more app-side key→source maps, refcount bookkeeping, or
    live-controller registries for custom UIs
- **Unified play exclusion**
  - `session.play()` (exclusive by default) and `VideoStream.pauseAllExcept(key)`
    pause every other playing video; same-key siblings are never paused
  - `VideoStreamPlayer` routes its play paths through the same primitive, so
    widget-based and session-based playback never overlap
- **`VideoPlayerOptions` passthrough**
  - `VideoStreamConfig.playerOptions` applies to every controller the package
    creates (e.g. `allowBackgroundPlayback: true` to survive iOS route pushes)
  - Optional per-source override `VideoSource.*(playerOptions:)`; with a
    shared controller the first creation for a key wins
- **`VideoSurfaceArbiter`** (`VideoStream.surfaceArbiter`) — a canonical
  "who renders the texture" `ChangeNotifier` for inline↔fullscreen handoff
  with one shared controller
- `VideoStream.instance.controllerPool` is deprecated (removal in 0.4.0):
  use the session API instead

## 0.2.0

- **Bring your own bytes: `VideoSource` abstraction** for content the package
  cannot fetch itself (e.g. end-to-end encrypted attachments the app downloads
  and decrypts)
  - `VideoSource.url(url, headers:)` — existing HTTP flow, unchanged
  - `VideoSource.bytes(bytes, key:, mimeType:, filename:)` — caller-supplied
    plaintext bytes, keyed by a stable id (e.g. a Matrix event ID)
  - `VideoSource.file(path, key:)` — content already on disk
  - `VideoStreamPlayer` accepts `source:` as an alternative to `url:` (the
    `url:` parameter keeps working and forwards to `VideoSource.url`)
  - `VideoStream.precacheBytes(key, bytes)` to push content into the cache
    before a player exists (e.g. after a background download completes)
- Injected sources bypass the HTTP proxy entirely: played from the disk cache
  via file controllers on mobile, served through blob object URLs (with data
  URI fallback) on web
- Injected content participates in the existing cache LRU: counted by
  `getCacheSize()`, evicted by the size cap, removable via
  `removeFromCache(key)` / `clearCache()`
- Controller pooling and dedup work by source key: acquiring the same key
  twice (e.g. inline + fullscreen) reuses one controller
- New `VideoSourceNotCachedException` + `VideoStreamErrorType.sourceNotCached`
  when an injected source was evicted and cannot be re-materialized — the
  package never fetches injected keys over HTTP; the app re-downloads and
  re-injects
- **Surfaced videos are never evicted**: the cache size cap only applies to
  videos that are out of view. Content larger than the cap still plays (soft
  cap) and is reclaimed once its player is released
- Preloading treats injected sources as already-local no-ops without breaking
  preload of neighboring URL sources in feeds
- **Error callbacks and detailed error information**
  - New `onError` callback on `VideoStreamPlayer`
  - `VideoStreamError` class with type, message, URL, exception, and status code
  - `VideoStreamErrorType` enum: network, server, notFound, sourceNotCached,
    format, playback, unknown
  - Improved error UI with type-specific icons and messages
- **Proxy edge-case handling for videos with missing metadata**
  - Passthrough mode for chunked transfer encoding / missing Content-Length
  - Content length detection fallbacks (HEAD, Range GET, probe) without
    downloading the body
  - Servers that ignore Range requests are detected and served via direct
    streaming/passthrough instead of corrupting chunked playback
  - Recovery via direct range streaming when a chunk download fails

## 0.1.0

- Initial release
- `VideoStreamPlayer` widget for easy video playback
- Intelligent caching with LRU eviction (disk + memory)
- Smart preloading with size checks (skips files too large for cache)
- Partial preloading with Range requests (downloads only first N bytes)
- Controller pooling for efficient resource management
- Preload manager for smooth feed scrolling
- Localhost proxy server for play-while-download (mobile)
- HLS streaming support with adaptive quality
- MP4 chunked streaming with range requests
- Lifecycle-aware caching (pauses on background)
- Memory pressure handling
- Configurable via `VideoStreamConfig`
- Web platform support with autoplay policy handling
