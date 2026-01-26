/// Shared HTTP utilities with pre-compiled regex patterns.
class HttpUtils {
  /// Pre-compiled regex for parsing HTTP Range headers.
  static final _rangeRegex = RegExp(r'bytes=(\d+)-(\d*)');

  /// Parse an HTTP Range header.
  ///
  /// Returns a tuple of (start, end) if valid, or null if invalid.
  /// If end is not specified in the header, it will be null in the result.
  static (int start, int? end)? parseRangeHeader(String? rangeHeader) {
    if (rangeHeader == null) return null;
    final match = _rangeRegex.firstMatch(rangeHeader);
    if (match == null) return null;
    final start = int.parse(match.group(1)!);
    final endStr = match.group(2);
    final end = endStr != null && endStr.isNotEmpty ? int.parse(endStr) : null;
    return (start, end);
  }

  /// Parse and validate a Range header against a total content length.
  ///
  /// Returns a tuple of (start, end) clamped to valid range, or null if invalid.
  static (int start, int end)? parseRange(String? rangeHeader, int totalLength) {
    final parsed = parseRangeHeader(rangeHeader);
    if (parsed == null) return null;

    final start = parsed.$1;
    final end = parsed.$2 ?? totalLength - 1;

    if (start >= totalLength || start > end) return null;

    return (start, end.clamp(0, totalLength - 1));
  }
}
