// Tests for the VideoSource sealed hierarchy and
// VideoSourceNotCachedException, written against the 0.2.0 design spec.
//
// CONTRACT: VideoSource (url/bytes/file) and VideoSourceNotCachedException
// are exported from package:flutter_video_stream/flutter_video_stream.dart,
// so this file deliberately imports only the public library — it doubles as
// a test of the export surface.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';

void main() {
  group('VideoSource.url', () {
    test('key is the url itself', () {
      const source = VideoSource.url('https://example.com/video.mp4');

      expect(source, isA<UrlVideoSource>());
      expect(source.key, 'https://example.com/video.mp4');
      expect((source as UrlVideoSource).url, 'https://example.com/video.mp4');
      expect(source.headers, isNull);
    });

    test('carries optional headers', () {
      const source = VideoSource.url(
        'https://example.com/video.mp4',
        headers: {'Authorization': 'Bearer token'},
      );

      expect(
        (source as UrlVideoSource).headers,
        {'Authorization': 'Bearer token'},
      );
      // Headers must not leak into identity.
      expect(source.key, 'https://example.com/video.mp4');
    });
  });

  group('VideoSource.bytes', () {
    test('uses the provided key, not content, as identity', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final source = VideoSource.bytes(bytes, key: 'mx-event-1');

      expect(source, isA<BytesVideoSource>());
      expect(source.key, 'mx-event-1');

      final typed = source as BytesVideoSource;
      expect(typed.bytes, same(bytes));
      expect(typed.mimeType, isNull);
      expect(typed.filename, isNull);
    });

    test('carries optional mimeType and filename hints', () {
      final source = VideoSource.bytes(
        Uint8List.fromList([9, 9, 9]),
        key: 'mx-event-2',
        mimeType: 'video/webm',
        filename: 'clip.webm',
      );

      final typed = source as BytesVideoSource;
      expect(typed.mimeType, 'video/webm');
      expect(typed.filename, 'clip.webm');
      expect(typed.key, 'mx-event-2');
    });
  });

  group('VideoSource.file', () {
    test('uses the provided key, not the path, as identity', () {
      const source = VideoSource.file('/tmp/somewhere/clip.mp4', key: 'mx-3');

      expect(source, isA<FileVideoSource>());
      expect(source.key, 'mx-3');
      expect((source as FileVideoSource).path, '/tmp/somewhere/clip.mp4');
    });
  });

  group('VideoSource sealed-type pattern matching', () {
    // Being sealed means a switch with no default must be exhaustive over
    // the three variants — this test fails to COMPILE if a variant is
    // missing or the class stops being sealed.
    String describe(VideoSource source) => switch (source) {
          UrlVideoSource(:final url) => 'url:$url',
          BytesVideoSource(:final bytes) => 'bytes:${bytes.length}',
          FileVideoSource(:final path) => 'file:$path',
        };

    test('switch matches each variant', () {
      expect(
        describe(const VideoSource.url('https://example.com/a.mp4')),
        'url:https://example.com/a.mp4',
      );
      expect(
        describe(VideoSource.bytes(Uint8List(5), key: 'k')),
        'bytes:5',
      );
      expect(
        describe(const VideoSource.file('/data/clip.mov', key: 'k2')),
        'file:/data/clip.mov',
      );
    });

    test('variants are mutually exclusive under is-checks', () {
      final bytes = VideoSource.bytes(Uint8List(1), key: 'k');
      expect(bytes is UrlVideoSource, isFalse);
      expect(bytes is FileVideoSource, isFalse);
      expect(bytes is BytesVideoSource, isTrue);
    });
  });

  group('VideoSourceNotCachedException', () {
    // CONTRACT ASSUMPTION: the spec declares `final String key` and
    // `final String message` but leaves the constructor shape open. We
    // assume a positional key with a default message — the minimal surface
    // implied by "carries key and has a useful toString".
    test('carries the key and a non-empty message', () {
      final e = VideoSourceNotCachedException('mx-evicted-key');

      expect(e, isA<Exception>());
      expect(e.key, 'mx-evicted-key');
      expect(e.message, isNotEmpty);
    });

    test('toString names the type and includes the key', () {
      final e = VideoSourceNotCachedException('mx-evicted-key');
      final s = e.toString();

      expect(s, contains('VideoSourceNotCachedException'));
      expect(s, contains('mx-evicted-key'));
      // Must be more useful than the default "Instance of ..." string.
      expect(s, isNot(contains('Instance of')));
    });
  });
}
