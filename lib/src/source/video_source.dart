import 'dart:typed_data';

import 'package:video_player/video_player.dart' show VideoPlayerOptions;

/// Describes where a video's content comes from.
///
/// [VideoSource] is the identity and content descriptor for everything the
/// package does — caching, controller pooling, deduplication, and preloading
/// are all keyed by [key].
///
/// Three kinds of sources are supported:
///
/// - [VideoSource.url] — the classic flow: the package fetches, caches and
///   streams the video over HTTP. The URL itself is the [key].
/// - [VideoSource.bytes] — caller-supplied plaintext bytes (e.g. an encrypted
///   attachment the app downloaded and decrypted itself). The package writes
///   the bytes into its cache and plays them locally, bypassing the HTTP
///   proxy entirely. The package never fetches a bytes-keyed source over
///   HTTP.
/// - [VideoSource.file] — content that already exists on disk. The file is
///   imported into the cache (keyed by [key]) and played locally.
///
/// ## Example
///
/// ```dart
/// // App downloads + decrypts, then hands us plaintext bytes:
/// final source = VideoSource.bytes(
///   decryptedBytes,
///   key: eventId,           // any stable unique id
///   mimeType: 'video/mp4',
/// );
///
/// VideoStreamPlayer(source: source);
/// ```
sealed class VideoSource {
  const VideoSource();

  /// Stable identity used for caching, pooling, and deduplication.
  ///
  /// Acquiring the same key twice reuses one controller; cache entries are
  /// stored, sized, and evicted under this key — identical semantics to how
  /// a URL keys the pipeline in the URL flow.
  String get key;

  /// Optional [VideoPlayerOptions] applied when this source's controller is
  /// created, taking precedence over `VideoStreamConfig.playerOptions`.
  ///
  /// Note: two sources with the same [key] share one pooled controller, so
  /// the options of whichever source triggers the **first** creation win;
  /// later joins reuse that controller unchanged.
  VideoPlayerOptions? get playerOptions;

  /// A video fetched over HTTP (existing behavior, unchanged).
  ///
  /// [url] doubles as the [key]. Optional [headers] are sent with every
  /// request for this video.
  const factory VideoSource.url(
    String url, {
    Map<String, String>? headers,
    VideoPlayerOptions? playerOptions,
  }) = UrlVideoSource;

  /// Caller-supplied plaintext video bytes.
  ///
  /// [key] must be a stable unique id for this content (for example a
  /// Matrix event ID). [mimeType] and [filename] are optional hints used to
  /// pick a suitable file extension / blob type; when absent, `video/mp4`
  /// is assumed.
  ///
  /// The bytes are written into the same cache the URL flow uses and
  /// participate in the LRU size cap. If the cache entry is evicted while
  /// this source object is still around, the bytes are transparently
  /// re-injected on the next acquire — no error, no network.
  const factory VideoSource.bytes(
    Uint8List bytes, {
    required String key,
    String? mimeType,
    String? filename,
    VideoPlayerOptions? playerOptions,
  }) = BytesVideoSource;

  /// Video content that already exists on disk at [path].
  ///
  /// The file is copied into the cache under [key] on first use. If both the
  /// cache entry and the file at [path] are gone when the source is acquired,
  /// a [VideoSourceNotCachedException] is thrown so the app can re-download
  /// and re-inject. Not supported on web.
  const factory VideoSource.file(
    String path, {
    required String key,
    VideoPlayerOptions? playerOptions,
  }) = FileVideoSource;
}

/// A video fetched over HTTP. See [VideoSource.url].
final class UrlVideoSource extends VideoSource {
  /// The URL of the video (MP4 or HLS).
  final String url;

  /// Optional HTTP headers for the video request.
  final Map<String, String>? headers;

  @override
  final VideoPlayerOptions? playerOptions;

  /// Creates a URL-backed video source.
  const UrlVideoSource(this.url, {this.headers, this.playerOptions});

  @override
  String get key => url;
}

/// Caller-supplied video bytes. See [VideoSource.bytes].
final class BytesVideoSource extends VideoSource {
  /// The full plaintext video content.
  final Uint8List bytes;

  @override
  final String key;

  /// Optional MIME type hint (e.g. `video/mp4`, `video/webm`).
  final String? mimeType;

  /// Optional original filename hint, used to derive a file extension when
  /// [mimeType] is not provided.
  final String? filename;

  @override
  final VideoPlayerOptions? playerOptions;

  /// Creates a bytes-backed video source.
  const BytesVideoSource(
    this.bytes, {
    required this.key,
    this.mimeType,
    this.filename,
    this.playerOptions,
  });
}

/// A video file already on disk. See [VideoSource.file].
final class FileVideoSource extends VideoSource {
  /// Path of the video file on disk.
  final String path;

  @override
  final String key;

  @override
  final VideoPlayerOptions? playerOptions;

  /// Creates a file-backed video source.
  const FileVideoSource(this.path, {required this.key, this.playerOptions});
}

/// Thrown when an injected ([VideoSource.bytes] / [VideoSource.file]) source
/// key cannot be served from the cache and cannot be re-materialized.
///
/// The package never fetches injected keys over HTTP, so when the cached
/// bytes have been evicted and no local copy is reachable, this error is
/// surfaced instead. Catch it (or watch for
/// [VideoStreamErrorType.sourceNotCached] in `VideoStreamPlayer.onError`)
/// to re-download, re-decrypt, and re-inject the content:
///
/// ```dart
/// try {
///   await pool.acquireSource(VideoSource.file(path, key: eventId));
/// } on VideoSourceNotCachedException catch (e) {
///   final bytes = await myApp.downloadAndDecrypt(e.key);
///   await VideoStream.precacheBytes(e.key, bytes);
/// }
/// ```
class VideoSourceNotCachedException implements Exception {
  /// The source key whose content is no longer available.
  final String key;

  /// Human-readable description of the failure.
  final String message;

  /// Creates the exception for [key], optionally overriding [message].
  VideoSourceNotCachedException(this.key, [String? message])
      : message = message ??
            'Content for key "$key" is not in the cache (it may have been '
                'evicted). Re-inject it with VideoStream.precacheBytes() — '
                'injected sources are never fetched over HTTP.';

  @override
  String toString() => 'VideoSourceNotCachedException($key): $message';
}
