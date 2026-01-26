import 'dart:async';

/// Throttles data streams to a maximum bytes per second rate
class BandwidthThrottler {
  /// Maximum bytes per second (0 = unlimited)
  final int maxBytesPerSecond;

  /// Bucket size for token bucket algorithm (allows small bursts)
  final int _bucketSize;

  /// Current tokens in bucket
  int _tokens;

  /// Last refill time
  DateTime _lastRefill;

  /// Whether throttling is enabled
  bool get isEnabled => maxBytesPerSecond > 0;

  BandwidthThrottler({
    this.maxBytesPerSecond = 0,
  })  : _bucketSize = maxBytesPerSecond > 0
            ? (maxBytesPerSecond * 2).clamp(65536, 10 * 1024 * 1024)
            : 0,
        _tokens = maxBytesPerSecond > 0
            ? (maxBytesPerSecond * 2).clamp(65536, 10 * 1024 * 1024)
            : 0,
        _lastRefill = DateTime.now();

  /// Refill tokens based on time elapsed
  void _refillTokens() {
    if (!isEnabled) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastRefill);
    final tokensToAdd =
        (elapsed.inMicroseconds * maxBytesPerSecond / 1000000).round();

    if (tokensToAdd > 0) {
      _tokens = (_tokens + tokensToAdd).clamp(0, _bucketSize);
      _lastRefill = now;
    }
  }

  /// Request to send [bytes] bytes
  /// Returns a Future that completes when allowed to send
  /// The returned int is the number of bytes allowed (may be less than requested)
  Future<int> requestBytes(int bytes) async {
    if (!isEnabled) return bytes;

    _refillTokens();

    // If we have enough tokens, use them immediately
    if (_tokens >= bytes) {
      _tokens -= bytes;
      return bytes;
    }

    // If bucket is empty, wait for refill
    if (_tokens <= 0) {
      // Calculate wait time for at least some tokens
      final minBytes = bytes.clamp(1, 65536); // Request at least 64KB
      final waitMicros = (minBytes * 1000000) ~/ maxBytesPerSecond;
      await Future.delayed(Duration(microseconds: waitMicros));
      _refillTokens();
    }

    // Return what we have (partial send)
    final allowed = _tokens.clamp(0, bytes);
    _tokens -= allowed;
    return allowed > 0 ? allowed : 1; // Always allow at least 1 byte to progress
  }

  /// Wrap a stream to throttle its throughput
  Stream<List<int>> throttleStream(Stream<List<int>> source) async* {
    if (!isEnabled) {
      yield* source;
      return;
    }

    await for (final chunk in source) {
      int offset = 0;
      while (offset < chunk.length) {
        final remaining = chunk.length - offset;
        final allowed = await requestBytes(remaining);
        yield chunk.sublist(offset, offset + allowed);
        offset += allowed;
      }
    }
  }

  /// Create a throttled sink that wraps another sink
  ThrottledSink<List<int>> throttleSink(EventSink<List<int>> sink) {
    return ThrottledSink(sink, this);
  }

  /// Reset the throttler state
  void reset() {
    _tokens = _bucketSize;
    _lastRefill = DateTime.now();
  }
}

/// A sink that throttles data before forwarding to the wrapped sink
class ThrottledSink<T extends List<int>> implements EventSink<T> {
  final EventSink<T> _sink;
  final BandwidthThrottler _throttler;
  bool _isClosed = false;

  ThrottledSink(this._sink, this._throttler);

  @override
  void add(T data) {
    if (_isClosed) return;

    if (!_throttler.isEnabled) {
      _sink.add(data);
      return;
    }

    // For sync sink, we need to handle throttling differently
    // Queue the data and process asynchronously
    _processAsync(data);
  }

  Future<void> _processAsync(T data) async {
    int offset = 0;
    while (offset < data.length && !_isClosed) {
      final remaining = data.length - offset;
      final allowed = await _throttler.requestBytes(remaining);
      if (_isClosed) return;

      final chunk = data.sublist(offset, offset + allowed);
      _sink.add(chunk as T);
      offset += allowed;
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (!_isClosed) {
      _sink.addError(error, stackTrace);
    }
  }

  @override
  void close() {
    _isClosed = true;
    _sink.close();
  }
}

/// Stream transformer that applies bandwidth throttling
class BandwidthThrottleTransformer
    implements StreamTransformer<List<int>, List<int>> {
  final BandwidthThrottler throttler;

  BandwidthThrottleTransformer(this.throttler);

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) {
    return throttler.throttleStream(stream);
  }

  @override
  StreamTransformer<RS, RT> cast<RS, RT>() {
    return StreamTransformer.castFrom(this);
  }
}
