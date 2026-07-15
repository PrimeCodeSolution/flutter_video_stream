// Tests for the rewritten WebCacheManager, written against the 0.2.0
// design spec. Runs on the VM: the ObjectUrlStore seam is injected with a
// fake, so no browser APIs are touched (the conditional import falls back
// to the stub, which is never used here).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/src/cache/cache_manager.dart';
import 'package:flutter_video_stream/src/cache/object_url_store.dart';
import 'package:flutter_video_stream/src/cache/web_cache_manager.dart';

/// Records every created/revoked URL and serves deterministic 'blob:fake-N'
/// URLs.
class FakeObjectUrlStore implements ObjectUrlStore {
  final List<String> created = [];
  final List<String> revoked = [];
  int _counter = 0;

  @override
  String createObjectUrl(Uint8List bytes, String mimeType) {
    final url = 'blob:fake-${_counter++}';
    created.add(url);
    return url;
  }

  @override
  void revokeObjectUrl(String url) {
    revoked.add(url);
  }
}

/// A store whose createObjectUrl always throws, forcing the data-URI
/// fallback path.
class ThrowingObjectUrlStore implements ObjectUrlStore {
  final List<String> revoked = [];

  @override
  String createObjectUrl(Uint8List bytes, String mimeType) {
    throw UnsupportedError('object URLs unavailable');
  }

  @override
  void revokeObjectUrl(String url) {
    revoked.add(url);
  }
}

Uint8List makeBytes(int length, [int seed = 0]) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i + seed) % 251));

