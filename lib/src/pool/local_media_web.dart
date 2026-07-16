import 'dart:typed_data';

import 'package:video_player/video_player.dart';

VideoPlayerController createLocalController(String pathOrUrl,
        {VideoPlayerOptions? options}) =>
    VideoPlayerController.networkUrl(Uri.parse(pathOrUrl),
        videoPlayerOptions: options);

// No file system on web: VideoSource.file cannot be imported.
Future<Uint8List?> readSourceFile(String path) async => null;
