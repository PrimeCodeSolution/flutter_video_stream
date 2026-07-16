import 'dart:typed_data';

import 'package:video_player/video_player.dart';

import 'local_media_io.dart'
    if (dart.library.js_interop) 'local_media_web.dart' as platform;

/// Creates a controller that plays already-local content.
///
/// [pathOrUrl] is a cache file path on mobile, or a `blob:` / `data:` URL on
/// web. Injected sources always go through here — never through the HTTP
/// proxy. [options] are passed through to the controller constructor.
VideoPlayerController createLocalController(String pathOrUrl,
        {VideoPlayerOptions? options}) =>
    platform.createLocalController(pathOrUrl, options: options);

/// Reads the file at [path] for importing a [VideoSource.file] into the
/// cache. Returns null when the file is missing or the platform has no file
/// system access (web).
Future<Uint8List?> readSourceFile(String path) => platform.readSourceFile(path);
