import 'package:flutter/material.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import '../main.dart';
import '../utils/formatters.dart';

class MetricsScreen extends StatefulWidget {
  const MetricsScreen({super.key});

  @override
  State<MetricsScreen> createState() => _MetricsScreenState();
}

class _MetricsScreenState extends State<MetricsScreen> {
  @override
  void initState() {
    super.initState();
    // Start metrics polling when screen is shown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppStateProvider.of(context).startMetricsPolling();
    });
  }

  @override
  void dispose() {
    // Stop polling when screen is disposed
    // Note: In a real app, you might want to keep polling active
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateProvider.of(context);
    final metrics = appState.metrics;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Metrics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => appState.resetMetrics(),
            tooltip: 'Reset Metrics',
          ),
        ],
      ),
      body: metrics == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                appState.resetMetrics();
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildCacheCard(metrics),
                  const SizedBox(height: 16),
                  _buildDownloadsCard(metrics),
                  const SizedBox(height: 16),
                  _buildRetriesCard(metrics),
                  const SizedBox(height: 16),
                  _buildErrorsCard(metrics),
                  const SizedBox(height: 80),
                ],
              ),
            ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required IconData icon,
    required Color iconColor,
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
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: iconColor.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
                const SizedBox(width: 12),
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

  Widget _buildStatRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[400])),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator(String label, double value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(color: Colors.grey[400])),
            Text(
              formatPercent(value),
              style: TextStyle(color: color, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            backgroundColor: Colors.grey[800],
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildCacheCard(MetricsSnapshot metrics) {
    return _buildMetricCard(
      title: 'Cache Performance',
      icon: Icons.storage,
      iconColor: Colors.blue,
      children: [
        _buildProgressIndicator(
          'Overall Hit Rate',
          metrics.overallCacheHitRate,
          _getHitRateColor(metrics.overallCacheHitRate),
        ),
        _buildProgressIndicator(
          'Memory Hit Rate',
          metrics.memoryCacheHitRate,
          _getHitRateColor(metrics.memoryCacheHitRate),
        ),
        _buildProgressIndicator(
          'Disk Hit Rate',
          metrics.diskCacheHitRate,
          _getHitRateColor(metrics.diskCacheHitRate),
        ),
        const Divider(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildStatBox(
                'Memory Hits',
                metrics.memoryCacheHits.toString(),
                Colors.green,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildStatBox(
                'Memory Misses',
                metrics.memoryCacheMisses.toString(),
                Colors.red,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildStatBox(
                'Disk Hits',
                metrics.diskCacheHits.toString(),
                Colors.green,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildStatBox(
                'Disk Misses',
                metrics.diskCacheMisses.toString(),
                Colors.red,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDownloadsCard(MetricsSnapshot metrics) {
    return _buildMetricCard(
      title: 'Downloads',
      icon: Icons.cloud_download,
      iconColor: Colors.green,
      children: [
        _buildProgressIndicator(
          'Success Rate',
          metrics.downloadSuccessRate,
          _getHitRateColor(metrics.downloadSuccessRate),
        ),
        const Divider(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildStatBox(
                'Started',
                metrics.downloadsStarted.toString(),
                Colors.blue,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildStatBox(
                'Completed',
                metrics.downloadsCompleted.toString(),
                Colors.green,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildStatBox(
                'Failed',
                metrics.downloadsFailed.toString(),
                Colors.red,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildStatBox(
                'Cancelled',
                metrics.downloadsCancelled.toString(),
                Colors.orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildStatRow(
          'Total Downloaded',
          formatBytes(metrics.totalBytesDownloaded),
        ),
        _buildStatRow(
          'Average Speed',
          formatSpeed(metrics.averageDownloadSpeed),
        ),
        _buildStatRow(
          'Recent Speed',
          formatSpeed(metrics.recentAverageDownloadSpeed),
          valueColor: Colors.green,
        ),
      ],
    );
  }

  Widget _buildRetriesCard(MetricsSnapshot metrics) {
    return _buildMetricCard(
      title: 'Retries',
      icon: Icons.refresh,
      iconColor: Colors.orange,
      children: [
        _buildProgressIndicator(
          'Retry Success Rate',
          metrics.retrySuccessRate,
          _getHitRateColor(metrics.retrySuccessRate),
        ),
        const Divider(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildStatBox(
                'Total Retries',
                metrics.totalRetries.toString(),
                Colors.blue,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildStatBox(
                'Succeeded',
                metrics.retriesSucceeded.toString(),
                Colors.green,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildStatBox(
                'Failed',
                metrics.retriesFailed.toString(),
                Colors.red,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorsCard(MetricsSnapshot metrics) {
    final errors = metrics.errorCountsByType;

    return _buildMetricCard(
      title: 'Errors',
      icon: Icons.error_outline,
      iconColor: Colors.red,
      children: [
        if (errors.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(Icons.check_circle_outline,
                      color: Colors.green, size: 48),
                  const SizedBox(height: 8),
                  const Text('No errors recorded'),
                ],
              ),
            ),
          )
        else ...[
          for (final entry in errors.entries)
            _buildStatRow(
              entry.key.replaceAll('_', ' ').toUpperCase(),
              entry.value.toString(),
              valueColor: Colors.red,
            ),
        ],
      ],
    );
  }

  Widget _buildStatBox(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(77)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[400],
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Color _getHitRateColor(double rate) {
    if (rate >= 0.8) return Colors.green;
    if (rate >= 0.5) return Colors.orange;
    return Colors.red;
  }
}
