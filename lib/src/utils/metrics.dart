import 'dart:collection';

/// Metrics tracking for video streaming operations
class VideoStreamMetrics {
  static final VideoStreamMetrics _instance = VideoStreamMetrics._();
  static VideoStreamMetrics get instance => _instance;

  VideoStreamMetrics._();

  // Cache metrics
  int _memoryCacheHits = 0;
  int _memoryCacheMisses = 0;
  int _diskCacheHits = 0;
  int _diskCacheMisses = 0;

  // Download metrics
  int _downloadsStarted = 0;
  int _downloadsCompleted = 0;
  int _downloadsFailed = 0;
  int _downloadsCancelled = 0;
  int _totalBytesDownloaded = 0;
  int _totalDownloadTimeMs = 0;

  // Retry metrics
  int _totalRetries = 0;
  int _retriesSucceeded = 0;
  int _retriesFailed = 0;

  // Error tracking (last N errors)
  static const int _maxErrorHistory = 50;
  final Queue<ErrorRecord> _errorHistory = Queue();

  // Bandwidth metrics (rolling window)
  final List<_BandwidthSample> _bandwidthSamples = [];
  static const int _maxBandwidthSamples = 100;

  // ============ Cache Metrics ============

  void recordMemoryCacheHit() => _memoryCacheHits++;
  void recordMemoryCacheMiss() => _memoryCacheMisses++;
  void recordDiskCacheHit() => _diskCacheHits++;
  void recordDiskCacheMiss() => _diskCacheMisses++;

  int get memoryCacheHits => _memoryCacheHits;
  int get memoryCacheMisses => _memoryCacheMisses;
  int get diskCacheHits => _diskCacheHits;
  int get diskCacheMisses => _diskCacheMisses;

  double get memoryCacheHitRate {
    final total = _memoryCacheHits + _memoryCacheMisses;
    return total > 0 ? _memoryCacheHits / total : 0.0;
  }

  double get diskCacheHitRate {
    final total = _diskCacheHits + _diskCacheMisses;
    return total > 0 ? _diskCacheHits / total : 0.0;
  }

  double get overallCacheHitRate {
    final hits = _memoryCacheHits + _diskCacheHits;
    final total = hits + _diskCacheMisses; // Disk miss = true miss
    return total > 0 ? hits / total : 0.0;
  }

  // ============ Download Metrics ============

  void recordDownloadStarted() => _downloadsStarted++;

  void recordDownloadCompleted(int bytes, int durationMs) {
    _downloadsCompleted++;
    _totalBytesDownloaded += bytes;
    _totalDownloadTimeMs += durationMs;

    // Record bandwidth sample
    if (durationMs > 0) {
      final bytesPerSecond = (bytes * 1000) ~/ durationMs;
      _bandwidthSamples.add(_BandwidthSample(
        timestamp: DateTime.now(),
        bytesPerSecond: bytesPerSecond,
      ));
      if (_bandwidthSamples.length > _maxBandwidthSamples) {
        _bandwidthSamples.removeAt(0);
      }
    }
  }

  void recordDownloadFailed(String url, Object error) {
    _downloadsFailed++;
    _recordError('download_failed', url, error);
  }

  void recordDownloadCancelled() => _downloadsCancelled++;

  int get downloadsStarted => _downloadsStarted;
  int get downloadsCompleted => _downloadsCompleted;
  int get downloadsFailed => _downloadsFailed;
  int get downloadsCancelled => _downloadsCancelled;
  int get totalBytesDownloaded => _totalBytesDownloaded;

  double get downloadSuccessRate {
    final total = _downloadsCompleted + _downloadsFailed;
    return total > 0 ? _downloadsCompleted / total : 0.0;
  }

  /// Average download speed in bytes per second
  int get averageDownloadSpeed {
    if (_totalDownloadTimeMs == 0) return 0;
    return (_totalBytesDownloaded * 1000) ~/ _totalDownloadTimeMs;
  }

  /// Recent average download speed (last N samples)
  int get recentAverageDownloadSpeed {
    if (_bandwidthSamples.isEmpty) return 0;
    final recentSamples = _bandwidthSamples.length > 10
        ? _bandwidthSamples.sublist(_bandwidthSamples.length - 10)
        : _bandwidthSamples;
    final total = recentSamples.fold<int>(0, (sum, s) => sum + s.bytesPerSecond);
    return total ~/ recentSamples.length;
  }

  // ============ Retry Metrics ============

  void recordRetryAttempt() => _totalRetries++;
  void recordRetrySuccess() => _retriesSucceeded++;
  void recordRetryFailure() => _retriesFailed++;

  int get totalRetries => _totalRetries;
  int get retriesSucceeded => _retriesSucceeded;
  int get retriesFailed => _retriesFailed;

  double get retrySuccessRate {
    final total = _retriesSucceeded + _retriesFailed;
    return total > 0 ? _retriesSucceeded / total : 0.0;
  }

  // ============ Error Tracking ============

  void _recordError(String type, String context, Object error) {
    _errorHistory.addLast(ErrorRecord(
      timestamp: DateTime.now(),
      type: type,
      context: context,
      error: error.toString(),
    ));
    if (_errorHistory.length > _maxErrorHistory) {
      _errorHistory.removeFirst();
    }
  }

  void recordError(String type, String context, Object error) {
    _recordError(type, context, error);
  }

  List<ErrorRecord> get recentErrors => _errorHistory.toList();

