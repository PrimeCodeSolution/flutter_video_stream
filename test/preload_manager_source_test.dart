// Tests for PreloadManager's handling of injected (non-preloadable) keys,
// written against the 0.2.0 design spec:
// register(String key, int? index, {bool preloadable = true}) — injected
// keys are never enqueued for precache but still occupy their index.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/src/cache/cache_manager.dart';
import 'package:flutter_video_stream/src/pool/preload_manager.dart';

/// Hand-rolled CacheManager fake that records every precache call.
/// getStatus always reports none so the preload queue always precaches.
class RecordingCacheManager implements CacheManager {
  /// URLs passed to precache, in call order.
  final List<String> precached = [];

  /// bytes argument per precache call, keyed by url.
  final Map<String, int?> precachedBytes = {};

  @override
  Future<void> initialize({
    bool keepCache = true,
    Duration cacheTTL = const Duration(days: 7),
    int memoryCacheSize = 100 * 1024 * 1024,
    int maxDiskCacheSize = 500 * 1024 * 1024,
    bool respondToMemoryPressure = true,
    double memoryPressureRetainPercent = 0.25,
    bool evictOnStartup = true,
    bool enableRetry = true,
    int maxRetries = 3,
    bool enableMetrics = true,
    int maxBandwidthBytesPerSecond = 0,
  }) async {}

  @override
  Future<String> getCacheUrl(String originalUrl,
          {Map<String, String>? headers}) async =>
      originalUrl;

  @override
  Future<void> precache(String url,
      {int? bytes, Map<String, String>? headers}) async {
    precached.add(url);
    precachedBytes[url] = bytes;
  }

  @override
  Future<void> putBytes(String key, Uint8List bytes,
      {String? mimeType, String? filename}) async {}

  @override
  Future<CacheStatus> getStatus(String url) async => CacheStatus.none;

  @override
  Future<void> remove(String url) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<int> getSize() async => 0;

  @override
  set activeKeysProvider(Set<String> Function()? provider) {}

  @override
  set onEvicted(void Function(String key)? callback) {}

  @override
  Future<void> evictIfNeeded() async {}

  @override
  void dispose() {}
}

void main() {
  late RecordingCacheManager cache;
  late PreloadManager manager;

  setUp(() {
    cache = RecordingCacheManager();
    manager = PreloadManager(
      cacheManager: cache,
      preloadCount: 2,
      preloadBytes: 1234,
    );
  });

  tearDown(() {
    manager.dispose();
  });

  group('injected (non-preloadable) keys', () {
    test('notifyActive precaches only URL neighbors, never the injected key',
        () async {
      manager.register('https://example.com/v0.mp4', 0);
      manager.register('https://example.com/v1.mp4', 1);
      manager.register('https://example.com/v2.mp4', 2);
      // Injected key sharing index 1 (e.g. an encrypted video in the feed).
      // Registered after the URL at the same index so neighbor lookup
      // order stays deterministic.
      manager.register('mx-injected-1', 1, preloadable: false);

      manager.notifyActive(0);
      await pumpEventQueue();

      expect(
        cache.precached,
        unorderedEquals(
            ['https://example.com/v1.mp4', 'https://example.com/v2.mp4']),
      );
      expect(cache.precached, isNot(contains('mx-injected-1')));
      // Preload requests carry the configured partial-preload byte budget.
      expect(cache.precachedBytes['https://example.com/v1.mp4'], 1234);
    });

    test('an injected key at a neighbor index does not block other URL '
        'neighbors from preloading', () async {
      manager.register('https://example.com/feed0.mp4', 0);
      // Index 1 is occupied ONLY by an injected key.
      manager.register('mx-injected-2', 1, preloadable: false);
      manager.register('https://example.com/feed2.mp4', 2);

      manager.notifyActive(0);
      await pumpEventQueue();

      // The injected key keeps its slot (never fetched), while the URL
      // neighbor at index 2 still preloads.
      expect(cache.precached, ['https://example.com/feed2.mp4']);
      expect(cache.precached, isNot(contains('mx-injected-2')));
    });

    test('re-registering a key as preloadable clears the injected marker',
        () async {
      // CONTRACT: register() with the default preloadable: true must undo a
      // previous non-preloadable registration for the same key (a feed slot
      // being reused for a URL source).
      manager.register('https://example.com/v0.mp4', 0);
      manager.register('https://example.com/swap.mp4', 1, preloadable: false);
      manager.register('https://example.com/swap.mp4', 1);

      manager.notifyActive(0);
      await pumpEventQueue();

      expect(cache.precached, contains('https://example.com/swap.mp4'));
    });
  });
}
