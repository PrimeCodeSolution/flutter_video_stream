import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'object_url_store.dart';

/// Real browser implementation backed by `Blob` + `URL.createObjectURL`.
class _WebObjectUrlStore implements ObjectUrlStore {
  @override
  String createObjectUrl(Uint8List bytes, String mimeType) {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    return web.URL.createObjectURL(blob);
  }

  @override
  void revokeObjectUrl(String url) {
    if (url.startsWith('blob:')) {
      web.URL.revokeObjectURL(url);
    }
  }
}

ObjectUrlStore getPlatformObjectUrlStore() => _WebObjectUrlStore();
