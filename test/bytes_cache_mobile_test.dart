// Tests for MobileCacheManager.putBytes and injected-key cache semantics,
// written against the 0.2.0 design spec.
//
// The real file system is used via a fresh temp directory per test, with a
// FakePathProviderPlatform pointing getTemporaryDirectory() at it. The fake
// extends (not implements) PathProviderPlatform, matching path_provider
// 2.1.5 / path_provider_platform_interface 2.1.2 as resolved in
// pubspec.lock.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/src/cache/cache_manager.dart';
import 'package:flutter_video_stream/src/cache/mobile_cache_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  FakePathProviderPlatform(this.temporaryPath);

  final String temporaryPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;
}

/// The cache file name scheme: sha256 of the key (same as the URL flow).
String hashedName(String key) => sha256.convert(utf8.encode(key)).toString();

Uint8List makeBytes(int length, [int seed = 0]) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i + seed) % 251));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  MobileCacheManager? cache;

  Future<MobileCacheManager> newCache(
      {int maxDiskCacheSize = 500 * 1024 * 1024}) async {
    final manager = MobileCacheManager();
    await manager.initialize(
      keepCache: true,
      respondToMemoryPressure: false,
      evictOnStartup: false,
      maxDiskCacheSize: maxDiskCacheSize,
    );
    cache = manager;
    return manager;
  }

  Directory cacheDir() => Directory('${tempRoot.path}/video_stream_cache');

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('bytes_cache_test');
    PathProviderPlatform.instance = FakePathProviderPlatform(tempRoot.path);
  });

  tearDown(() async {
    cache?.dispose();
    cache = null;
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  group('putBytes basics', () {
    test('getCacheUrl returns a local file path with the injected content',
        () async {
      final manager = await newCache();
      const key = 'mx-event-basic';
      final bytes = makeBytes(64);

      await manager.putBytes(key, bytes);

      final url = await manager.getCacheUrl(key);
      expect(url, isNot(key));
      expect(url, startsWith(cacheDir().path));

      final file = File(url);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), bytes);
    });

    test('getStatus is complete after putBytes and none after remove',
        () async {
      final manager = await newCache();
      const key = 'mx-event-status';

      expect(await manager.getStatus(key), CacheStatus.none);

      await manager.putBytes(key, makeBytes(32));
      expect(await manager.getStatus(key), CacheStatus.complete);

      await manager.remove(key);
      expect(await manager.getStatus(key), CacheStatus.none);
      // Removed entries resolve back to the raw key.
      expect(await manager.getCacheUrl(key), key);
    });

    test('getSize includes injected bytes and clear removes injected entries',
        () async {
      final manager = await newCache();

      expect(await manager.getSize(), 0);

      await manager.putBytes('mx-size-1', makeBytes(100));
      await manager.putBytes('mx-size-2', makeBytes(50, 7));

      // Disk holds the payloads (plus small metadata files) and the memory
      // cache holds a copy, so the total is at least the injected payload.
      expect(await manager.getSize(), greaterThanOrEqualTo(150));

      await manager.clear();
      expect(await manager.getSize(), 0);
      expect(await manager.getStatus('mx-size-1'), CacheStatus.none);
      expect(await manager.getStatus('mx-size-2'), CacheStatus.none);
    });
  });

  group('extension resolution', () {
    test("mimeType 'video/webm' stores a .webm file", () async {
      final manager = await newCache();
      const key = 'mx-event-webm';

      await manager.putBytes(key, makeBytes(16), mimeType: 'video/webm');

      final url = await manager.getCacheUrl(key);
      expect(url, endsWith('.webm'));
      expect(url, contains(hashedName(key)));
    });

    test('no hints defaults to .mp4', () async {
      final manager = await newCache();
      const key = 'mx-event-plain';

      await manager.putBytes(key, makeBytes(16));

      expect(await manager.getCacheUrl(key), endsWith('.mp4'));
    });

    test("filename 'clip.mov' stores a .mov file", () async {
      final manager = await newCache();
      const key = 'mx-event-mov';

      await manager.putBytes(key, makeBytes(16), filename: 'clip.mov');

      expect(await manager.getCacheUrl(key), endsWith('.mov'));
    });

    test('mimeType wins over filename when both are given', () async {
      // CONTRACT: spec resolution order is mimeType map, then filename
      // suffix, then key suffix, then .mp4.
      final manager = await newCache();
      const key = 'mx-event-both-hints';

      await manager.putBytes(
        key,
        makeBytes(16),
        mimeType: 'video/webm',
        filename: 'clip.mov',
      );

      expect(await manager.getCacheUrl(key), endsWith('.webm'));
    });
  });

  group('LRU disk eviction', () {
    test('evicts the least-recently-accessed entry once over the cap',
        () async {
      // Cap fits two 100-byte payloads but not three.
      final manager = await newCache(maxDiskCacheSize: 250);

      // Eviction sorts by metadata lastAccessed, which putBytes stamps with
      // DateTime.now(). Small delays keep the timestamps strictly ordered.
      // putBytes also invalidates the 30s metadata cache, so each eviction
      // pass sees fresh metadata.
      await manager.putBytes('mx-lru-a', makeBytes(100, 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.putBytes('mx-lru-b', makeBytes(100, 2));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.putBytes('mx-lru-c', makeBytes(100, 3));

      // A is the least recently accessed -> evicted; B and C survive.
      expect(await manager.getStatus('mx-lru-a'), CacheStatus.none);
      expect(await manager.getStatus('mx-lru-b'), CacheStatus.complete);
      expect(await manager.getStatus('mx-lru-c'), CacheStatus.complete);
    });
  });

  group('putBytes argument validation', () {
    test('empty bytes throws ArgumentError', () async {
      final manager = await newCache();

      await expectLater(
        manager.putBytes('mx-empty', Uint8List(0)),
        throwsA(isA<ArgumentError>()),
      );
      expect(await manager.getStatus('mx-empty'), CacheStatus.none);
    });
  });

  group('surfaced-video pinning', () {
    test('active (surfaced) keys are never evicted; LRU falls to the next '
        'non-surfaced entry', () async {
      final manager = await newCache(maxDiskCacheSize: 250);
      manager.activeKeysProvider = () => {'mx-pin-a'};

      await manager.putBytes('mx-pin-a', makeBytes(100, 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.putBytes('mx-pin-b', makeBytes(100, 2));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.putBytes('mx-pin-c', makeBytes(100, 3));

      // A is the LRU entry but surfaced -> skipped; B is the oldest
      // non-surfaced entry -> evicted; C is the just-injected key
      // (extraProtected during its own pass) -> kept.
      expect(await manager.getStatus('mx-pin-a'), CacheStatus.complete);
      expect(await manager.getStatus('mx-pin-b'), CacheStatus.none);
      expect(await manager.getStatus('mx-pin-c'), CacheStatus.complete);
    });

    test('cache may legitimately stay over the cap when everything is '
        'surfaced', () async {
      final manager = await newCache(maxDiskCacheSize: 250);
      manager.activeKeysProvider = () => {'mx-full-a', 'mx-full-b'};

      await manager.putBytes('mx-full-a', makeBytes(100, 1));
      await manager.putBytes('mx-full-b', makeBytes(100, 2));
      await manager.putBytes('mx-full-c', makeBytes(100, 3));

      // Nothing is evictable: A and B are surfaced, C is protected during
      // its own injection pass. Total (300) stays over the cap (250).
      expect(await manager.getStatus('mx-full-a'), CacheStatus.complete);
      expect(await manager.getStatus('mx-full-b'), CacheStatus.complete);
      expect(await manager.getStatus('mx-full-c'), CacheStatus.complete);
    });

    test('soft cap: oversized bytes are stored and servable, then reclaimed '
        'by evictIfNeeded once out of view', () async {
      final manager = await newCache(maxDiskCacheSize: 250);
      const key = 'mx-soft-cap';
      final bytes = makeBytes(300);

      manager.activeKeysProvider = () => <String>{};

      // Larger than the cap, but stored anyway (the just-injected key is
      // protected during its own eviction pass).
      await manager.putBytes(key, bytes);
      final url = await manager.getCacheUrl(key);
      expect(url, isNot(key));
      expect(await File(url).readAsBytes(), bytes);
      expect(await manager.getStatus(key), CacheStatus.complete);

      // Surfaced -> an explicit eviction pass must keep it.
      manager.activeKeysProvider = () => {key};
      await manager.evictIfNeeded();
      expect(await manager.getStatus(key), CacheStatus.complete);

      // Out of view -> reclaimed.
      manager.activeKeysProvider = () => <String>{};
      await manager.evictIfNeeded();
      expect(await manager.getStatus(key), CacheStatus.none);
      // Disk eviction also drops the memory copy.
      expect(manager.getFromMemory(key), isNull);
    });

    test('disk eviction drops the evicted key from the memory cache too',
        () async {
      final manager = await newCache(maxDiskCacheSize: 250);

      await manager.putBytes('mx-mem-a', makeBytes(100, 1));
      expect(manager.getFromMemory('mx-mem-a'), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.putBytes('mx-mem-b', makeBytes(100, 2));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.putBytes('mx-mem-c', makeBytes(100, 3));

      // A was evicted from disk (see LRU test); its memory copy must be
      // gone as well, while survivors keep theirs.
      expect(await manager.getStatus('mx-mem-a'), CacheStatus.none);
      expect(manager.getFromMemory('mx-mem-a'), isNull);
      expect(manager.getFromMemory('mx-mem-c'), isNotNull);
    });
  });

  group('re-injection', () {
    test('same key with a different mimeType leaves exactly one cache file',
        () async {
      final manager = await newCache();
      const key = 'mx-event-reinject';

      await manager.putBytes(key, makeBytes(24), mimeType: 'video/mp4');
      await manager.putBytes(key, makeBytes(48, 5), mimeType: 'video/webm');

      final prefix = hashedName(key);
      final contentFiles = await cacheDir()
          .list()
          .where((e) => e is File)
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((name) => name.startsWith(prefix))
          .where((name) =>
              !name.endsWith('.cachemeta') &&
              !name.endsWith('.partial') &&
              !name.endsWith('.meta'))
          .toList();

      expect(contentFiles, hasLength(1),
          reason: 'stale file from the first injection must be deleted');
      expect(contentFiles.single, endsWith('.webm'));

      // The key resolves to the new file with the new content.
      final url = await manager.getCacheUrl(key);
      expect(url, endsWith('.webm'));
      expect(await File(url).readAsBytes(), makeBytes(48, 5));
    });
  });

  group('review regressions', () {
    test('key with an embedded extension and a conflicting mimeType stays '
        'servable', () async {
      // Regression: putBytes stored under the mimeType-derived extension
      // while lookup probed only the key-derived one, so the entry was
      // permanently unfindable (VideoSourceNotCachedException loop).
      final manager = await newCache();
      const key = 'trailer.mov';
      final bytes = makeBytes(40, 9);

      await manager.putBytes(key, bytes, mimeType: 'video/mp4');

      final url = await manager.getCacheUrl(key);
      expect(url, isNot(key));
      expect(await File(url).readAsBytes(), bytes);
      expect(await manager.getStatus(key), CacheStatus.complete);

      await manager.remove(key);
      expect(await manager.getStatus(key), CacheStatus.none);
      final leftovers = await cacheDir()
          .list()
          .where((e) => e.path.contains(hashedName(key)))
          .toList();
      expect(leftovers, isEmpty,
          reason: 'remove must find the file whatever extension it has');
    });

    test('URL-shaped key with a query string and no hints stays servable',
        () async {
      // Uri-path parsing sees ".webm" behind the query string while raw
      // suffix matching does not; store and lookup must agree.
      final manager = await newCache();
      const key = 'https://cdn.example.com/v.webm?tok=abc';

      await manager.putBytes(key, makeBytes(16, 11));

      expect(await manager.getCacheUrl(key), isNot(key));
      expect(await manager.getStatus(key), CacheStatus.complete);
    });

    test('precache refuses non-URL keys instead of attempting an HTTP fetch',
        () async {
      final manager = await newCache();
      const key = 'mx-event-no-http';

      // Returns promptly without throwing and without creating any files.
      await manager.precache(key).timeout(const Duration(seconds: 2));

      expect(await manager.getStatus(key), CacheStatus.none);
      final files = await cacheDir()
          .list()
          .where((e) => e.path.contains(hashedName(key)))
          .toList();
      expect(files, isEmpty);
    });
  });
}
