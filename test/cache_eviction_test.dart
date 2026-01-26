import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/src/cache/download_tracker.dart';
import 'package:flutter_video_stream/src/cache/lru_memory_cache.dart';

void main() {
  group('CacheMetadata', () {
    test('serializes to JSON correctly', () {
      final now = DateTime.now();
      final metadata = CacheMetadata(
        url: 'https://example.com/video.mp4',
        filePath: '/cache/abc123.mp4',
        fileSize: 1024000,
        created: now,
        lastAccessed: now,
        expires: now.add(const Duration(days: 7)),
      );

      final json = metadata.toJson();

      expect(json['url'], 'https://example.com/video.mp4');
      expect(json['filePath'], '/cache/abc123.mp4');
      expect(json['fileSize'], 1024000);
      expect(json['created'], now.toIso8601String());
      expect(json['lastAccessed'], now.toIso8601String());
      expect(json['expires'], now.add(const Duration(days: 7)).toIso8601String());
    });

    test('deserializes from JSON correctly', () {
      final now = DateTime.now();
      final json = {
        'url': 'https://example.com/video.mp4',
        'filePath': '/cache/abc123.mp4',
        'fileSize': 1024000,
        'created': now.toIso8601String(),
        'lastAccessed': now.toIso8601String(),
        'expires': now.add(const Duration(days: 7)).toIso8601String(),
      };

      final metadata = CacheMetadata.fromJson(json);

      expect(metadata.url, 'https://example.com/video.mp4');
      expect(metadata.filePath, '/cache/abc123.mp4');
      expect(metadata.fileSize, 1024000);
    });

    test('handles null expires', () {
      final now = DateTime.now();
      final metadata = CacheMetadata(
        url: 'https://example.com/video.mp4',
        filePath: '/cache/abc123.mp4',
        fileSize: 1024000,
        created: now,
        lastAccessed: now,
        expires: null,
      );

      final json = metadata.toJson();
      expect(json['expires'], isNull);

      final restored = CacheMetadata.fromJson(json);
      expect(restored.expires, isNull);
      expect(restored.isExpired, isFalse);
    });

    test('isExpired returns true for past expiration', () {
      final pastDate = DateTime.now().subtract(const Duration(days: 1));
      final metadata = CacheMetadata(
        url: 'https://example.com/video.mp4',
        filePath: '/cache/abc123.mp4',
        fileSize: 1024000,
        created: pastDate,
        lastAccessed: pastDate,
        expires: pastDate,
      );

      expect(metadata.isExpired, isTrue);
    });

    test('isExpired returns false for future expiration', () {
      final now = DateTime.now();
      final metadata = CacheMetadata(
        url: 'https://example.com/video.mp4',
        filePath: '/cache/abc123.mp4',
        fileSize: 1024000,
        created: now,
        lastAccessed: now,
        expires: now.add(const Duration(days: 7)),
      );

      expect(metadata.isExpired, isFalse);
    });

    test('round-trips through JSON encoding', () {
      final now = DateTime.now();
      final original = CacheMetadata(
        url: 'https://example.com/video.mp4',
        filePath: '/cache/abc123.mp4',
        fileSize: 1024000,
        created: now,
        lastAccessed: now,
        expires: now.add(const Duration(days: 7)),
      );

      final jsonStr = jsonEncode(original.toJson());
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final restored = CacheMetadata.fromJson(decoded);

      expect(restored.url, original.url);
      expect(restored.filePath, original.filePath);
      expect(restored.fileSize, original.fileSize);
    });

    test('copyWith creates new instance with updated fields', () {
      final now = DateTime.now();
      final original = CacheMetadata(
        url: 'https://example.com/video.mp4',
        filePath: '/cache/abc123.mp4',
        fileSize: 1024000,
        created: now,
        lastAccessed: now,
        expires: now.add(const Duration(days: 7)),
      );

      final later = now.add(const Duration(hours: 1));
      final updated = original.copyWith(lastAccessed: later);

      // Original should be unchanged
      expect(original.lastAccessed, now);

      // Updated should have new lastAccessed
      expect(updated.lastAccessed, later);

      // Other fields should remain the same
      expect(updated.url, original.url);
      expect(updated.filePath, original.filePath);
      expect(updated.fileSize, original.fileSize);
      expect(updated.created, original.created);
      expect(updated.expires, original.expires);
    });

    test('fromJson throws FormatException for invalid JSON', () {
      final invalidJson = <String, dynamic>{
        'url': 'https://example.com/video.mp4',
        'filePath': '/cache/abc123.mp4',
        'fileSize': 'not-an-int', // Invalid type
        'created': DateTime.now().toIso8601String(),
        'lastAccessed': DateTime.now().toIso8601String(),
      };

      expect(
        () => CacheMetadata.fromJson(invalidJson),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException for missing required fields', () {
      final incompleteJson = <String, dynamic>{
        'url': 'https://example.com/video.mp4',
        // Missing other required fields
      };

      expect(
        () => CacheMetadata.fromJson(incompleteJson),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('LruMemoryCache eviction methods', () {
    test('evictToPercent reduces cache to target percentage', () {
      final cache = LruMemoryCache(maxSizeBytes: 1000);

      // Fill cache with data
      cache.put('url1', Uint8List(200)); // 200 bytes
      cache.put('url2', Uint8List(300)); // 300 bytes
      cache.put('url3', Uint8List(400)); // 400 bytes
      // Total: 900 bytes

      expect(cache.currentSize, 900);

      // Evict to 50% (500 bytes)
      final freed = cache.evictToPercent(0.5);

      expect(cache.currentSize, lessThanOrEqualTo(500));
      expect(freed, greaterThan(0));
    });

    test('evictToPercent evicts oldest entries first', () {
      final cache = LruMemoryCache(maxSizeBytes: 1000);

      cache.put('url1', Uint8List(300)); // oldest
      cache.put('url2', Uint8List(300));
      cache.put('url3', Uint8List(300)); // newest

      // Evict to 50%
      cache.evictToPercent(0.5);

      // url1 (oldest) should be evicted, url3 (newest) should remain
      expect(cache.contains('url1'), isFalse);
      expect(cache.contains('url3'), isTrue);
    });

    test('evictToPercent handles already under limit', () {
      final cache = LruMemoryCache(maxSizeBytes: 1000);

      cache.put('url1', Uint8List(100));
      expect(cache.currentSize, 100);

      // Already under 50%, should do nothing
      final freed = cache.evictToPercent(0.5);

      expect(freed, 0);
      expect(cache.currentSize, 100);
    });

    test('evictToPercent throws on invalid percentage', () {
      final cache = LruMemoryCache(maxSizeBytes: 1000);

      expect(() => cache.evictToPercent(-0.1), throwsArgumentError);
      expect(() => cache.evictToPercent(1.5), throwsArgumentError);
    });

    test('evictAll clears entire cache', () {
      final cache = LruMemoryCache(maxSizeBytes: 1000);

      cache.put('url1', Uint8List(200));
      cache.put('url2', Uint8List(300));
      cache.put('url3', Uint8List(400));

      expect(cache.currentSize, 900);
      expect(cache.itemCount, 3);

      final freed = cache.evictAll();

      expect(freed, 900);
      expect(cache.currentSize, 0);
      expect(cache.itemCount, 0);
    });

    test('evictAll returns 0 for empty cache', () {
      final cache = LruMemoryCache(maxSizeBytes: 1000);

      final freed = cache.evictAll();

      expect(freed, 0);
    });
  });
}
