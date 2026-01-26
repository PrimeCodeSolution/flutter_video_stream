import 'dart:collection';
import 'package:flutter/foundation.dart';

/// LRU (Least Recently Used) memory cache for video data.
/// Stores video bytes in RAM for fast access.
class LruMemoryCache {
  final int maxSizeBytes;

  /// LinkedHashMap maintains insertion order, enabling LRU eviction
  final LinkedHashMap<String, _CacheEntry> _cache = LinkedHashMap();
  int _currentSize = 0;

  LruMemoryCache({required this.maxSizeBytes});

  /// Get cached data for a URL. Returns null if not cached.
  /// Moves the entry to the end (most recently used) on access.
  Uint8List? get(String url) {
    final entry = _cache.remove(url);
    if (entry == null) return null;

    // Re-insert at end (most recently used)
    _cache[url] = entry;
    debugPrint(
        'LruMemoryCache: HIT for $url (${_formatBytes(entry.data.length)})');
    return entry.data;
  }

  /// Store data in cache. Evicts LRU entries if over size limit.
  void put(String url, Uint8List data) {
    // Don't cache if single item exceeds max size
    if (data.length > maxSizeBytes) {
      debugPrint(
          'LruMemoryCache: Item too large to cache (${_formatBytes(data.length)} > ${_formatBytes(maxSizeBytes)})');
      return;
    }

    // Remove existing entry if present
    final existing = _cache.remove(url);
    if (existing != null) {
      _currentSize -= existing.data.length;
    }

    // Evict until we have room
    _evictIfNeeded(data.length);

    // Add new entry
    _cache[url] = _CacheEntry(data: data, timestamp: DateTime.now());
    _currentSize += data.length;

    debugPrint(
        'LruMemoryCache: STORED $url (${_formatBytes(data.length)}, total: ${_formatBytes(_currentSize)}/${_formatBytes(maxSizeBytes)})');
  }

  /// Check if URL is in memory cache
  bool contains(String url) => _cache.containsKey(url);

  /// Remove specific URL from cache
  void remove(String url) {
    final entry = _cache.remove(url);
    if (entry != null) {
      _currentSize -= entry.data.length;
      debugPrint('LruMemoryCache: REMOVED $url');
    }
  }

  /// Clear all cached data
  void clear() {
    _cache.clear();
    _currentSize = 0;
    debugPrint('LruMemoryCache: CLEARED');
  }

  /// Current cache size in bytes
  int get currentSize => _currentSize;

  /// Number of items in cache
  int get itemCount => _cache.length;

  /// Evict oldest entries until we have room for [neededBytes]
  void _evictIfNeeded(int neededBytes) {
    while (_currentSize + neededBytes > maxSizeBytes && _cache.isNotEmpty) {
      // Remove first entry (oldest/least recently used)
      final oldestKey = _cache.keys.first;
      final evicted = _cache.remove(oldestKey);
      if (evicted != null) {
        _currentSize -= evicted.data.length;
        debugPrint(
            'LruMemoryCache: EVICTED $oldestKey (${_formatBytes(evicted.data.length)})');
      }
    }
  }

  /// Evict entries until cache is at or below [targetPercent] of max size.
  ///
  /// Returns the number of bytes freed.
  int evictToPercent(double targetPercent) {
    if (targetPercent < 0 || targetPercent > 1) {
      throw ArgumentError('targetPercent must be between 0 and 1');
    }

    final targetSize = (maxSizeBytes * targetPercent).round();
    int freedBytes = 0;

    while (_currentSize > targetSize && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final evicted = _cache.remove(oldestKey);
      if (evicted != null) {
        _currentSize -= evicted.data.length;
        freedBytes += evicted.data.length;
        debugPrint(
            'LruMemoryCache: EVICTED (pressure) $oldestKey (${_formatBytes(evicted.data.length)})');
      }
    }

    if (freedBytes > 0) {
      debugPrint(
          'LruMemoryCache: Freed ${_formatBytes(freedBytes)} to reach ${(targetPercent * 100).toInt()}% of max');
    }

    return freedBytes;
  }

  /// Emergency eviction: clear all entries.
  ///
  /// Returns the number of bytes freed.
  int evictAll() {
    final freedBytes = _currentSize;
    _cache.clear();
    _currentSize = 0;
    debugPrint('LruMemoryCache: EMERGENCY EVICTION - freed ${_formatBytes(freedBytes)}');
    return freedBytes;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _CacheEntry {
  final Uint8List data;
  final DateTime timestamp;

  _CacheEntry({required this.data, required this.timestamp});
}
