import 'package:flutter/material.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import '../main.dart';
import '../utils/formatters.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late VideoStreamConfig _config;
  bool _hasChanges = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _config = AppStateProvider.of(context).config;
  }

  void _updateConfig(VideoStreamConfig newConfig) {
    setState(() {
      _config = newConfig;
      _hasChanges = true;
    });
    AppStateProvider.of(context).updateConfig(newConfig);
  }

  Future<void> _applyChanges() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply Configuration'),
        content: const Text(
          'This will reinitialize VideoStream and stop all current playback. '
          'The cache will be preserved.\n\nContinue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await AppStateProvider.of(context).applyConfig();
      setState(() => _hasChanges = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuration applied')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateProvider.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          if (_hasChanges)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: appState.isApplyingConfig ? null : _applyChanges,
                icon: appState.isApplyingConfig
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: const Text('Apply'),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCacheSection(),
          const SizedBox(height: 16),
          _buildPreloadSection(),
          const SizedBox(height: 16),
          _buildDownloadSection(),
          const SizedBox(height: 16),
          _buildBehaviorSection(),
          const SizedBox(height: 16),
          _buildRetrySection(),
          const SizedBox(height: 16),
          _buildDebugSection(),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const Divider(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildCacheSection() {
    return _buildSectionCard(
      title: 'Cache',
      icon: Icons.storage,
      children: [
        _buildSliderSetting(
          label: 'Max Cache Size',
          value: _config.maxCacheSize.toDouble(),
          min: 50 * 1024 * 1024,
          max: 1024 * 1024 * 1024,
          divisions: 19,
          formatValue: (v) => formatBytes(v.toInt()),
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: v.toInt(),
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSliderSetting(
          label: 'Max Memory Cache Size',
          value: _config.maxMemoryCacheSize.toDouble(),
          min: 10 * 1024 * 1024,
          max: 500 * 1024 * 1024,
          divisions: 49,
          formatValue: (v) => formatBytes(v.toInt()),
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: v.toInt(),
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSwitchSetting(
          label: 'Keep Cache',
          subtitle: 'Persist cache across sessions',
          value: _config.keepCache,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: v,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        _buildSliderSetting(
          label: 'Cache TTL',
          value: _config.cacheTTL.inDays.toDouble(),
          min: 1,
          max: 30,
          divisions: 29,
          formatValue: (v) => '${v.toInt()} days',
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: Duration(days: v.toInt()),
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSwitchSetting(
          label: 'Evict on Startup',
          subtitle: 'Clean expired cache on app start',
          value: _config.evictOnStartup,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: v,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
      ],
    );
  }

  Widget _buildPreloadSection() {
    return _buildSectionCard(
      title: 'Preload',
      icon: Icons.download_for_offline,
      children: [
        _buildSliderSetting(
          label: 'Preload Count',
          value: _config.preloadCount.toDouble(),
          min: 0,
          max: 5,
          divisions: 5,
          formatValue: (v) => '${v.toInt()} videos',
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: v.toInt(),
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSliderSetting(
          label: 'Preload Bytes',
          value: _config.preloadBytes.toDouble(),
          min: 512 * 1024,
          max: 10 * 1024 * 1024,
          divisions: 19,
          formatValue: (v) => formatBytes(v.toInt()),
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: v.toInt(),
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSliderSetting(
          label: 'Pool Size',
          value: _config.poolSize.toDouble(),
          min: 1,
          max: 5,
          divisions: 4,
          formatValue: (v) => '${v.toInt()} controllers',
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: v.toInt(),
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSwitchSetting(
          label: 'Precache Web',
          subtitle: 'Enable preloading on web platform',
          value: _config.precacheWeb,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: v,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        _buildSwitchSetting(
          label: 'Precache Mobile',
          subtitle: 'Enable preloading on mobile platforms',
          value: _config.precacheMobile,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: v,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
      ],
    );
  }

  Widget _buildDownloadSection() {
    return _buildSectionCard(
      title: 'Download',
      icon: Icons.cloud_download,
      children: [
        _buildSliderSetting(
          label: 'Max Concurrent Downloads',
          value: _config.maxConcurrentDownloads.toDouble(),
          min: 1,
          max: 6,
          divisions: 5,
          formatValue: (v) => '${v.toInt()}',
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: v.toInt(),
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSwitchSetting(
          label: 'Use Isolates',
          subtitle: 'Run downloads in background threads',
          value: _config.useIsolates,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: v,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        _buildSliderSetting(
          label: 'Chunk Size',
          value: _config.chunkSize.toDouble(),
          min: 512 * 1024,
          max: 8 * 1024 * 1024,
          divisions: 15,
          formatValue: (v) => formatBytes(v.toInt()),
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: v.toInt(),
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSliderSetting(
          label: 'Max Bandwidth',
          value: _config.maxBandwidthBytesPerSecond == 0
              ? 0
              : _config.maxBandwidthBytesPerSecond.toDouble(),
          min: 0,
          max: 10 * 1024 * 1024,
          divisions: 20,
          formatValue: (v) => v == 0 ? 'Unlimited' : formatSpeed(v.toInt()),
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: v.toInt(),
          )),
        ),
      ],
    );
  }

  Widget _buildBehaviorSection() {
    return _buildSectionCard(
      title: 'Behavior',
      icon: Icons.tune,
      children: [
        _buildSwitchSetting(
          label: 'Use Proxy',
          subtitle: 'Enable localhost proxy for better caching (mobile)',
          value: _config.useProxy,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: v,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        _buildSwitchSetting(
          label: 'Pause on Background',
          subtitle: 'Pause downloads when app is backgrounded',
          value: _config.pauseOnBackground,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: v,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        _buildSwitchSetting(
          label: 'Respond to Memory Pressure',
          subtitle: 'Reduce cache when system is low on memory',
          value: _config.respondToMemoryPressure,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: v,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        _buildSliderSetting(
          label: 'Memory Pressure Retain',
          value: _config.memoryPressureRetainPercent,
          min: 0.1,
          max: 0.9,
          divisions: 8,
          formatValue: (v) => formatPercent(v),
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: v,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
      ],
    );
  }

  Widget _buildRetrySection() {
    return _buildSectionCard(
      title: 'Retry',
      icon: Icons.refresh,
      children: [
        _buildSwitchSetting(
          label: 'Enable Retry',
          subtitle: 'Automatically retry failed requests',
          value: _config.enableRetry,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: v,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        _buildSliderSetting(
          label: 'Max Retries',
          value: _config.maxRetries.toDouble(),
          min: 0,
          max: 10,
          divisions: 10,
          formatValue: (v) => '${v.toInt()}',
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: v.toInt(),
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
      ],
    );
  }

  Widget _buildDebugSection() {
    return _buildSectionCard(
      title: 'Debug',
      icon: Icons.bug_report,
      children: [
        _buildDropdownSetting<LogLevel>(
          label: 'Log Level',
          value: _config.logLevel,
          items: LogLevel.values,
          formatValue: (v) => v.name,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: v ?? _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: _config.enableMetrics,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
        const SizedBox(height: 12),
        _buildSwitchSetting(
          label: 'Enable Metrics',
          subtitle: 'Track cache hits, downloads, errors',
          value: _config.enableMetrics,
          onChanged: (v) => _updateConfig(VideoStreamConfig(
            maxCacheSize: _config.maxCacheSize,
            maxMemoryCacheSize: _config.maxMemoryCacheSize,
            preloadCount: _config.preloadCount,
            preloadBytes: _config.preloadBytes,
            poolSize: _config.poolSize,
            logLevel: _config.logLevel,
            precacheWeb: _config.precacheWeb,
            precacheMobile: _config.precacheMobile,
            keepCache: _config.keepCache,
            cacheTTL: _config.cacheTTL,
            useProxy: _config.useProxy,
            useIsolates: _config.useIsolates,
            maxConcurrentDownloads: _config.maxConcurrentDownloads,
            chunkSize: _config.chunkSize,
            pauseOnBackground: _config.pauseOnBackground,
            respondToMemoryPressure: _config.respondToMemoryPressure,
            memoryPressureRetainPercent: _config.memoryPressureRetainPercent,
            evictOnStartup: _config.evictOnStartup,
            enableRetry: _config.enableRetry,
            maxRetries: _config.maxRetries,
            enableMetrics: v,
            maxBandwidthBytesPerSecond: _config.maxBandwidthBytesPerSecond,
          )),
        ),
      ],
    );
  }

  Widget _buildSliderSetting({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) formatValue,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(
              formatValue(value),
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildSwitchSetting({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      title: Text(label),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildDropdownSetting<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) formatValue,
    required ValueChanged<T?> onChanged,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        DropdownButton<T>(
          value: value,
          items: items.map((item) {
            return DropdownMenuItem<T>(
              value: item,
              child: Text(formatValue(item)),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
