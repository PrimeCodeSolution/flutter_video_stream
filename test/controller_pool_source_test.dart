// End-to-end tests for the VideoSource path through VideoStream.initialize
// and ControllerPool.acquireSource, written against the 0.2.0 design spec.
// These deliberately exercise the raw pool API, deprecated for consumers
// in 0.3.0 in favor of VideoSession.
// ignore_for_file: deprecated_member_use_from_same_package
//
// Two fakes stand in for the platform:
// - FakeVideoPlayerPlatform extends (not implements) VideoPlayerPlatform
//   from video_player_platform_interface 6.6.0 (as resolved in
//   pubspec.lock; video_player 2.10.1 drives it via createWithOptions and
//   awaits the `initialized` event from videoEventsFor).
// - FakePathProviderPlatform points getTemporaryDirectory() at a fresh
//   temp directory per test, so the mobile cache manager works on real
//   files without touching the machine's shared temp cache.
//
// VideoStream is a singleton guarded by _isInitialized; VideoStream.dispose()
// resets the guard, so each test runs initialize()/dispose() in
// setUp/tearDown.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  FakePathProviderPlatform(this.temporaryPath);

  final String temporaryPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;
}

/// Minimal in-memory video player platform, cribbed from video_player
/// 2.10.1's own test fake. Records every created DataSource and emits an
/// `initialized` event so VideoPlayerController.initialize() completes.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<String> calls = <String>[];
  final List<DataSource> dataSources = <DataSource>[];
  final Map<int, StreamController<VideoEvent>> streams =
      <int, StreamController<VideoEvent>>{};
  int nextPlayerId = 0;
  final Map<int, Duration> _positions = <int, Duration>{};

  int _startPlayer(DataSource dataSource) {
    final stream = StreamController<VideoEvent>();
    streams[nextPlayerId] = stream;
    stream.add(VideoEvent(
      eventType: VideoEventType.initialized,
      size: const Size(100, 100),
      duration: const Duration(seconds: 1),
    ));
    dataSources.add(dataSource);
    return nextPlayerId++;
  }

  @override
  Future<void> init() async {
    calls.add('init');
  }

  // video_player 2.10.1 calls createWithOptions; create is kept as the
  // deprecated delegate target for completeness.
  @override
  // ignore: deprecated_member_use
  Future<int?> create(DataSource dataSource) async {
    calls.add('create');
    return _startPlayer(dataSource);
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('createWithOptions');
    return _startPlayer(options.dataSource);
  }

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await streams[playerId]?.close();
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return streams[playerId]!.stream;
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    calls.add('setLooping');
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    calls.add('setVolume');
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seekTo');
    _positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    calls.add('getPosition');
    return _positions[playerId] ?? Duration.zero;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    calls.add('setPlaybackSpeed');
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {
    calls.add('setMixWithOthers');
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    return const SizedBox();
  }
}

Uint8List makeBytes(int length, [int seed = 0]) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i + seed) % 251));