void main() {
  group('putBytes / getCacheUrl', () {
    test('serves injected bytes through the created blob URL', () async {
      final store = FakeObjectUrlStore();
      final cache = WebCacheManager(objectUrlStore: store);
      await cache.initialize(maxDiskCacheSize: 1024);

      final bytes = makeBytes(100);
      await cache.putBytes('mx-web-1', bytes);

      expect(store.created, ['blob:fake-0']);
      expect(await cache.getCacheUrl('mx-web-1'), 'blob:fake-0');
      expect(await cache.getStatus('mx-web-1'), CacheStatus.complete);
      expect(await cache.getSize(), bytes.length);
    });

    test('unknown keys pass through unchanged (browser handles URL flow)',
        () async {
      final cache = WebCacheManager(objectUrlStore: FakeObjectUrlStore());
      await cache.initialize(maxDiskCacheSize: 1024);

      const url = 'https://example.com/feed/video.mp4';
      expect(await cache.getCacheUrl(url), url);
      expect(await cache.getStatus(url), CacheStatus.none);
    });
  });

  group('LRU eviction at the initialize() cap', () {
    test('evicts least-recently-used entry and revokes its object URL',
        () async {
      final store = FakeObjectUrlStore();
      final cache = WebCacheManager(objectUrlStore: store);
      // Cap fits two 100-byte payloads but not three.
      await cache.initialize(maxDiskCacheSize: 250);

      await cache.putBytes('mx-a', makeBytes(100, 1)); // blob:fake-0
      await cache.putBytes('mx-b', makeBytes(100, 2)); // blob:fake-1

      // Touch A so B becomes the least recently used.
      // CONTRACT: getCacheUrl hits LRU-touch the entry.
      expect(await cache.getCacheUrl('mx-a'), 'blob:fake-0');

      await cache.putBytes('mx-c', makeBytes(100, 3)); // evicts B

      expect(store.revoked, ['blob:fake-1']);

      // Evicted key falls back to pass-through and reads as not cached.
      expect(await cache.getCacheUrl('mx-b'), 'mx-b');
      expect(await cache.getStatus('mx-b'), CacheStatus.none);

      // Survivors are unaffected.
      expect(await cache.getStatus('mx-a'), CacheStatus.complete);
      expect(await cache.getStatus('mx-c'), CacheStatus.complete);
      expect(await cache.getSize(), 200);
    });
  });

  group('remove / clear', () {
    test('remove revokes the object URL and shrinks the size', () async {
      final store = FakeObjectUrlStore();
      final cache = WebCacheManager(objectUrlStore: store);
      await cache.initialize(maxDiskCacheSize: 1024);

      await cache.putBytes('mx-r1', makeBytes(60)); // blob:fake-0
      await cache.putBytes('mx-r2', makeBytes(40)); // blob:fake-1

      await cache.remove('mx-r1');

      expect(store.revoked, ['blob:fake-0']);
      expect(await cache.getStatus('mx-r1'), CacheStatus.none);
      expect(await cache.getCacheUrl('mx-r1'), 'mx-r1');
      expect(await cache.getSize(), 40);
    });

    test('clear revokes every object URL and resets the size to 0', () async {
      final store = FakeObjectUrlStore();
      final cache = WebCacheManager(objectUrlStore: store);
      await cache.initialize(maxDiskCacheSize: 1024);

      await cache.putBytes('mx-c1', makeBytes(60)); // blob:fake-0
      await cache.putBytes('mx-c2', makeBytes(40)); // blob:fake-1

      await cache.clear();

      expect(store.revoked, unorderedEquals(['blob:fake-0', 'blob:fake-1']));
      expect(await cache.getSize(), 0);
      expect(await cache.getStatus('mx-c1'), CacheStatus.none);
      expect(await cache.getStatus('mx-c2'), CacheStatus.none);
    });
  });

  group('data-URI fallback', () {
    test('falls back to a base64 data URI when createObjectUrl throws',
        () async {
      final cache = WebCacheManager(objectUrlStore: ThrowingObjectUrlStore());
      await cache.initialize(maxDiskCacheSize: 1024);

      final bytes = makeBytes(90);
      await cache.putBytes('mx-data-uri', bytes);

      final url = await cache.getCacheUrl('mx-data-uri');
      const prefix = 'data:video/mp4;base64,';
      expect(url, startsWith(prefix));
      expect(base64Decode(url.substring(prefix.length)), bytes);

      expect(await cache.getStatus('mx-data-uri'), CacheStatus.complete);
      expect(await cache.getSize(), bytes.length);
    });

    test('data URI uses the provided mimeType', () async {
      final cache = WebCacheManager(objectUrlStore: ThrowingObjectUrlStore());
      await cache.initialize(maxDiskCacheSize: 1024);

      await cache.putBytes('mx-data-webm', makeBytes(10),
          mimeType: 'video/webm');

      expect(
        await cache.getCacheUrl('mx-data-webm'),
        startsWith('data:video/webm;base64,'),
      );
    });
  });

  group('putBytes argument validation', () {
    test('empty bytes throws ArgumentError (the only ArgumentError case)',
        () async {
      final cache = WebCacheManager(objectUrlStore: FakeObjectUrlStore());
      await cache.initialize(maxDiskCacheSize: 100);

      await expectLater(
        cache.putBytes('mx-empty', Uint8List(0)),
        throwsA(isA<ArgumentError>()),
      );
      expect(await cache.getStatus('mx-empty'), CacheStatus.none);
    });
  });

  group('surfaced-video pinning', () {
    test('active (surfaced) keys are never evicted; LRU falls to the next '
        'non-surfaced entry', () async {
      final store = FakeObjectUrlStore();
      final cache = WebCacheManager(objectUrlStore: store);
      await cache.initialize(maxDiskCacheSize: 250);
      cache.activeKeysProvider = () => {'mx-a'};

      await cache.putBytes('mx-a', makeBytes(100, 1)); // blob:fake-0
      await cache.putBytes('mx-b', makeBytes(100, 2)); // blob:fake-1

      await cache.putBytes('mx-c', makeBytes(100, 3)); // must evict B, not A

      expect(store.revoked, ['blob:fake-1']);
      expect(await cache.getStatus('mx-a'), CacheStatus.complete);
      expect(await cache.getStatus('mx-b'), CacheStatus.none);
      expect(await cache.getStatus('mx-c'), CacheStatus.complete);
      expect(await cache.getSize(), 200);
    });

    test('cache may legitimately stay over the cap when everything is '
        'surfaced', () async {
      final store = FakeObjectUrlStore();
      final cache = WebCacheManager(objectUrlStore: store);
      await cache.initialize(maxDiskCacheSize: 250);
      cache.activeKeysProvider = () => {'mx-a', 'mx-b'};

      await cache.putBytes('mx-a', makeBytes(100, 1));
      await cache.putBytes('mx-b', makeBytes(100, 2));
      // A and B are surfaced, C is protected during its own injection pass:
      // nothing is evictable and the put must still terminate and store.
      await cache.putBytes('mx-c', makeBytes(100, 3));

      expect(store.revoked, isEmpty);
      expect(await cache.getStatus('mx-a'), CacheStatus.complete);
      expect(await cache.getStatus('mx-b'), CacheStatus.complete);
      expect(await cache.getStatus('mx-c'), CacheStatus.complete);
      expect(await cache.getSize(), 300);
    });

    test('soft cap: oversized bytes are stored and servable, then reclaimed '
        'by evictIfNeeded once out of view', () async {
      final store = FakeObjectUrlStore();
      final cache = WebCacheManager(objectUrlStore: store);
      await cache.initialize(maxDiskCacheSize: 100);
      const key = 'mx-soft-cap';
      final bytes = makeBytes(150);

      cache.activeKeysProvider = () => <String>{};

      // Larger than the cap, but stored anyway.
      await cache.putBytes(key, bytes);
      expect(await cache.getCacheUrl(key), 'blob:fake-0');
      expect(await cache.getStatus(key), CacheStatus.complete);
      expect(await cache.getSize(), 150);

      // Surfaced -> an explicit eviction pass must keep it.
      cache.activeKeysProvider = () => {key};
      await cache.evictIfNeeded();
      expect(await cache.getStatus(key), CacheStatus.complete);
      expect(store.revoked, isEmpty);

      // Out of view -> reclaimed (evictIfNeeded fits the cache back under
      // the cap) and its object URL revoked.
      cache.activeKeysProvider = () => <String>{};
      await cache.evictIfNeeded();
      expect(await cache.getStatus(key), CacheStatus.none);
      expect(await cache.getCacheUrl(key), key);
      expect(await cache.getSize(), 0);
      expect(store.revoked, ['blob:fake-0']);
    });
  });
}
