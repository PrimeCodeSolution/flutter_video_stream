import 'dart:typed_data';

import 'object_url_store_stub.dart'
    if (dart.library.js_interop) 'object_url_store_web.dart' as platform;

/// Creates and revokes browser object URLs for in-memory video bytes.
///
/// Abstracted behind an interface so [WebCacheManager] can be unit tested
/// off-web with a fake, and so the data-URI fallback can kick in when object
/// URLs are unavailable.
abstract class ObjectUrlStore {
  /// Returns a URL the browser can play [bytes] from (a `blob:` URL).
  ///
  /// Throws if object URLs are not supported in the current environment.
  String createObjectUrl(Uint8List bytes, String mimeType);

  /// Releases the resources behind [url]. Only `blob:` URLs need revoking;
  /// anything else is a no-op.
  void revokeObjectUrl(String url);
}

/// The [ObjectUrlStore] for the current platform (real blobs on web, an
/// unsupported-throwing stub elsewhere).
ObjectUrlStore getPlatformObjectUrlStore() =>
    platform.getPlatformObjectUrlStore();
