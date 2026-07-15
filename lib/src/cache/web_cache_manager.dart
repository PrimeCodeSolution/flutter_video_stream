import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'cache_manager.dart';
import 'object_url_store.dart';

CacheManager getPlatformCacheManager() => WebCacheManager();

/// Web cache manager.
///
/// URL sources remain a pure pass-through — the browser's native HTTP cache
/// handles them. Injected content ([putBytes]) is held in memory and served
/// through blob object URLs (with a data-URI fallback when object URLs are
/// unavailable). Injected entries participate in an LRU capped by the
/// configured max cache size, and are counted by [getSize].
class WebCacheManager implements CacheManager {
  /// Creates the web cache manager.
  ///
  /// [objectUrlStore] is injectable for tests; the platform store is used
  /// when omitted.
  WebCacheManager({ObjectUrlStore? objectUrlStore})
      : _store = objectUrlStore ?? getPlatformObjectUrlStore();

  final ObjectUrlStore _store;

  /// Injected entries in LRU order (least recently used first).
  final LinkedHashMap<String, _WebCacheEntry> _entries = LinkedHashMap();
  int _maxCacheSize = 500 * 1024 * 1024;
  int _currentSize = 0;

  /// Keys currently surfaced (acquired by a player); never evicted.
  Set<String> Function()? _activeKeysProvider;

  @override
  set activeKeysProvider(Set<String> Function()? provider) {
    _activeKeysProvider = provider;
  }

  /// Notified when a key's cached content is deleted (see [CacheManager.onEvicted]).
  void Function(String key)? _onEvicted;

  @override
  set onEvicted(void Function(String key)? callback) {
    _onEvicted = callback;
  }

  @override
  Future<void> initialize({
    bool keepCache = true,
    Duration cacheTTL = const Duration(days: 7),
    int memoryCacheSize = 100 * 1024 * 1024,
    int maxDiskCacheSize = 500 * 1024 * 1024,
    bool respondToMemoryPressure = true,
    double memoryPressureRetainPercent = 0.25,
    bool evictOnStartup = true,
    bool enableRetry = true,
    int maxRetries = 3,
    bool enableMetrics = true,
    int maxBandwidthBytesPerSecond = 0,
  }) async {
    _maxCacheSize = maxDiskCacheSize;
    debugPrint(
        'WebCacheManager: Initialized (browser cache for URLs, blob store for injected bytes)');
  }

  @override
  Future<String> getCacheUrl(String originalUrl,
      {Map<String, String>? headers}) async {
    final entry = _entries.remove(originalUrl);
    if (entry != null) {
      // Re-insert at the end: most recently used
      _entries[originalUrl] = entry;
      return entry.servedUrl;
    }
    // URL flow: browser handles caching natively
    return originalUrl;
  }

  @override
  Future<void> putBytes(
    String key,
    Uint8List bytes, {
    String? mimeType,
    String? filename,
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'must not be empty');
    }

    // Replace any existing entry for this key
    _removeEntry(key);

    // Evict least recently used, non-surfaced entries until the new one
    // fits. The cap is soft: surfaced videos are never evicted, and the
    // new entry (about to surface) is stored even if it alone exceeds the
    // cap - it gets reclaimed once out of view.
    _evictUntilFits(bytes.length, extraProtected: {key});

    final mime = _resolveMimeType(mimeType: mimeType, filename: filename);
    String servedUrl;
    try {
      servedUrl = _store.createObjectUrl(bytes, mime);
    } catch (e) {
      debugPrint(
          'WebCacheManager: Object URL unavailable ($e), using data URI for $key');
      servedUrl = 'data:$mime;base64,${base64Encode(bytes)}';
    }

    _entries[key] = _WebCacheEntry(servedUrl: servedUrl, size: bytes.length);
    _currentSize += bytes.length;
    debugPrint(
        'WebCacheManager: Stored ${bytes.length} bytes for key $key ($_currentSize/$_maxCacheSize total)');
  }

  String _resolveMimeType({String? mimeType, String? filename}) {
    final explicit = mimeType?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final lower = filename?.toLowerCase() ?? '';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.ts')) return 'video/mp2t';
    return 'video/mp4';
  }

  void _removeEntry(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return;
    _currentSize -= entry.size;
    // Never revoke a blob URL a playing controller is streaming from
    // (explicit remove/re-inject of a surfaced key). The blob lives until
    // page unload - a deliberate, bounded leak in a rare app-driven case.
    final surfaced = _activeKeysProvider?.call().contains(key) ?? false;
    if (surfaced) {
      debugPrint(
          'WebCacheManager: $key removed while playing; deferring blob revocation to page unload');
    } else {
      _store.revokeObjectUrl(entry.servedUrl);
    }
    // Drop any warm controller still pointing at the removed URL
    _onEvicted?.call(key);
  }

  /// Evict LRU-first until [incomingBytes] more fit under the cap, skipping
  /// surfaced keys and [extraProtected]. May leave the cache over the cap
  /// when everything remaining is surfaced.
  void _evictUntilFits(int incomingBytes,
      {Set<String> extraProtected = const {}}) {
    if (_currentSize + incomingBytes <= _maxCacheSize) return;

    final protected = <String>{
      ...?_activeKeysProvider?.call(),
      ...extraProtected,
    };

    for (final key in _entries.keys.toList()) {
      if (_currentSize + incomingBytes <= _maxCacheSize) break;
      // Never evict a video that is currently surfaced
      if (protected.contains(key)) continue;
      debugPrint('WebCacheManager: Evicting $key (LRU)');
      _removeEntry(key);
    }
  }

  @override
  Future<void> evictIfNeeded() async {
    _evictUntilFits(0);
  }

  @override
  Future<void> precache(String url,
      {int? bytes, Map<String, String>? headers}) async {
    // No-op on web - can't precache without service worker
  }

  @override
  Future<CacheStatus> getStatus(String url) async {
    return _entries.containsKey(url) ? CacheStatus.complete : CacheStatus.none;
  }

  @override
  Future<void> remove(String url) async {
    _removeEntry(url);
  }

  @override
  Future<void> clear() async {
    for (final entry in _entries.values) {
      _store.revokeObjectUrl(entry.servedUrl);
    }
    _entries.clear();
    _currentSize = 0;
  }

  @override
  Future<int> getSize() async {
    return _currentSize;
  }

  @override
  void dispose() {
    // Revoke synchronously; clear() is async only to satisfy the interface.
    for (final entry in _entries.values) {
      _store.revokeObjectUrl(entry.servedUrl);
    }
    _entries.clear();
    _currentSize = 0;
  }
}

class _WebCacheEntry {
  final String servedUrl;
  final int size;

  _WebCacheEntry({required this.servedUrl, required this.size});
}
