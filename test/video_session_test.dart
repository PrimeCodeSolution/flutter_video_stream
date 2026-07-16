// Tests for the 0.3.0 handle-based session API, written against the
// design spec: VideoStream.acquire/attach + VideoSession refcounting,
// exclusive play (session <-> session and session <-> VideoStreamPlayer),
// VideoPlayerOptions passthrough, and the VideoSurfaceArbiter.
//
// The fakes mirror test/controller_pool_source_test.dart:
// - FakeVideoPlayerPlatform extends (not implements) VideoPlayerPlatform
//   from video_player_platform_interface 6.6.0 (video_player 2.10.1 drives
//   it via createWithOptions and awaits the `initialized` event).
// - FakePathProviderPlatform points getTemporaryDirectory() at a fresh
//   temp directory per test.
//
// VideoStream is a singleton guarded by _isInitialized; VideoStream.dispose()
// resets the guard, so each test runs initialize()/dispose() in
// setUp/tearDown.
//
// Pool internals (activeKeys) are only reachable through the
// VideoStream.instance.controllerPool getter, which 0.3.0 deprecates in
// favor of sessions (removal in 0.4.0) - hence the ignore below.
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player/video_player.dart'
    show VideoPlayerController, VideoPlayerOptions;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  FakePathProviderPlatform(this.temporaryPath);

  final String temporaryPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;
}

/// Minimal in-memory video player platform, a local copy of the fake in
/// controller_pool_source_test.dart (test files own their fakes). Records
/// every created DataSource, emits an `initialized` event so
/// VideoPlayerController.initialize() completes, and renders a SizedBox
/// from buildViewWithOptions so VideoPlayer widgets can be pumped.
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

