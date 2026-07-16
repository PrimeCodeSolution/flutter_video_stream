import 'package:flutter/foundation.dart';

/// A tiny arbiter answering "which surface currently renders the texture?"
/// when several widgets share one pooled controller (e.g. an inline tile
/// and a fullscreen page during a handoff).
///
/// This is pure state plus [ChangeNotifier] notifications — the package
/// does not enforce anything with it. It exists so apps doing
/// inline↔fullscreen handoff have a canonical owner answer instead of each
/// inventing one. Access the shared instance via `VideoStream.surfaceArbiter`.
///
/// ```dart
/// // Fullscreen page takes over rendering:
/// VideoStream.surfaceArbiter.claim('fullscreen:$key');
///
/// // Inline tile only renders while it owns the surface:
/// final owns = VideoStream.surfaceArbiter.owner == 'inline:$key';
///
/// // Fullscreen page pops:
/// VideoStream.surfaceArbiter.release('fullscreen:$key');
/// ```
class VideoSurfaceArbiter extends ChangeNotifier {
  String? _owner;

  /// Identifier of the current surface owner, or null when unclaimed.
  ///
  /// The id is app-defined — typically the source key, optionally prefixed
  /// by the widget location as in the example above.
  String? get owner => _owner;

  /// Makes [surfaceId] the current owner and notifies listeners.
  /// No-op (no notification) if it already owns the surface.
  void claim(String surfaceId) {
    if (_owner == surfaceId) return;
    _owner = surfaceId;
    notifyListeners();
  }

  /// Clears ownership and notifies listeners — but only if [surfaceId] is
  /// the current owner. A release by anyone else is a no-op, so a stale
  /// surface tearing down late cannot steal the surface from its successor.
  void release(String surfaceId) {
    if (_owner != surfaceId) return;
    _owner = null;
    notifyListeners();
  }
}
