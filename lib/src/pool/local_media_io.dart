import 'dart:io';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';

VideoPlayerController createLocalController(String pathOrUrl) =>
    VideoPlayerController.file(File(pathOrUrl));

Future<Uint8List?> readSourceFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  try {
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}