/// testWidgets analogue of the plain-test eventually() helper: the widget's
/// init chain mixes real IO (cache lookups, which only progress on the real
/// event loop, via runAsync) with fake-zone microtasks (flushed by pump),
/// so both are driven until [condition] holds or ~2s of real time elapse.
Future<bool> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  return condition();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late FakeVideoPlayerPlatform fakePlatform;

  Future<void> initVideoStream({VideoPlayerOptions? playerOptions}) {
    return VideoStream.initialize(
      config: VideoStreamConfig(
        maxCacheSize: 500 * 1024 * 1024,
        useProxy: false,
        precache: false,
        useIsolates: false,
        respondToMemoryPressure: false,
        evictOnStartup: false,
        // Keeps unit tests free of WidgetsBinding observer registration
        // side effects (same as controller_pool_source_test.dart).
        pauseOnBackground: false,
        playerOptions: playerOptions,
      ),
    );
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('video_session_test');
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

  group('session join/release refcounting', () {
    test('two sessions on one key share one controller and one platform '
        'player; the key stays active until the last release', () async {
      const key = 'mx-session-refcount';
      final bytes = makeBytes(64);
      final pool = VideoStream.instance.controllerPool;

      final s1 = await VideoStream.acquire(VideoSource.bytes(bytes, key: key));
      final s2 = await VideoStream.acquire(VideoSource.bytes(bytes, key: key));

      expect(s1.key, key);
      expect(s2.key, key);
      expect(identical(s1.controller, s2.controller), isTrue);
      // Exactly one platform player was created for the key.
      expect(
        fakePlatform.calls.where((c) => c == 'createWithOptions'),
        hasLength(1),
      );

      s1.release();
      expect(pool.activeKeys, contains(key),
          reason: 'the second session still holds a reference');

      s2.release();
      expect(pool.activeKeys, isNot(contains(key)),
          reason: 'after the last release the key is only warm');
    });

    test('double release throws AssertionError in debug and does not '
        'double-decrement', () async {
      const key = 'mx-session-double-release';
      final bytes = makeBytes(64, 1);
      final pool = VideoStream.instance.controllerPool;

      final first =
          await VideoStream.acquire(VideoSource.bytes(bytes, key: key));
      first.release();

      // A session acquired before the double release must be unaffected
      // by it.
      final survivor =
          await VideoStream.acquire(VideoSource.bytes(bytes, key: key));
      expect(pool.activeKeys, contains(key));

      expect(() => first.release(), throwsAssertionError);
      expect(first.isReleased, isTrue);
      expect(pool.activeKeys, contains(key),
          reason: 'the failed second release must not have decremented the '
              'survivor\'s reference');

      survivor.release();
      expect(pool.activeKeys, isNot(contains(key)));
    });

    test('releasing one session while a sibling acquire is in flight leaves '
        'the sibling usable with no refcount leak', () async {
      const key = 'mx-session-inflight';
      final bytes = makeBytes(64, 2);
      final pool = VideoStream.instance.controllerPool;

      // Started without awaiting: both share one in-flight acquisition.
      final firstFuture =
          VideoStream.acquire(VideoSource.bytes(bytes, key: key));
      final secondFuture =
          VideoStream.acquire(VideoSource.bytes(bytes, key: key));

      final first = await firstFuture;
      final controller = first.controller;
      first.release();

      final second = await secondFuture;
      expect(second.isReleased, isFalse);
      expect(pool.activeKeys, contains(key),
          reason: 'the sibling session holds its own reference');
      expect(identical(second.controller, controller), isTrue);
      expect(
        fakePlatform.calls.where((c) => c == 'createWithOptions'),
        hasLength(1),
        reason: 'both acquires must have shared one acquisition',
      );

      // The surviving session's controller is fully usable.
      expect(second.controller.value.isInitialized, isTrue);
      await second.play(exclusive: false);
      expect(second.controller.value.isPlaying, isTrue);
      await second.pause();

      second.release();
      expect(pool.activeKeys, isNot(contains(key)),
          reason: 'refcount must balance out to zero');
    });

    test('a released session throws StateError from controller, play and '
        'pause, and reports isReleased', () async {
      const key = 'mx-session-after-release';
      final session = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(64, 3), key: key));

      expect(session.isReleased, isFalse);
      session.release();
      expect(session.isReleased, isTrue);

      expect(() => session.controller, throwsStateError);
      // Future.sync catches both a synchronous throw and a failed future.
      await expectLater(Future.sync(session.play), throwsStateError);
      await expectLater(Future.sync(session.pause), throwsStateError);
    });
  });

  group('attach', () {
    test('attach on a live key returns the same controller and joins the '
        'refcount', () async {
      const key = 'mx-session-attach-live';
      final bytes = makeBytes(48, 1);
      final pool = VideoStream.instance.controllerPool;

      final owner =
          await VideoStream.acquire(VideoSource.bytes(bytes, key: key));
      final attached = await VideoStream.attach(key);

      expect(identical(owner.controller, attached.controller), isTrue);
      expect(
        fakePlatform.calls.where((c) => c == 'createWithOptions'),
        hasLength(1),
      );

      owner.release();
      expect(pool.activeKeys, contains(key),
          reason: 'the attached session still holds a reference');

      attached.release();
      expect(pool.activeKeys, isNot(contains(key)));
    });

    test('attach on a warm key revives the pooled controller', () async {
      const key = 'mx-session-attach-warm';
      final pool = VideoStream.instance.controllerPool;

      final session = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(48, 2), key: key));
      final controller = session.controller;
      session.release();
      expect(pool.activeKeys, isNot(contains(key)),
          reason: 'controller is warm, not active');

      final attached = await VideoStream.attach(key);
      expect(identical(attached.controller, controller), isTrue,
          reason: 'the warm controller must be revived, not re-created');
      expect(pool.activeKeys, contains(key));

      attached.release();
    });

    test('attach materializes a precached key from the local cache, never '
        'as a network URL of the raw key', () async {
      const key = 'mx-session-attach-precached';
      await VideoStream.precacheBytes(key, makeBytes(64, 3));

      // No session was ever created for the key: attach must re-materialize
      // from the cache alone.
      final session = await VideoStream.attach(key);
      expect(session.controller.value.isInitialized, isTrue);

      expect(fakePlatform.dataSources, hasLength(1));
      final ds = fakePlatform.dataSources.single;
      expect(ds.sourceType, DataSourceType.file);
      expect(ds.uri, startsWith('file://'));
      expect(ds.uri, isNot(contains(key)),
          reason: 'the raw key must never be used as a playback URL');

      session.release();
    });

    test('attach on an unknown non-URL key throws '
        'VideoSourceNotCachedException', () async {
      await expectLater(
        VideoStream.attach('mx-session-unknown'),
        throwsA(
          isA<VideoSourceNotCachedException>()
              .having((e) => e.key, 'key', 'mx-session-unknown'),
        ),
      );
      expect(fakePlatform.dataSources, isEmpty);
    });

    test('attach on an uncached URL key re-materializes via the network '
        'flow', () async {
      const key = 'https://example.com/attach.mp4';

      final session = await VideoStream.attach(key);

      expect(fakePlatform.dataSources, hasLength(1));
      final ds = fakePlatform.dataSources.single;
      expect(ds.sourceType, DataSourceType.network);
      expect(ds.uri, key);

      session.release();
    });
  });

  group('exclusive play', () {
    test('exclusive play pauses sessions on other keys; exclusive: false '
        'leaves them playing', () async {
      final a = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 21), key: 'mx-session-excl-a'));
      final b = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 22), key: 'mx-session-excl-b'));

      await a.play();
      expect(a.controller.value.isPlaying, isTrue);

      await b.play(); // exclusive by default
      expect(a.controller.value.isPlaying, isFalse,
          reason: 'exclusive play must pause other playing keys');
      expect(b.controller.value.isPlaying, isTrue);

      await a.play(exclusive: false);
      expect(a.controller.value.isPlaying, isTrue);
      expect(b.controller.value.isPlaying, isTrue,
          reason: 'non-exclusive play must not touch other keys');

      await a.pause();
      await b.pause();
      a.release();
      b.release();
    });

    test('same-key sibling sessions never pause each other', () async {
      const key = 'mx-session-excl-siblings';
      final bytes = makeBytes(32, 23);

      final s1 = await VideoStream.acquire(VideoSource.bytes(bytes, key: key));
      final s2 = await VideoStream.acquire(VideoSource.bytes(bytes, key: key));

      await s1.play();
      expect(s1.controller.value.isPlaying, isTrue);

      // video_player itself sends one platform pause per controller while
      // handling the `initialized` event, so count from here on.
      final pausesBefore =
          fakePlatform.calls.where((c) => c == 'pause').length;

      await s2.play(); // exclusive, but the only other holder is a sibling
      expect(s2.controller.value.isPlaying, isTrue,
          reason: 'the shared controller must still be playing');
      expect(fakePlatform.calls.where((c) => c == 'pause').length,
          pausesBefore,
          reason: 'siblings share one controller and are never paused by '
              'each other');

      await s1.pause();
      s1.release();
      s2.release();
    });

    test('VideoStream.pauseAllExcept pauses every other playing pooled '
        'controller', () async {
      const keptKey = 'mx-session-pae-kept';
      final kept = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 24), key: keptKey));
      final other = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 25), key: 'mx-session-pae-other'));

      await kept.play(exclusive: false);
      await other.play(exclusive: false);
      expect(kept.controller.value.isPlaying, isTrue);
      expect(other.controller.value.isPlaying, isTrue);

      await VideoStream.pauseAllExcept(keptKey);

      expect(kept.controller.value.isPlaying, isTrue);
      expect(other.controller.value.isPlaying, isFalse);

      await kept.pause();
      kept.release();
      other.release();
    });

    testWidgets('an exclusive session play pauses a playing '
        'VideoStreamPlayer widget', (tester) async {
      const widgetUrl = 'https://example.com/widget.mp4';
      VideoPlayerController? widgetController;

      await tester.pumpWidget(
        MaterialApp(
          home: VideoStreamPlayer(
            url: widgetUrl,
            autoPlay: true,
            muted: true,
            onInitialized: (controller) => widgetController = controller,
          ),
        ),
      );

      final widgetPlaying = await pumpUntil(
          tester, () => widgetController?.value.isPlaying ?? false);
      expect(widgetPlaying, isTrue,
          reason: 'the autoPlay widget must be playing before the session '
              'contends for exclusivity');

      late VideoSession session;
      await tester.runAsync(() async {
        session = await VideoStream.acquire(VideoSource.bytes(
            makeBytes(40, 7),
            key: 'mx-session-widget-rival'));
        await session.play(); // exclusive by default
      });
      await tester.pump();

      expect(session.controller.value.isPlaying, isTrue);
      expect(widgetController!.value.isPlaying, isFalse,
          reason: 'exclusive session play must pause the widget-owned '
              'controller');

      // Leave nothing playing: a playing controller keeps a periodic
      // position timer alive, which testWidgets flags as pending.
      await tester.runAsync(() async {
        await session.pause();
        session.release();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('playerOptions passthrough', () {
    test('config playerOptions reach both the networkUrl and the file '
        'creation sites', () async {
      await VideoStream.dispose();
      await initVideoStream(
          playerOptions: VideoPlayerOptions(allowBackgroundPlayback: true));

      // URL flow -> VideoPlayerController.networkUrl site.
      final urlSession = await VideoStream.acquire(
          const VideoSource.url('https://example.com/options-config.mp4'));
      expect(
          urlSession.controller.videoPlayerOptions?.allowBackgroundPlayback,
          isTrue);

      // Bytes flow -> local file constructor site.
      final bytesSession = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 11), key: 'mx-session-options-bytes'));
      expect(
          bytesSession.controller.videoPlayerOptions?.allowBackgroundPlayback,
          isTrue);

      urlSession.release();
      bytesSession.release();
    });

    test('per-source playerOptions win over config playerOptions', () async {
      await VideoStream.dispose();
      await initVideoStream(
          playerOptions: VideoPlayerOptions(allowBackgroundPlayback: true));

      final session = await VideoStream.acquire(VideoSource.url(
        'https://example.com/options-override.mp4',
        playerOptions: VideoPlayerOptions(mixWithOthers: true),
      ));

      final options = session.controller.videoPlayerOptions;
      expect(options?.mixWithOthers, isTrue);
      expect(options?.allowBackgroundPlayback, isFalse,
          reason: 'the source options object replaces the config options '
              'wholesale; they are not merged');

      session.release();
    });

    test('first creation wins: a same-key acquire with different options '
        'joins the existing controller unchanged', () async {
      const url = 'https://example.com/options-first-wins.mp4';

      final first = await VideoStream.acquire(VideoSource.url(url,
          playerOptions: VideoPlayerOptions(mixWithOthers: true)));
      final second = await VideoStream.acquire(VideoSource.url(url,
          playerOptions: VideoPlayerOptions(allowBackgroundPlayback: true)));

      expect(identical(first.controller, second.controller), isTrue);
      expect(
        fakePlatform.calls.where((c) => c == 'createWithOptions'),
        hasLength(1),
      );

      final options = second.controller.videoPlayerOptions;
      expect(options?.mixWithOthers, isTrue,
          reason: 'the first creation\'s options must survive');
      expect(options?.allowBackgroundPlayback, isFalse,
          reason: 'the second source\'s options must have been ignored');

      first.release();
      second.release();
    });
  });

  group('VideoSurfaceArbiter', () {
    test('claim and release notify exactly once, with owner-guarded release',
        () {
      final arbiter = VideoSurfaceArbiter();
      var notifications = 0;
      arbiter.addListener(() => notifications++);

      arbiter.claim('mx-surface-inline');
      expect(arbiter.owner, 'mx-surface-inline');
      expect(notifications, 1);

      arbiter.claim('mx-surface-inline');
      expect(notifications, 1,
          reason: 're-claiming the owned surface must not notify');

      arbiter.release('mx-surface-fullscreen');
      expect(arbiter.owner, 'mx-surface-inline',
          reason: 'a release by a non-owner is a no-op');
      expect(notifications, 1);

      arbiter.release('mx-surface-inline');
      expect(arbiter.owner, isNull);
      expect(notifications, 2);
    });

    test('VideoStream.surfaceArbiter is one global instance and works '
        'without initialize()', () async {
      // Tear VideoStream down: the arbiter must be usable regardless.
      await VideoStream.dispose();

      final arbiter = VideoStream.surfaceArbiter;
      expect(identical(arbiter, VideoStream.surfaceArbiter), isTrue);

      arbiter.claim('mx-surface-global');
      expect(arbiter.owner, 'mx-surface-global');

      // The global instance outlives tests: leave it unowned.
      arbiter.release('mx-surface-global');
      expect(arbiter.owner, isNull);
    });
  });

  group('review regressions (0.3.0)', () {
    test('releasing the last reference pauses a still-playing controller '
        '(no ownerless ghost audio)', () async {
      const key = 'mx-session-ghost';
      final bytes = makeBytes(32, 31);

      final session =
          await VideoStream.acquire(VideoSource.bytes(bytes, key: key));
      final controller = session.controller;
      await session.play();
      expect(controller.value.isPlaying, isTrue);

      session.release();
      // The pause is fire-and-forget; let it land.
      await Future<void>.delayed(Duration.zero);

      expect(controller.value.isPlaying, isFalse,
          reason: 'a zero-refcount controller must not keep playing');
    });

    test('a session released during the exclusive-play round-trip never '
        'starts its controller', () async {
      // Another key must be playing so pauseAllExcept actually awaits,
      // opening the release window.
      final other = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 32), key: 'mx-session-cancel-other'));
      await other.play();

      const key = 'mx-session-cancel';
      final session = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 33), key: key));
      final controller = session.controller;

      // Start the exclusive play, then release before the pause round-trip
      // completes.
      final playFuture = session.play();
      session.release();
      await playFuture;

      expect(controller.value.isPlaying, isFalse,
          reason: 'a released session must never start playback');
      other.release();
    });

    test('two racing exclusive plays end with exactly one video playing '
        '(last one wins)', () async {
      final a = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 34), key: 'mx-session-race-a'));
      final b = await VideoStream.acquire(
          VideoSource.bytes(makeBytes(32, 35), key: 'mx-session-race-b'));

      await Future.wait([a.play(), b.play()]);

      final playing = [
        if (a.controller.value.isPlaying) 'a',
        if (b.controller.value.isPlaying) 'b',
      ];
      expect(playing, ['b'],
          reason: 'exclusive plays are serialized last-wins');

      await b.pause();
      a.release();
      b.release();
    });

    test('an acquire holding bytes is not poisoned by joining a doomed '
        'attach on the same key', () async {
      const key = 'mx-session-doomed-join';
      final bytes = makeBytes(48, 36);

      // attach() registers its in-flight acquisition synchronously and is
      // doomed (nothing cached, not a URL). The acquire joins it, sees the
      // failure, and must retry with its own bytes instead of failing.
      // The expectation is attached immediately so the attach error is
      // never unhandled while the acquire is awaited.
      final attachExpectation = expectLater(VideoStream.attach(key),
          throwsA(isA<VideoSourceNotCachedException>()));
      final session =
          await VideoStream.acquire(VideoSource.bytes(bytes, key: key));

      await attachExpectation;
      expect(session.controller.value.isInitialized, isTrue);
      expect(await VideoStream.getCacheStatus(key), CacheStatus.complete);
      session.release();
    });
  });
}