/// Polls [condition] until it holds or ~2s elapse. Used where the work under
/// test is fire-and-forget (pool release -> cacheManager.evictIfNeeded()).
Future<bool> eventually(Future<bool> Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return condition();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late FakeVideoPlayerPlatform fakePlatform;

  Future<void> initVideoStream({int maxCacheSize = 500 * 1024 * 1024}) {
    return VideoStream.initialize(
      config: VideoStreamConfig(
        maxCacheSize: maxCacheSize,
        useProxy: false,
        precache: false,
        useIsolates: false,
        respondToMemoryPressure: false,
        evictOnStartup: false,
        // Not in the spec's test matrix, but keeps unit tests free of
        // WidgetsBinding observer registration side effects.
        pauseOnBackground: false,
      ),
    );
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('pool_source_test');
    PathProviderPlatform.instance = FakePathProviderPlatform(tempRoot.path);
    fakePlatform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fakePlatform;

    await initVideoStream();
  });

  tearDown(() async {
    await VideoStream.dispose();
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  group('acquireSource pooling by key', () {
    test('precacheBytes then acquiring the same key twice reuses one '
        'controller', () async {
      const key = 'mx-event-pool-reuse';
      final bytes = makeBytes(64);

      await VideoStream.precacheBytes(key, bytes, mimeType: 'video/mp4');
      expect(await VideoStream.getCacheStatus(key), CacheStatus.complete);

      final pool = VideoStream.instance.controllerPool;
      // Two distinct source objects, same key -> identical controller.
      final first = await pool.acquireSource(VideoSource.bytes(bytes, key: key));
      final second =
          await pool.acquireSource(VideoSource.bytes(bytes, key: key));

      expect(identical(first, second), isTrue);
      // Only one platform player was created for the key.
      expect(
        fakePlatform.calls.where((c) => c == 'createWithOptions'),
        hasLength(1),
      );
    });

    test('URL sources still work through acquireSource and acquire', () async {
      const url = 'https://example.com/feed/video1.mp4';
      final pool = VideoStream.instance.controllerPool;

      final viaSource = await pool.acquireSource(const VideoSource.url(url));
      final viaLegacy = await pool.acquire(url);

      // acquire(url) delegates to acquireSource(VideoSource.url(url)):
      // same key, same pooled controller.
      expect(identical(viaSource, viaLegacy), isTrue);

      // The URL flow is unchanged: a network data source on the raw URL
      // (no cache hit, proxy disabled).
      final ds = fakePlatform.dataSources.last;
      expect(ds.sourceType, DataSourceType.network);
      expect(ds.uri, url);
    });
  });

  group('typed cache miss', () {
    test('file source with nothing cached and no file on disk throws '
        'VideoSourceNotCachedException', () async {
      final missingPath = '${tempRoot.path}/does_not_exist.mp4';
      final pool = VideoStream.instance.controllerPool;

      await expectLater(
        pool.acquireSource(VideoSource.file(missingPath, key: 'mx-missing')),
        throwsA(
          isA<VideoSourceNotCachedException>()
              .having((e) => e.key, 'key', 'mx-missing'),
        ),
      );

      // Nothing must have been created on the platform side, and nothing
      // was fetched or cached for the key.
      expect(fakePlatform.dataSources, isEmpty);
      expect(await VideoStream.getCacheStatus('mx-missing'), CacheStatus.none);
    });
  });

  group('self-heal for bytes sources', () {
    test('acquireSource re-injects bytes after the cache entry was removed',
        () async {
      const key = 'mx-event-self-heal';
      final bytes = makeBytes(48, 3);

      await VideoStream.precacheBytes(key, bytes);
      await VideoStream.removeFromCache(key);
      expect(await VideoStream.getCacheStatus(key), CacheStatus.none);

      // The source still holds the bytes, so acquire must transparently
      // re-inject instead of throwing (spec: bytes sources self-heal).
      final controller = await VideoStream.instance.controllerPool
          .acquireSource(VideoSource.bytes(bytes, key: key));

      expect(controller, isNotNull);
      expect(await VideoStream.getCacheStatus(key), CacheStatus.complete);
    });
  });

  group('injected sources play from local files', () {
    test('controller for an injected source uses a file data source, never '
        'a network URL of the raw key', () async {
      const key = 'mx-event-datasource';
      final bytes = makeBytes(32, 9);

      await VideoStream.precacheBytes(key, bytes);
      await VideoStream.instance.controllerPool
          .acquireSource(VideoSource.bytes(bytes, key: key));

      expect(fakePlatform.dataSources, hasLength(1));
      final ds = fakePlatform.dataSources.single;

      expect(ds.sourceType, DataSourceType.file);
      // VideoPlayerController.file builds a file:// URI of the absolute
      // cache path (video_player 2.10.1).
      expect(ds.uri, startsWith('file://'));
      expect(ds.uri, contains('video_stream_cache'));
      // The raw key must never be used as a playback URL.
      expect(ds.uri, isNot(contains(key)));
    });
  });

  group('surfaced-video pinning: pool API', () {
    test('activeKeys tracks acquired keys and release fires onKeyReleased '
        'when refCount hits 0', () async {
      const key = 'mx-event-active';
      final bytes = makeBytes(32);
      final pool = VideoStream.instance.controllerPool;

      // Replaces the default wiring (-> cacheManager.evictIfNeeded) for
      // this test; a fresh VideoStream.initialize in setUp restores it.
      final released = <String>[];
      pool.onKeyReleased = released.add;

      await VideoStream.precacheBytes(key, bytes);
      await pool.acquireSource(VideoSource.bytes(bytes, key: key));

      expect(pool.activeKeys, contains(key));
      expect(released, isEmpty);

      pool.release(key);

      // refCount dropped to 0: no longer surfaced, callback fired once.
      expect(pool.activeKeys, isNot(contains(key)));
      expect(released, [key]);
    });

    test('releasing one of two holders keeps the key surfaced and does not '
        'fire onKeyReleased', () async {
      const key = 'mx-event-two-holders';
      final bytes = makeBytes(32, 5);
      final pool = VideoStream.instance.controllerPool;

      final released = <String>[];
      pool.onKeyReleased = released.add;

      await VideoStream.precacheBytes(key, bytes);
      await pool.acquireSource(VideoSource.bytes(bytes, key: key));
      await pool.acquireSource(VideoSource.bytes(bytes, key: key));

      pool.release(key);

      // Still one holder left: surfaced, no release event.
      expect(pool.activeKeys, contains(key));
      expect(released, isEmpty);
    });
  });

  group('surfaced-video pinning: VideoStream wiring', () {
    test('an over-cap injected key survives while surfaced and is reclaimed '
        'after its only player is released', () async {
      // Re-initialize with a tiny disk cap so a single 300-byte injection
      // is over cap (soft cap: stored anyway).
      await VideoStream.dispose();
      await initVideoStream(maxCacheSize: 200);

      const key = 'mx-event-overcap';
      final bytes = makeBytes(300);
      final pool = VideoStream.instance.controllerPool;

      await VideoStream.precacheBytes(key, bytes);
      expect(await VideoStream.getCacheStatus(key), CacheStatus.complete,
          reason: 'soft cap: oversized bytes must still be stored');

      await pool.acquireSource(VideoSource.bytes(bytes, key: key));

      // Surfaced (activeKeysProvider wiring): an explicit eviction pass
      // must not touch it.
      await VideoStream.instance.cacheManager.evictIfNeeded();
      expect(await VideoStream.getCacheStatus(key), CacheStatus.complete);

      // Releasing the only holder triggers onKeyReleased ->
      // evictIfNeeded() (fire-and-forget), which reclaims the over-cap
      // entry now that it is out of view.
      pool.release(key);

      final evicted = await eventually(
          () async => await VideoStream.getCacheStatus(key) == CacheStatus.none);
      expect(evicted, isTrue,
          reason: 'released over-cap entry must be reclaimed by the '
              'release -> evictIfNeeded wiring');
    });
  });

  group('warm controllers dropped on eviction (review regression)', () {
    test('removeFromCache drops a warm controller so re-acquire '
        're-materializes instead of returning a dead controller', () async {
      const key = 'mx-event-warm-drop';
      final bytes = makeBytes(32, 4);
      final pool = VideoStream.instance.controllerPool;

      final first =
          await pool.acquireSource(VideoSource.bytes(bytes, key: key));
      pool.release(key); // warm: refCount 0, still pooled

      await VideoStream.removeFromCache(key); // onEvicted -> dropWarm

      final second =
          await pool.acquireSource(VideoSource.bytes(bytes, key: key));

      expect(identical(first, second), isFalse,
          reason: 'a controller whose backing file was removed must not be '
              'reused from the warm pool');
      // The bytes source self-healed back into the cache.
      expect(await VideoStream.getCacheStatus(key), CacheStatus.complete);
      // One platform player per materialization.
      expect(
        fakePlatform.calls.where((c) => c == 'createWithOptions'),
        hasLength(2),
      );
    });

    test('clearCache drops all warm controllers', () async {
      const key = 'mx-event-clear-drop';
      final bytes = makeBytes(32, 5);
      final pool = VideoStream.instance.controllerPool;

      final first =
          await pool.acquireSource(VideoSource.bytes(bytes, key: key));
      pool.release(key);

      await VideoStream.clearCache();

      final second =
          await pool.acquireSource(VideoSource.bytes(bytes, key: key));
      expect(identical(first, second), isFalse);
    });
  });
}
