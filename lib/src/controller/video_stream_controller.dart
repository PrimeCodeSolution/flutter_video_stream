import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

/// Singleton controller for the currently active video.
/// Abstracts away video_player internals from consuming apps.
class VideoStreamController extends ChangeNotifier {
  VideoStreamController._();
  static final VideoStreamController instance = VideoStreamController._();

  VideoPlayerController? _activeController;
  String? _activeUrl;

  // State
  bool _isPaused = false;
  bool _isMuted = false;

  /// Whether user has interacted with video on web (enables autoplay).
  /// Browser autoplay policy requires one user interaction per page load.
  bool _webUserHasInteracted = false;

  // Getters
  bool get isPaused => _isPaused;
  bool get isMuted => _isMuted;

  /// Whether the user has interacted with video on web.
  /// After first interaction, autoplay is allowed for subsequent videos.
  bool get webUserHasInteracted => _webUserHasInteracted;

  /// Mark that user has interacted with video on web.
  /// Called when user taps play button on first video.
  void markWebUserInteracted() {
    _webUserHasInteracted = true;
    notifyListeners();
  }

  bool get hasActiveVideo => _activeController != null;
  String? get activeUrl => _activeUrl;

  /// Called internally by VideoStreamPlayer when it becomes active.
  /// This is package-private - not intended for external use.
  void setActiveController(VideoPlayerController? controller, String? url) {
    _activeController = controller;
    _activeUrl = url;

    // Apply current state to new controller
    if (controller != null) {
      controller.setVolume(_isMuted ? 0.0 : 1.0);
      if (_isPaused) {
        controller.pause();
      }
    }

    // Defer notification to avoid calling during build phase
    SchedulerBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });
  }

  /// Pause the currently active video.
  void pause() {
    _isPaused = true;
    _activeController?.pause();
    notifyListeners();
  }

  /// Resume playback of the currently active video.
  void play() {
    _isPaused = false;
    _activeController?.play();
    notifyListeners();
  }

  /// Toggle between play and pause.
  void togglePlayPause() {
    if (_isPaused) {
      play();
    } else {
      pause();
    }
  }

  /// Mute the currently active video.
  void mute() {
    _isMuted = true;
    _activeController?.setVolume(0.0);
    notifyListeners();
  }

  /// Unmute the currently active video.
  void unmute() {
    _isMuted = false;
    _activeController?.setVolume(1.0);
    notifyListeners();
  }

  /// Toggle between muted and unmuted.
  void toggleMute() {
    if (_isMuted) {
      unmute();
    } else {
      mute();
    }
  }

  /// Reset state (e.g., when disposing).
  void reset() {
    _activeController = null;
    _activeUrl = null;
    _isPaused = false;
    _isMuted = false;
    // Note: _webUserHasInteracted is NOT reset here - it persists for the session
    // Only a page reload resets it (new singleton instance)
    notifyListeners();
  }
}
