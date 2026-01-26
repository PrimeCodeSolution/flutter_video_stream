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
