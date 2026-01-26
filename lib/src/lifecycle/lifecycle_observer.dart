import 'package:flutter/widgets.dart';

/// Severity level of memory pressure from the system.
enum MemoryPressureLevel {
  /// Minor pressure - reduce cache by ~25%
  low,

  /// Moderate pressure - reduce cache by ~50%
  medium,

  /// High pressure - reduce cache by ~75%
  high,

  /// Critical pressure - clear all caches immediately
  critical,
}

/// Callback type for memory pressure events.
typedef MemoryPressureCallback = void Function(MemoryPressureLevel level);

/// Mixin for components that need lifecycle awareness.
///
/// Implement this mixin to receive notifications when the app
/// goes to background (paused) or returns to foreground (resumed).
mixin LifecycleAware {
  /// Called when the app moves to the background.
  void onPaused();

  /// Called when the app returns to the foreground.
  void onResumed();
}

/// Singleton observer that monitors app lifecycle and memory pressure.
///
/// This observer implements [WidgetsBindingObserver] to receive system
/// notifications about app state changes and memory warnings.
///
/// ## Usage
///
/// ```dart
/// // Register a listener
/// VideoStreamLifecycleObserver.instance.addListener(myComponent);
///
/// // Handle memory pressure
/// VideoStreamLifecycleObserver.instance.onMemoryPressure = (level) {
///   // Reduce cache based on severity
/// };
/// ```
class VideoStreamLifecycleObserver with WidgetsBindingObserver {
  static VideoStreamLifecycleObserver? _instance;

  /// Get the singleton instance. Creates it if needed.
  static VideoStreamLifecycleObserver get instance {
    _instance ??= VideoStreamLifecycleObserver._();
    return _instance!;
  }

  VideoStreamLifecycleObserver._();

  final Set<LifecycleAware> _listeners = {};
  final List<MemoryPressureCallback> _memoryPressureCallbacks = [];
  bool _isRegistered = false;
  bool _isPaused = false;

  /// Whether the app is currently paused (in background).
  bool get isPaused => _isPaused;

  /// Start observing lifecycle events.
  ///
  /// Call this during app initialization (mobile only).
  void start() {
    if (_isRegistered) return;

    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _isRegistered = true;
  }

  /// Stop observing lifecycle events.
  ///
  /// Call this during app disposal.
  void stop() {
    if (!_isRegistered) return;

    final binding = WidgetsBinding.instance;
    binding.removeObserver(this);
    _isRegistered = false;
    _listeners.clear();
    _memoryPressureCallbacks.clear();
  }

  /// Add a lifecycle-aware component as a listener.
  void addListener(LifecycleAware listener) {
    _listeners.add(listener);
  }

  /// Remove a lifecycle-aware component.
  void removeListener(LifecycleAware listener) {
    _listeners.remove(listener);
  }

  /// Add a memory pressure callback.
  void addMemoryPressureCallback(MemoryPressureCallback callback) {
    _memoryPressureCallbacks.add(callback);
  }

  /// Remove a memory pressure callback.
  void removeMemoryPressureCallback(MemoryPressureCallback callback) {
    _memoryPressureCallbacks.remove(callback);
  }

  /// Legacy setter for backward compatibility.
  @Deprecated('Use addMemoryPressureCallback/removeMemoryPressureCallback instead')
  set onMemoryPressure(MemoryPressureCallback? callback) {
    // For backward compatibility, treat this as adding/clearing the first callback
    _memoryPressureCallbacks.clear();
    if (callback != null) {
      _memoryPressureCallbacks.add(callback);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        if (!_isPaused) {
          _isPaused = true;
          _notifyPaused();
        }
        break;
      case AppLifecycleState.resumed:
        if (_isPaused) {
          _isPaused = false;
          _notifyResumed();
        }
        break;
      case AppLifecycleState.detached:
        // App is about to be terminated - no action needed
        break;
    }
  }

  @override
  void didHaveMemoryPressure() {
    // System is low on memory - notify all callbacks
    // We treat this as high pressure since Flutter only gets
    // one generic notification (no severity levels)
    _notifyMemoryPressure(MemoryPressureLevel.high);
  }

  void _notifyMemoryPressure(MemoryPressureLevel level) {
    for (final callback in _memoryPressureCallbacks.toList()) {
      try {
        callback(level);
      } catch (e) {
        // Don't let one callback crash others
      }
    }
  }

  void _notifyPaused() {
    for (final listener in _listeners.toList()) {
      try {
        listener.onPaused();
      } catch (e) {
        // Don't let one listener crash others
      }
    }
  }

  void _notifyResumed() {
    for (final listener in _listeners.toList()) {
      try {
        listener.onResumed();
      } catch (e) {
        // Don't let one listener crash others
      }
    }
  }

  /// Manually trigger memory pressure handling.
  ///
  /// Useful for testing or when implementing custom memory monitoring.
  void triggerMemoryPressure(MemoryPressureLevel level) {
    _notifyMemoryPressure(level);
  }
}
