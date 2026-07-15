// Integration tests for the proxy's MP4 edge-case handling: passthrough for
// servers with no usable Content-Length, and safe fallback for servers that
// ignore Range requests. A real ProxyServer talks to a real local upstream
// HttpServer with configurable behavior; correctness is asserted on the
// exact bytes the proxy delivers.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_stream/src/cache/mobile_cache_manager.dart';
import 'package:flutter_video_stream/src/proxy/proxy_server.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  FakePathProviderPlatform(this.temporaryPath);

  final String temporaryPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;
}

Uint8List makePayload(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => i % 251));

/// A local upstream video server with configurable capabilities.
class UpstreamServer {
  UpstreamServer({
    required this.payload,
    this.supportHead = true,
    this.supportRange = true,
    this.sendContentLength = true,
  });

  final Uint8List payload;
  final bool supportHead;
  final bool supportRange;

  /// When false, GET responses omit Content-Length, so Dart's HttpServer
  /// falls back to chunked transfer encoding.
  final bool sendContentLength;

  HttpServer? _server;
  final List<String?> rangeHeadersSeen = [];
  int requestCount = 0;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
    return 'http://127.0.0.1:${_server!.port}/video.mp4';
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    final response = request.response;

    if (request.method == 'HEAD') {
      if (!supportHead) {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      response.headers.contentType = ContentType('video', 'mp4');
      response.contentLength = payload.length;
      await response.close();
      return;
    }

    final rangeHeader = request.headers.value('range');
    rangeHeadersSeen.add(rangeHeader);

    if (rangeHeader != null && supportRange) {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final end = match.group(2)!.isEmpty
            ? payload.length - 1
            : int.parse(match.group(2)!).clamp(0, payload.length - 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers
            .set('Content-Range', 'bytes $start-$end/${payload.length}');
        response.contentLength = end - start + 1;
        response.add(payload.sublist(start, end + 1));
        await response.close();
        return;
      }
    }

    // Full-body 200 (Range, if any, is ignored).
    response.statusCode = HttpStatus.ok;
    if (sendContentLength) {
      response.contentLength = payload.length;
    }
    response.add(payload);
    await response.close();
  }
}

/// Fetches [url], returning status code, body bytes, and headers.
Future<(int, Uint8List, HttpHeaders)> fetch(String url,
    {String? range}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    if (range != null) {
      request.headers.set('Range', range);
    }
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return (response.statusCode, builder.takeBytes(), response.headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // flutter_test installs a mock HttpClient that 400s every request.
    // These tests only talk to local loopback servers, so restore real
    // networking.
    HttpOverrides.global = null;
  });

  late Directory tempRoot;
  late MobileCacheManager cacheManager;
  late ProxyServer proxy;
  UpstreamServer? upstream;

  // Payload spans multiple 1KB proxy chunks so chunk assembly is exercised.
  final payload = makePayload(5000);

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('proxy_passthrough_test');
    PathProviderPlatform.instance = FakePathProviderPlatform(tempRoot.path);

    cacheManager = MobileCacheManager();
    await cacheManager.initialize(
      respondToMemoryPressure: false,
      evictOnStartup: false,
    );

    proxy = ProxyServer(cacheManager: cacheManager, chunkSize: 1024);
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await upstream?.stop();
    upstream = null;
    cacheManager.dispose();
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  group('well-behaved server (chunked caching path)', () {
    test('full request delivers the exact payload', () async {
      upstream = UpstreamServer(payload: payload);
      final url = await upstream!.start();

      final (status, body, _) = await fetch(proxy.getProxyUrl(url));

      expect(status, HttpStatus.ok);
      expect(body, payload);
    });

    test('range request delivers the exact slice with 206 and Content-Range',
        () async {
      upstream = UpstreamServer(payload: payload);
      final url = await upstream!.start();

      final (status, body, headers) =
          await fetch(proxy.getProxyUrl(url), range: 'bytes=1000-2999');

      expect(status, HttpStatus.partialContent);
      expect(headers.value('content-range'), 'bytes 1000-2999/5000');
      expect(body, payload.sublist(1000, 3000));
    });

    test('HEAD-less server still works via the Range GET fallback', () async {
      upstream = UpstreamServer(payload: payload, supportHead: false);
      final url = await upstream!.start();

      final (status, body, _) = await fetch(proxy.getProxyUrl(url));

      expect(status, HttpStatus.ok);
      expect(body, payload);
    });
  });

  group('server with no usable Content-Length (passthrough)', () {
    test('chunked-transfer upstream is served via passthrough with correct '
        'bytes', () async {
      upstream = UpstreamServer(
        payload: payload,
        supportHead: false,
        supportRange: false,
        sendContentLength: false,
      );
      final url = await upstream!.start();

      final (status, body, _) = await fetch(proxy.getProxyUrl(url));

      expect(status, HttpStatus.ok);
      expect(body, payload);
    });

    test('subsequent requests keep using passthrough and stay correct',
        () async {
      upstream = UpstreamServer(
        payload: payload,
        supportHead: false,
        supportRange: false,
        sendContentLength: false,
      );
      final url = await upstream!.start();

      final (_, first, _) = await fetch(proxy.getProxyUrl(url));
      final requestsAfterFirst = upstream!.requestCount;
      final (status, second, _) = await fetch(proxy.getProxyUrl(url));

      expect(first, payload);
      expect(status, HttpStatus.ok);
      expect(second, payload);
      // The second proxy request must not re-run metadata probing - exactly
      // one more upstream GET (the passthrough itself).
      expect(upstream!.requestCount, requestsAfterFirst + 1);
    });
  });

  group('server that ignores Range requests (corruption regression)', () {
    // Regression: the server advertises Content-Length via HEAD, so the
    // chunked path starts, but it answers every ranged GET with the whole
    // file (200). Chunk data landed at wrong offsets and playback was
    // corrupted; now the proxy detects the 200, serves the request via
    // direct streaming with correct slicing, and flips the URL to
    // passthrough.
    test('full request still delivers the exact payload', () async {
      upstream = UpstreamServer(payload: payload, supportRange: false);
      final url = await upstream!.start();

      final (status, body, _) = await fetch(proxy.getProxyUrl(url));

      expect(status, HttpStatus.ok);
      expect(body, payload);
    });

    test('range request delivers exactly the requested slice', () async {
      upstream = UpstreamServer(payload: payload, supportRange: false);
      final url = await upstream!.start();

      final (status, body, headers) =
          await fetch(proxy.getProxyUrl(url), range: 'bytes=1500-2499');

      // The proxy honors the range itself even though upstream cannot.
      expect(status, HttpStatus.partialContent);
      expect(headers.value('content-range'), 'bytes 1500-2499/5000');
      expect(body, payload.sublist(1500, 2500));
    });
  });
}
