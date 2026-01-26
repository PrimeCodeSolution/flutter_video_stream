import '../cache/cache_manager.dart';

/// Stub proxy server for web platform (proxy not used on web)
class ProxyServer {
  ProxyServer(
      {required CacheManager cacheManager, int chunkSize = 2 * 1024 * 1024});

  bool get isRunning => false;
  int get port => 0;

  Future<void> start() async {}
  Future<void> stop() async {}
  String getProxyUrl(String originalUrl) => originalUrl;
}
