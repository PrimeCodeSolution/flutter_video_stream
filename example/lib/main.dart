import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await VideoStream.initialize(
    config: const VideoStreamConfig(
      maxCacheSize: 200 * 1024 * 1024,
      preloadCount: 2,
      preloadBytes: 3 * 1024 * 1024,
      logLevel: LogLevel.verbose,
      precacheWeb: false,
      precacheMobile: true,
      enableMetrics: true,
      keepCache: false,
    ),
  );

  runApp(const VideoStreamDemoApp());
}

class VideoStreamDemoApp extends StatelessWidget {
  const VideoStreamDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AppStateProvider(
      child: MaterialApp(
        title: 'VideoStream Demo',
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.dark(
            primary: Colors.pink,
            secondary: Colors.pinkAccent,
            surface: Colors.grey[900]!,
          ),
          useMaterial3: true,
          cardTheme: CardThemeData(
            color: Colors.grey[850],
            elevation: 2,
          ),
        ),
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

/// Simple state management using InheritedNotifier
class AppState extends ChangeNotifier {
  VideoStreamConfig _config = const VideoStreamConfig(
    maxCacheSize: 200 * 1024 * 1024,
    preloadCount: 2,
    preloadBytes: 3 * 1024 * 1024,
    logLevel: LogLevel.verbose,
    precacheWeb: false,
    precacheMobile: true,
    enableMetrics: true,
  );

  MetricsSnapshot? _metrics;
  Timer? _metricsTimer;
  bool _isApplyingConfig = false;

  VideoStreamConfig get config => _config;
  MetricsSnapshot? get metrics => _metrics;
  bool get isApplyingConfig => _isApplyingConfig;

  void updateConfig(VideoStreamConfig newConfig) {
    _config = newConfig;
    notifyListeners();
  }

  Future<void> applyConfig() async {
    _isApplyingConfig = true;
    notifyListeners();

    try {
      await VideoStream.dispose();
      await VideoStream.initialize(config: _config);
    } finally {
      _isApplyingConfig = false;
      notifyListeners();
    }
  }

  void startMetricsPolling() {
    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _metrics = VideoStream.getMetricsSnapshot();
      notifyListeners();
    });
    // Get initial snapshot
    _metrics = VideoStream.getMetricsSnapshot();
    notifyListeners();
  }

  void stopMetricsPolling() {
    _metricsTimer?.cancel();
    _metricsTimer = null;
  }

  void resetMetrics() {
    VideoStream.resetMetrics();
    _metrics = VideoStream.getMetricsSnapshot();
    notifyListeners();
  }

  @override
  void dispose() {
    _metricsTimer?.cancel();
    super.dispose();
  }
}

class AppStateProvider extends StatefulWidget {
  final Widget child;

  const AppStateProvider({super.key, required this.child});

  @override
  State<AppStateProvider> createState() => _AppStateProviderState();

  static AppState of(BuildContext context) {
    final provider =
        context.dependOnInheritedWidgetOfExactType<_AppStateInherited>();
    return provider!.state;
  }
}

class _AppStateProviderState extends State<AppStateProvider> {
  final AppState _state = AppState();

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AppStateInherited(
      state: _state,
      child: widget.child,
    );
  }
}

class _AppStateInherited extends InheritedNotifier<AppState> {
  final AppState state;

  const _AppStateInherited({
    required this.state,
    required super.child,
  }) : super(notifier: state);
}
