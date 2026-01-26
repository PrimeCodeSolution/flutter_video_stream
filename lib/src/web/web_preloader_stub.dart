import 'package:video_player/video_player.dart';

/// Stub for non-web platforms - does nothing
WebPreloader getWebPreloader() => WebPreloader._();

class WebPreloader {
  WebPreloader._();

  /// No-op on mobile
  void warmUp(String url, {Map<String, String>? headers}) {}

  /// No-op on mobile
  void notifyActive(int index, Map<String, int> registeredUrls) {}

  /// No-op on mobile
  VideoPlayerController? getWarmedController(String url) => null;

  /// No-op on mobile
  void dispose() {}
}
