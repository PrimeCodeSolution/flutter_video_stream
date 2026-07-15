import 'dart:typed_data';

import 'object_url_store.dart';

/// Non-web stub: object URLs don't exist off-web. [WebCacheManager] catches
/// the throw and falls back to data URIs (only relevant in unit tests — on
/// real mobile platforms the mobile cache manager is used instead).
class _UnsupportedObjectUrlStore implements ObjectUrlStore {
  @override
  String createObjectUrl(Uint8List bytes, String mimeType) =>
      throw UnsupportedError('Object URLs are only supported on web');

  @override
  void revokeObjectUrl(String url) {}
}

ObjectUrlStore getPlatformObjectUrlStore() => _UnsupportedObjectUrlStore();