  Map<String, int> get errorCountsByType {
    final counts = <String, int>{};
    for (final error in _errorHistory) {
      counts[error.type] = (counts[error.type] ?? 0) + 1;
    }
    return counts;
  }

  // ============ Summary ============

  /// Get a snapshot of all metrics
  MetricsSnapshot getSnapshot() {
    return MetricsSnapshot(
      memoryCacheHits: _memoryCacheHits,
      memoryCacheMisses: _memoryCacheMisses,
      diskCacheHits: _diskCacheHits,
      diskCacheMisses: _diskCacheMisses,
      memoryCacheHitRate: memoryCacheHitRate,
      diskCacheHitRate: diskCacheHitRate,
      overallCacheHitRate: overallCacheHitRate,
      downloadsStarted: _downloadsStarted,
      downloadsCompleted: _downloadsCompleted,
      downloadsFailed: _downloadsFailed,
      downloadsCancelled: _downloadsCancelled,
      downloadSuccessRate: downloadSuccessRate,
      totalBytesDownloaded: _totalBytesDownloaded,
      averageDownloadSpeed: averageDownloadSpeed,
      recentAverageDownloadSpeed: recentAverageDownloadSpeed,
      totalRetries: _totalRetries,
      retriesSucceeded: _retriesSucceeded,
      retriesFailed: _retriesFailed,
      retrySuccessRate: retrySuccessRate,
      errorCountsByType: errorCountsByType,
    );
  }

  /// Reset all metrics
  void reset() {
    _memoryCacheHits = 0;
    _memoryCacheMisses = 0;
    _diskCacheHits = 0;
    _diskCacheMisses = 0;
    _downloadsStarted = 0;
    _downloadsCompleted = 0;
    _downloadsFailed = 0;
    _downloadsCancelled = 0;
    _totalBytesDownloaded = 0;
    _totalDownloadTimeMs = 0;
    _totalRetries = 0;
    _retriesSucceeded = 0;
    _retriesFailed = 0;
    _errorHistory.clear();
    _bandwidthSamples.clear();
  }

  @override
  String toString() => getSnapshot().toString();
}

/// A single error record
class ErrorRecord {
  final DateTime timestamp;
  final String type;
  final String context;
  final String error;

  ErrorRecord({
    required this.timestamp,
    required this.type,
    required this.context,
    required this.error,
  });

  @override
  String toString() => '[$timestamp] $type: $error (context: $context)';
}

/// Bandwidth sample for rolling average calculation
class _BandwidthSample {
  final DateTime timestamp;
  final int bytesPerSecond;

  _BandwidthSample({required this.timestamp, required this.bytesPerSecond});
}

/// Immutable snapshot of metrics at a point in time
class MetricsSnapshot {
  final int memoryCacheHits;
  final int memoryCacheMisses;
  final int diskCacheHits;
  final int diskCacheMisses;
  final double memoryCacheHitRate;
  final double diskCacheHitRate;
  final double overallCacheHitRate;
  final int downloadsStarted;
  final int downloadsCompleted;
  final int downloadsFailed;
  final int downloadsCancelled;
  final double downloadSuccessRate;
  final int totalBytesDownloaded;
  final int averageDownloadSpeed;
  final int recentAverageDownloadSpeed;
  final int totalRetries;
  final int retriesSucceeded;
  final int retriesFailed;
  final double retrySuccessRate;
  final Map<String, int> errorCountsByType;

  MetricsSnapshot({
    required this.memoryCacheHits,
    required this.memoryCacheMisses,
    required this.diskCacheHits,
    required this.diskCacheMisses,
    required this.memoryCacheHitRate,
    required this.diskCacheHitRate,
    required this.overallCacheHitRate,
    required this.downloadsStarted,
    required this.downloadsCompleted,
    required this.downloadsFailed,
    required this.downloadsCancelled,
    required this.downloadSuccessRate,
    required this.totalBytesDownloaded,
    required this.averageDownloadSpeed,
    required this.recentAverageDownloadSpeed,
    required this.totalRetries,
    required this.retriesSucceeded,
    required this.retriesFailed,
    required this.retrySuccessRate,
    required this.errorCountsByType,
  });

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(int bytesPerSecond) {
    return '${_formatBytes(bytesPerSecond)}/s';
  }

  @override
  String toString() {
    return '''
VideoStream Metrics:
  Cache:
    Memory: $memoryCacheHits hits / $memoryCacheMisses misses (${(memoryCacheHitRate * 100).toStringAsFixed(1)}% hit rate)
    Disk: $diskCacheHits hits / $diskCacheMisses misses (${(diskCacheHitRate * 100).toStringAsFixed(1)}% hit rate)
    Overall: ${(overallCacheHitRate * 100).toStringAsFixed(1)}% hit rate
  Downloads:
    Started: $downloadsStarted, Completed: $downloadsCompleted, Failed: $downloadsFailed, Cancelled: $downloadsCancelled
    Success rate: ${(downloadSuccessRate * 100).toStringAsFixed(1)}%
    Total downloaded: ${_formatBytes(totalBytesDownloaded)}
    Average speed: ${_formatSpeed(averageDownloadSpeed)}
    Recent speed: ${_formatSpeed(recentAverageDownloadSpeed)}
  Retries:
    Total: $totalRetries, Succeeded: $retriesSucceeded, Failed: $retriesFailed
    Success rate: ${(retrySuccessRate * 100).toStringAsFixed(1)}%
  Errors by type: $errorCountsByType
''';
  }
}
