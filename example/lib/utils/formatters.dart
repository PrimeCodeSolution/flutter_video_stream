// Utility functions for formatting values

/// Format bytes to human-readable string
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Format bytes per second to human-readable speed string
String formatSpeed(int bytesPerSecond) {
  return '${formatBytes(bytesPerSecond)}/s';
}

/// Format percentage (0.0-1.0) to string
String formatPercent(double value) {
  return '${(value * 100).toStringAsFixed(1)}%';
}

/// Format duration to mm:ss or hh:mm:ss
String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

/// Format number with K/M suffix
String formatCompactNumber(int number) {
  if (number < 1000) return number.toString();
  if (number < 1000000) return '${(number / 1000).toStringAsFixed(1)}K';
  return '${(number / 1000000).toStringAsFixed(1)}M';
}
