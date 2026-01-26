import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

@JS('navigator.serviceWorker')
external ServiceWorkerContainer? get _serviceWorker;

@JS('ServiceWorkerContainer')
extension type ServiceWorkerContainer(JSObject _) implements JSObject {
  external JSPromise<JSAny> register(String scriptURL, [JSObject? options]);
  external JSPromise<ServiceWorkerRegistration> get ready;
  external ServiceWorker? get controller;
}

@JS('ServiceWorkerRegistration')
extension type ServiceWorkerRegistration(JSObject _) implements JSObject {
  external ServiceWorker? get active;
}

@JS('ServiceWorker')
extension type ServiceWorker(JSObject _) implements JSObject {
  external void postMessage(JSAny? message, [JSObject? transfer]);
}

class ServiceWorkerBridge {
  static final ServiceWorkerBridge _instance = ServiceWorkerBridge._();
  factory ServiceWorkerBridge() => _instance;
  ServiceWorkerBridge._();

  bool get isSupported => _serviceWorker != null;

  Completer<void>? _readyCompleter;

  Future<void> ensureReady() async {
    if (_readyCompleter != null) return _readyCompleter!.future;
    _readyCompleter = Completer<void>();

    if (!isSupported) {
      debugPrint('Service Worker not supported');
      _readyCompleter!.complete(); // Don't block
      return;
    }

    // Wait for service worker to be ready
    try {
      await _serviceWorker!.ready.toDart;
      _readyCompleter!.complete();
    } catch (e) {
      debugPrint('Error waiting for SW ready: $e');
      _readyCompleter!.complete();
    }
  }

  Future<Map<String, dynamic>> postMessage(Map<String, dynamic> message) async {
    if (!isSupported) return {};
    await ensureReady();

    final controller = _serviceWorker!.controller;
    if (controller == null) {
      debugPrint('No active service worker controller');
      return {};
    }

    final completer = Completer<Map<String, dynamic>>();

    final channel = web.MessageChannel();

    channel.port1.onmessage = (web.MessageEvent event) {
      final data = (event.data as JSObject).dartify();
      if (data is Map) {
        completer.complete(Map<String, dynamic>.from(data));
      } else {
        completer.complete({});
      }
    }.toJS;

    // Convert Map to JS object
    final jsMessage = message.jsify();

    // Send message with port2
    controller.postMessage(jsMessage, [channel.port2].jsify() as JSObject);

    return completer.future;
  }
}
