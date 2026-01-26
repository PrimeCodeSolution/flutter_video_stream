import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';

/// Configuration for retry behavior
class RetryConfig {
  /// Maximum number of retry attempts
  final int maxRetries;

  /// Initial delay before first retry
  final Duration initialDelay;

  /// Maximum delay between retries
  final Duration maxDelay;

  /// Multiplier for exponential backoff
  final double backoffMultiplier;

  /// HTTP status codes that should trigger a retry
  final Set<int> retryableStatusCodes;

  const RetryConfig({
    this.maxRetries = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
    this.retryableStatusCodes = const {
      408, // Request Timeout
      429, // Too Many Requests
      500, // Internal Server Error
      502, // Bad Gateway
      503, // Service Unavailable
      504, // Gateway Timeout
    },
  });

  /// Default config for most operations
  static const defaultConfig = RetryConfig();

  /// More aggressive config for critical operations
  static const aggressiveConfig = RetryConfig(
    maxRetries: 5,
    initialDelay: Duration(milliseconds: 250),
    maxDelay: Duration(seconds: 60),
  );

  /// Light config for non-critical operations
  static const lightConfig = RetryConfig(
    maxRetries: 2,
    initialDelay: Duration(milliseconds: 1000),
    maxDelay: Duration(seconds: 10),
  );
}

/// Helper class for retry operations with exponential backoff
class RetryHelper {
  static final _random = Random();

  /// Execute an async operation with retry logic
  ///
  /// Returns the result of [operation] if successful.
  /// Throws the last error if all retries are exhausted.
  static Future<T> retry<T>({
    required Future<T> Function() operation,
    RetryConfig config = const RetryConfig(),
    bool Function(Object error)? shouldRetry,
    void Function(int attempt, Object error, Duration nextDelay)? onRetry,
  }) async {
    int attempt = 0;
    Duration delay = config.initialDelay;

    while (true) {
      try {
        return await operation();
      } catch (e) {
        attempt++;

        // Check if we should retry
        final canRetry = attempt <= config.maxRetries &&
            (shouldRetry?.call(e) ?? _isRetryableError(e, config));

        if (!canRetry) {
          rethrow;
        }

        // Add jitter to prevent thundering herd
        final jitter = _random.nextDouble() * 0.3 + 0.85; // 0.85 - 1.15
        final actualDelay = Duration(
          milliseconds: (delay.inMilliseconds * jitter).round(),
        );

        onRetry?.call(attempt, e, actualDelay);
        debugPrint(
          'RetryHelper: Attempt $attempt failed, retrying in ${actualDelay.inMilliseconds}ms: $e',
        );

        await Future.delayed(actualDelay);

        // Calculate next delay with exponential backoff
        delay = Duration(
          milliseconds:
              (delay.inMilliseconds * config.backoffMultiplier).round(),
        );
        if (delay > config.maxDelay) {
          delay = config.maxDelay;
        }
      }
    }
  }

  /// Execute an HTTP request with retry logic
  static Future<HttpClientResponse> retryHttpRequest({
    required Future<HttpClientRequest> Function() createRequest,
    RetryConfig config = const RetryConfig(),
    void Function(int attempt, Object error, Duration nextDelay)? onRetry,
  }) async {
    return retry<HttpClientResponse>(
      operation: () async {
        final request = await createRequest();
        final response = await request.close();

        // Check if status code indicates a retryable error
        if (config.retryableStatusCodes.contains(response.statusCode)) {
          // Drain the response to free resources
          await response.drain<void>();
          throw HttpRetryableException(
            'HTTP ${response.statusCode}',
            response.statusCode,
          );
        }

        return response;
      },
      config: config,
      shouldRetry: (e) => _isRetryableError(e, config),
      onRetry: onRetry,
    );
  }

  /// Check if an error is retryable
  static bool _isRetryableError(Object error, RetryConfig config) {
    // Network errors are retryable
    if (error is SocketException) return true;
    if (error is HttpException) return true;
    if (error is TimeoutException) return true;
    if (error is HandshakeException) return true;

    // Our custom retryable exception
    if (error is HttpRetryableException) return true;

    return false;
  }
}

/// Exception indicating an HTTP error that can be retried
class HttpRetryableException implements Exception {
  final String message;
  final int statusCode;

  HttpRetryableException(this.message, this.statusCode);

  @override
  String toString() => 'HttpRetryableException: $message (status: $statusCode)';
}
