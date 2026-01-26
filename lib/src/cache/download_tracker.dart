import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Metadata for cached files, tracking access patterns for LRU eviction.
class CacheMetadata {
  final String url;
  final String filePath;
  final int fileSize;
  final DateTime created;
  final DateTime lastAccessed;
  final DateTime? expires;

  const CacheMetadata({
    required this.url,
    required this.filePath,
    required this.fileSize,
    required this.created,
    required this.lastAccessed,
    this.expires,
  });

  /// Create a copy with updated fields.
  CacheMetadata copyWith({
    DateTime? lastAccessed,
    DateTime? expires,
  }) {
    return CacheMetadata(
      url: url,
      filePath: filePath,
      fileSize: fileSize,
      created: created,
      lastAccessed: lastAccessed ?? this.lastAccessed,
      expires: expires ?? this.expires,
    );
  }

  /// Create from JSON map with validation.
  factory CacheMetadata.fromJson(Map<String, dynamic> json) {
    final url = json['url'];
    final filePath = json['filePath'];
    final fileSize = json['fileSize'];
    final created = json['created'];
    final lastAccessed = json['lastAccessed'];

    if (url is! String || filePath is! String || fileSize is! int ||
        created is! String || lastAccessed is! String) {
      throw FormatException('Invalid CacheMetadata JSON: $json');
    }

    return CacheMetadata(
      url: url,
      filePath: filePath,
      fileSize: fileSize,
      created: DateTime.parse(created),
      lastAccessed: DateTime.parse(lastAccessed),
      expires: json['expires'] != null
          ? DateTime.tryParse(json['expires'] as String)
          : null,
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() => {
        'url': url,
        'filePath': filePath,
        'fileSize': fileSize,
        'created': created.toIso8601String(),
        'lastAccessed': lastAccessed.toIso8601String(),
        'expires': expires?.toIso8601String(),
      };

  /// Check if this cache entry has expired
  bool get isExpired =>
      expires != null && DateTime.now().isAfter(expires!);
}

/// Tracks partial downloads for resumption support.
/// Uses .partial files to store incomplete downloads.
class DownloadTracker {
  final Directory cacheDir;

  /// In-memory cache to debounce lastAccessed writes.
  final Map<String, DateTime> _lastAccessedCache = {};
  static const _writeThreshold = Duration(minutes: 5);

  /// Maximum size for the last accessed cache to prevent unbounded growth
  static const int _maxCacheSize = 1000;

  DownloadTracker({required this.cacheDir});

  /// Clean up the last accessed cache if it exceeds max size
  void _cleanupLastAccessedCache() {
    if (_lastAccessedCache.length <= _maxCacheSize) return;

    // Keep only the most recent entries (half of max size)
    final entries = _lastAccessedCache.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    _lastAccessedCache.clear();
    for (final entry in entries.take(_maxCacheSize ~/ 2)) {
      _lastAccessedCache[entry.key] = entry.value;
    }
  }

  /// Get the partial file for a URL's cache file
  File getPartialFile(File cacheFile) {
    return File('${cacheFile.path}.partial');
  }

  /// Get the metadata file that stores expected content length
  File _getMetaFile(File cacheFile) {
    return File('${cacheFile.path}.meta');
  }

  /// Get current downloaded bytes for a partial file
  Future<int> getDownloadedBytes(File cacheFile) async {
    final partial = getPartialFile(cacheFile);
    if (await partial.exists()) {
      return await partial.length();
    }
    return 0;
  }

  /// Get expected total bytes from metadata
  Future<int?> getExpectedBytes(File cacheFile) async {
    final meta = _getMetaFile(cacheFile);
    if (await meta.exists()) {
      try {
        final content = await meta.readAsString();
        return int.tryParse(content.trim());
      } catch (e) {
        debugPrint('DownloadTracker: Failed to read meta file: $e');
      }
    }
    return null;
  }

  /// Save expected total bytes to metadata
  Future<void> saveExpectedBytes(File cacheFile, int totalBytes) async {
    final meta = _getMetaFile(cacheFile);
    try {
      await meta.writeAsString(totalBytes.toString());
    } catch (e) {
      debugPrint('DownloadTracker: Failed to write meta file: $e');
    }
  }

  /// Append bytes to partial file
  Future<void> appendBytes(File cacheFile, List<int> bytes) async {
    final partial = getPartialFile(cacheFile);
    try {
      await partial.writeAsBytes(bytes, mode: FileMode.append);
    } catch (e) {
      debugPrint('DownloadTracker: Failed to append bytes: $e');
      rethrow;
    }
  }

  /// Complete the download by renaming partial to final
  Future<void> completeDownload(File cacheFile) async {
    final partial = getPartialFile(cacheFile);
    final meta = _getMetaFile(cacheFile);

    try {
      // Rename partial to final
      if (await partial.exists()) {
        await partial.rename(cacheFile.path);
      }
      // Clean up metadata
      if (await meta.exists()) {
        await meta.delete();
      }
    } catch (e) {
      debugPrint('DownloadTracker: Failed to complete download: $e');
      rethrow;
    }
  }

  /// Cancel and clean up a partial download
  Future<void> cancelDownload(File cacheFile) async {
    final partial = getPartialFile(cacheFile);
    final meta = _getMetaFile(cacheFile);

    try {
      if (await partial.exists()) {
        await partial.delete();
      }
      if (await meta.exists()) {
        await meta.delete();
      }
    } catch (e) {
      debugPrint('DownloadTracker: Failed to cancel download: $e');
    }
  }

  /// Check if a partial download exists and is valid
  Future<bool> hasValidPartial(File cacheFile) async {
    final partial = getPartialFile(cacheFile);
    if (!await partial.exists()) return false;

    final downloadedBytes = await partial.length();
    final expectedBytes = await getExpectedBytes(cacheFile);

    // Valid if we have bytes and either no expected size or downloaded < expected
    if (downloadedBytes > 0) {
      if (expectedBytes == null) return true;
      return downloadedBytes < expectedBytes;
    }
    return false;
  }

  /// Clean up orphaned partial files (no matching cache file and older than maxAge)
  Future<void> cleanupOrphans(
      {Duration maxAge = const Duration(hours: 24)}) async {
    if (!await cacheDir.exists()) return;

    final now = DateTime.now();
    try {
      await for (final entity in cacheDir.list()) {
        if (entity is File && entity.path.endsWith('.partial')) {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > maxAge) {
            await entity.delete();
            debugPrint('DownloadTracker: Cleaned up orphan ${entity.path}');
          }
        }
      }
    } catch (e) {
      debugPrint('DownloadTracker: Error during cleanup: $e');
    }
  }

  // ============ Cache Metadata Methods ============

  /// Get the cache metadata file for a cache file
  File _getCacheMetaFile(File cacheFile) {
    return File('${cacheFile.path}.cachemeta');
  }

  /// Save cache metadata for a completed download
  Future<void> saveCacheMetadata(
    File cacheFile,
    CacheMetadata metadata,
  ) async {
    final metaFile = _getCacheMetaFile(cacheFile);
    try {
      final jsonStr = jsonEncode(metadata.toJson());
      await metaFile.writeAsString(jsonStr);
    } catch (e) {
      debugPrint('DownloadTracker: Failed to save cache metadata: $e');
    }
  }

  /// Load cache metadata for a cache file
  Future<CacheMetadata?> loadCacheMetadata(File cacheFile) async {
    final metaFile = _getCacheMetaFile(cacheFile);
    if (!await metaFile.exists()) return null;

    try {
      final content = await metaFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return CacheMetadata.fromJson(json);
    } catch (e) {
      debugPrint('DownloadTracker: Failed to load cache metadata: $e');
      return null;
    }
  }

  /// Update last accessed timestamp for a cache file.
  /// Debounced to reduce disk I/O - only writes every 5 minutes per file.
  Future<void> updateLastAccessed(File cacheFile) async {
    final path = cacheFile.path;
    final now = DateTime.now();
    final lastWritten = _lastAccessedCache[path];

    // Only write to disk every 5 minutes per file
    if (lastWritten != null && now.difference(lastWritten) < _writeThreshold) {
      return;
    }

    final metadata = await loadCacheMetadata(cacheFile);
    if (metadata != null) {
      final updated = metadata.copyWith(lastAccessed: now);
      await saveCacheMetadata(cacheFile, updated);
      _lastAccessedCache[path] = now;

      // Periodically clean up the cache to prevent unbounded growth
      _cleanupLastAccessedCache();
    }
  }

  /// Get all cache metadata from the cache directory.
  /// If [validateFiles] is true (default), validates that cache files exist
  /// and cleans up orphaned metadata files.
  Future<List<CacheMetadata>> getAllCacheMetadata({bool validateFiles = true}) async {
    if (!await cacheDir.exists()) return [];

    final results = <CacheMetadata>[];
    final toDelete = <File>[];

    try {
      await for (final entity in cacheDir.list()) {
        if (entity is File && entity.path.endsWith('.cachemeta')) {
          try {
            final content = await entity.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            final metadata = CacheMetadata.fromJson(json);

            // Validate that the actual cache file exists
            if (validateFiles) {
              final cacheFile = File(metadata.filePath);
              if (!await cacheFile.exists()) {
                toDelete.add(entity);
                continue;
              }
            }

            results.add(metadata);
          } catch (e) {
            // Skip and delete invalid metadata files
            debugPrint('DownloadTracker: Invalid metadata file ${entity.path}');
            toDelete.add(entity);
          }
        }
      }

      // Clean up orphaned metadata files
      for (final file in toDelete) {
        try {
          await file.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('DownloadTracker: Error scanning metadata: $e');
    }
    return results;
  }

  /// Delete cache metadata file
  Future<void> deleteCacheMetadata(File cacheFile) async {
    final metaFile = _getCacheMetaFile(cacheFile);
    try {
      if (await metaFile.exists()) {
        await metaFile.delete();
      }
    } catch (e) {
      debugPrint('DownloadTracker: Failed to delete cache metadata: $e');
    }
  }
}
