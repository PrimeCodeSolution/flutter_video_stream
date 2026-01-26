import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import 'package:flutter_video_stream/src/cache/lru_memory_cache.dart';
import 'package:flutter_video_stream/src/parser/hls_parser.dart';

void main() {
  group('VideoStreamConfig', () {
    test('has correct default values', () {
      const config = VideoStreamConfig();

      expect(config.maxCacheSize, 500 * 1024 * 1024); // 500MB
      expect(config.maxMemoryCacheSize, 100 * 1024 * 1024); // 100MB
      expect(config.preloadCount, 2);
      expect(config.preloadBytes, 2 * 1024 * 1024); // 2MB
      expect(config.poolSize, 3);
      expect(config.logLevel, LogLevel.none);
      expect(config.precache, true);
      expect(config.precacheWeb, true);
      expect(config.precacheMobile, true);
      expect(config.keepCache, true);
      expect(config.cacheTTL, const Duration(days: 7));
      expect(config.useProxy, false);
      expect(config.useIsolates, true);
      expect(config.maxConcurrentDownloads, 3);
      expect(config.chunkSize, 2 * 1024 * 1024); // 2MB
    });

    test('accepts custom values', () {
      const config = VideoStreamConfig(
        maxCacheSize: 100 * 1024 * 1024,
        maxMemoryCacheSize: 50 * 1024 * 1024,
        preloadCount: 5,
        preloadBytes: 5 * 1024 * 1024,
        poolSize: 5,
        logLevel: LogLevel.verbose,
        precache: false,
        precacheWeb: false,
        precacheMobile: false,
        keepCache: false,
        cacheTTL: Duration(days: 1),
        useProxy: true,
        useIsolates: false,
        maxConcurrentDownloads: 5,
        chunkSize: 1 * 1024 * 1024,
      );

      expect(config.maxCacheSize, 100 * 1024 * 1024);
      expect(config.maxMemoryCacheSize, 50 * 1024 * 1024);
      expect(config.preloadCount, 5);
      expect(config.preloadBytes, 5 * 1024 * 1024);
      expect(config.poolSize, 5);
      expect(config.logLevel, LogLevel.verbose);
      expect(config.precache, false);
      expect(config.precacheWeb, false);
      expect(config.precacheMobile, false);
      expect(config.keepCache, false);
      expect(config.cacheTTL, const Duration(days: 1));
      expect(config.useProxy, true);
      expect(config.useIsolates, false);
      expect(config.maxConcurrentDownloads, 5);
      expect(config.chunkSize, 1 * 1024 * 1024);
    });
  });

  group('LogLevel', () {
    test('has all expected values', () {
      expect(LogLevel.values, contains(LogLevel.none));
      expect(LogLevel.values, contains(LogLevel.error));
      expect(LogLevel.values, contains(LogLevel.info));
      expect(LogLevel.values, contains(LogLevel.verbose));
      expect(LogLevel.values.length, 4);
    });
  });

  group('CacheStatus', () {
    test('has all expected values', () {
      expect(CacheStatus.values, contains(CacheStatus.none));
      expect(CacheStatus.values, contains(CacheStatus.partial));
      expect(CacheStatus.values, contains(CacheStatus.complete));
      expect(CacheStatus.values.length, 3);
    });
  });

  group('LruMemoryCache', () {
    test('stores and retrieves data', () {
      final cache = LruMemoryCache(maxSizeBytes: 1024);
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      cache.put('test-url', data);

      expect(cache.contains('test-url'), true);
      expect(cache.get('test-url'), equals(data));
      expect(cache.currentSize, 5);
      expect(cache.itemCount, 1);
    });

    test('returns null for missing keys', () {
      final cache = LruMemoryCache(maxSizeBytes: 1024);

      expect(cache.get('nonexistent'), isNull);
      expect(cache.contains('nonexistent'), false);
    });

    test('evicts LRU entries when full', () {
      final cache = LruMemoryCache(maxSizeBytes: 10);

      cache.put('url1', Uint8List.fromList([1, 2, 3, 4])); // 4 bytes
      cache.put('url2', Uint8List.fromList([5, 6, 7, 8])); // 4 bytes
      // Cache now has 8 bytes

      // Adding 4 more bytes should evict url1 (LRU)
      cache.put('url3', Uint8List.fromList([9, 10, 11, 12]));

      expect(cache.contains('url1'), false); // Evicted
      expect(cache.contains('url2'), true);
      expect(cache.contains('url3'), true);
    });

    test('accessing entry moves it to end (most recently used)', () {
      // maxSizeBytes: 11 means 4+4+4=12 won't fit, forcing eviction
      final cache = LruMemoryCache(maxSizeBytes: 11);

      cache.put('url1', Uint8List.fromList([1, 2, 3, 4]));
      cache.put('url2', Uint8List.fromList([5, 6, 7, 8]));

      // Access url1, making it most recently used
      cache.get('url1');

      // Adding new entry should evict url2 (now LRU, since url1 was accessed)
      cache.put('url3', Uint8List.fromList([9, 10, 11, 12]));

      expect(cache.contains('url1'), true);
      expect(cache.contains('url2'), false); // Evicted (was LRU after url1 access)
      expect(cache.contains('url3'), true);
    });

    test('does not cache items larger than max size', () {
      final cache = LruMemoryCache(maxSizeBytes: 5);
      final largeData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

      cache.put('large-url', largeData);

      expect(cache.contains('large-url'), false);
      expect(cache.currentSize, 0);
    });

    test('remove deletes specific entry', () {
      final cache = LruMemoryCache(maxSizeBytes: 1024);
      cache.put('url1', Uint8List.fromList([1, 2, 3]));
      cache.put('url2', Uint8List.fromList([4, 5, 6]));

      cache.remove('url1');

      expect(cache.contains('url1'), false);
      expect(cache.contains('url2'), true);
      expect(cache.currentSize, 3);
    });

    test('clear removes all entries', () {
      final cache = LruMemoryCache(maxSizeBytes: 1024);
      cache.put('url1', Uint8List.fromList([1, 2, 3]));
      cache.put('url2', Uint8List.fromList([4, 5, 6]));

      cache.clear();

      expect(cache.itemCount, 0);
      expect(cache.currentSize, 0);
    });

    test('updates existing entry without increasing total size incorrectly',
        () {
      final cache = LruMemoryCache(maxSizeBytes: 1024);
      cache.put('url', Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(cache.currentSize, 5);

      // Update with larger data
      cache.put('url', Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      expect(cache.currentSize, 8);
      expect(cache.itemCount, 1);
    });
  });

  group('HlsParser', () {
    test('parses simple media playlist', () {
      const content = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:9.009,
segment0.ts
#EXTINF:9.009,
segment1.ts
#EXTINF:3.003,
segment2.ts
#EXT-X-ENDLIST''';

      final playlist =
          HlsParser.parse(content, 'https://example.com/playlist.m3u8');

      expect(playlist.isMaster, false);
      expect(playlist, isA<HlsMediaPlaylist>());

      final media = playlist as HlsMediaPlaylist;
      expect(media.segments.length, 3);
      expect(media.targetDuration, 10);
      expect(media.mediaSequence, 0);
      expect(media.isLive, false); // Has #EXT-X-ENDLIST
      expect(media.segments[0].url, 'https://example.com/segment0.ts');
      expect(media.segments[0].duration, 9.009);
    });

    test('parses master playlist with variants', () {
      const content = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=720x480
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1280x720
mid.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=7680000,RESOLUTION=1920x1080
high.m3u8''';

      final playlist =
          HlsParser.parse(content, 'https://example.com/master.m3u8');

      expect(playlist.isMaster, true);
      expect(playlist, isA<HlsMasterPlaylist>());

      final master = playlist as HlsMasterPlaylist;
      expect(master.variants.length, 3);

      // Should be sorted by bandwidth (highest first)
      expect(master.variants[0].bandwidth, 7680000);
      expect(master.variants[0].resolution, '1920x1080');
      expect(master.variants[0].url, 'https://example.com/high.m3u8');

      expect(master.variants[2].bandwidth, 1280000);
      expect(master.variants[2].resolution, '720x480');
    });

    test('resolves relative URLs correctly', () {
      const content = '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
/absolute/path/segment.ts
#EXTINF:10.0,
relative/segment.ts
#EXTINF:10.0,
https://cdn.example.com/full/url/segment.ts
#EXT-X-ENDLIST''';

      final playlist =
          HlsParser.parse(content, 'https://example.com/streams/playlist.m3u8')
              as HlsMediaPlaylist;

      expect(playlist.segments[0].url,
          'https://example.com/absolute/path/segment.ts');
      expect(playlist.segments[1].url,
          'https://example.com/streams/relative/segment.ts');
      expect(playlist.segments[2].url,
          'https://cdn.example.com/full/url/segment.ts');
    });

    test('throws on invalid playlist', () {
      const invalidContent = 'This is not a valid playlist';

      expect(
        () => HlsParser.parse(
            invalidContent, 'https://example.com/playlist.m3u8'),
        throwsFormatException,
      );
    });

    test('detects live playlist (no ENDLIST)', () {
      const content = '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:12345
#EXTINF:10.0,
segment1.ts
#EXTINF:10.0,
segment2.ts''';

      final playlist = HlsParser.parse(content, 'https://example.com/live.m3u8')
          as HlsMediaPlaylist;

      expect(playlist.isLive, true);
      expect(playlist.mediaSequence, 12345);
    });

    test('parses encrypted playlist', () {
      const content = '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="https://example.com/key.bin"
#EXTINF:10.0,
encrypted_segment.ts
#EXT-X-ENDLIST''';

      final playlist =
          HlsParser.parse(content, 'https://example.com/playlist.m3u8')
              as HlsMediaPlaylist;

      expect(playlist.encryption, 'AES-128');
      expect(playlist.encryptionKeyUrl, 'https://example.com/key.bin');
      expect(playlist.segments[0].isEncrypted, true);
    });

    test('HlsMasterPlaylist.bestQuality returns highest bandwidth', () {
      const content = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000000
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000
high.m3u8''';

      final master = HlsParser.parse(content, 'https://example.com/master.m3u8')
          as HlsMasterPlaylist;

      expect(master.bestQuality?.bandwidth, 5000000);
    });

    test('HlsMasterPlaylist.getVariantForBandwidth finds closest match', () {
      const content = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000000
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000
mid.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000
high.m3u8''';

      final master = HlsParser.parse(content, 'https://example.com/master.m3u8')
          as HlsMasterPlaylist;

      expect(master.getVariantForBandwidth(2500000)?.bandwidth, 3000000);
      expect(master.getVariantForBandwidth(800000)?.bandwidth, 1000000);
      expect(master.getVariantForBandwidth(6000000)?.bandwidth, 5000000);
    });

    test('HlsMediaPlaylist.totalDuration sums all segments', () {
      const content = '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
segment1.ts
#EXTINF:10.0,
segment2.ts
#EXTINF:5.5,
segment3.ts
#EXT-X-ENDLIST''';

      final playlist =
          HlsParser.parse(content, 'https://example.com/playlist.m3u8')
              as HlsMediaPlaylist;

      expect(playlist.totalDuration, 25.5);
    });
  });
}
