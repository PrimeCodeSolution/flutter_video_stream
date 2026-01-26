import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Simple HLS (m3u8) playlist parser.
/// Extracts segment URLs and playlist metadata.
class HlsParser {
  /// Parse an HLS playlist from content string
  static HlsPlaylist parse(String content, String baseUrl) {
    final lines = LineSplitter.split(content).toList();

    if (lines.isEmpty || !lines.first.startsWith('#EXTM3U')) {
      throw FormatException('Invalid HLS playlist: missing #EXTM3U header');
    }

    // Determine if this is a master playlist or media playlist
    final isMaster = lines.any((line) =>
        line.startsWith('#EXT-X-STREAM-INF') ||
        line.startsWith('#EXT-X-I-FRAME-STREAM-INF'));

    if (isMaster) {
      return _parseMasterPlaylist(lines, baseUrl);
    } else {
      return _parseMediaPlaylist(lines, baseUrl);
    }
  }

  /// Parse a master playlist (contains variant streams)
  static HlsMasterPlaylist _parseMasterPlaylist(
      List<String> lines, String baseUrl) {
    final variants = <HlsVariant>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        // Parse attributes
        final attrs =
            _parseAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
        final bandwidth = int.tryParse(attrs['BANDWIDTH'] ?? '0') ?? 0;
        final resolution = attrs['RESOLUTION'];
        final codecs = attrs['CODECS'];

        // Next non-comment line is the URI
        String? uri;
        for (var j = i + 1; j < lines.length; j++) {
          if (!lines[j].startsWith('#') && lines[j].trim().isNotEmpty) {
            uri = _resolveUrl(lines[j].trim(), baseUrl);
            break;
          }
        }

        if (uri != null) {
          variants.add(HlsVariant(
            url: uri,
            bandwidth: bandwidth,
            resolution: resolution,
            codecs: codecs,
          ));
        }
      }
    }

    // Sort by bandwidth (highest first)
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));

    return HlsMasterPlaylist(
      baseUrl: baseUrl,
      variants: variants,
    );
  }

  /// Parse a media playlist (contains segments)
  static HlsMediaPlaylist _parseMediaPlaylist(
      List<String> lines, String baseUrl) {
    final segments = <HlsSegment>[];
    double targetDuration = 0;
    int mediaSequence = 0;
    bool isLive = true;
    String? encryption;
    String? encryptionKeyUrl;

    double currentDuration = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        targetDuration = double.tryParse(line.split(':').last) ?? 0;
      } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence = int.tryParse(line.split(':').last) ?? 0;
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        isLive = false;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final attrs = _parseAttributes(line.substring('#EXT-X-KEY:'.length));
        encryption = attrs['METHOD'];
        if (attrs.containsKey('URI')) {
          encryptionKeyUrl = _resolveUrl(
            attrs['URI']!.replaceAll('"', ''),
            baseUrl,
          );
        }
      } else if (line.startsWith('#EXTINF:')) {
        // Parse duration
        final durationStr = line.substring('#EXTINF:'.length).split(',').first;
        currentDuration = double.tryParse(durationStr) ?? 0;
      } else if (!line.startsWith('#') && line.trim().isNotEmpty) {
        // This is a segment URL
        final url = _resolveUrl(line.trim(), baseUrl);
        segments.add(HlsSegment(
          url: url,
          duration: currentDuration,
          sequence: mediaSequence + segments.length,
          isEncrypted: encryption != null && encryption != 'NONE',
        ));
        currentDuration = 0;
      }
    }

    return HlsMediaPlaylist(
      baseUrl: baseUrl,
      segments: segments,
      targetDuration: targetDuration,
      mediaSequence: mediaSequence,
      isLive: isLive,
      encryption: encryption,
      encryptionKeyUrl: encryptionKeyUrl,
    );
  }

  /// Parse HLS attribute string (KEY=VALUE,KEY2="VALUE2")
  static Map<String, String> _parseAttributes(String attrs) {
    final result = <String, String>{};
    final regex = RegExp(r'([A-Z0-9-]+)=("([^"]*)"|([^,]*))');

    for (final match in regex.allMatches(attrs)) {
      final key = match.group(1)!;
      final value = match.group(3) ?? match.group(4) ?? '';
      result[key] = value;
    }

    return result;
  }

  /// Resolve a relative URL against a base URL
  static String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    final base = Uri.parse(baseUrl);

    if (url.startsWith('/')) {
      // Absolute path
      return '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}$url';
    } else {
      // Relative path
      final basePath = base.path.substring(0, base.path.lastIndexOf('/') + 1);
      return '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}$basePath$url';
    }
  }

  /// Fetch and parse an HLS playlist from a URL
  static Future<HlsPlaylist> fetch(String url,
      {Map<String, String>? headers}) async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));

      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }

      final response = await request.close();

      if (response.statusCode != 200) {
        throw HttpException('Failed to fetch playlist: ${response.statusCode}');
      }

      final content = await response.transform(utf8.decoder).join();
      client.close();

      return parse(content, url);
    } catch (e) {
      debugPrint('HlsParser: Error fetching playlist: $e');
      rethrow;
    }
  }
}

/// Base class for HLS playlists
abstract class HlsPlaylist {
  final String baseUrl;

  HlsPlaylist({required this.baseUrl});

  bool get isMaster;
}

/// Master playlist containing variant streams
class HlsMasterPlaylist extends HlsPlaylist {
  final List<HlsVariant> variants;

  HlsMasterPlaylist({
    required super.baseUrl,
    required this.variants,
  });

  @override
  bool get isMaster => true;

  /// Get the best quality variant
  HlsVariant? get bestQuality => variants.isNotEmpty ? variants.first : null;

  /// Get variant closest to target bandwidth
  HlsVariant? getVariantForBandwidth(int targetBandwidth) {
    if (variants.isEmpty) return null;

    return variants.reduce((a, b) {
      final diffA = (a.bandwidth - targetBandwidth).abs();
      final diffB = (b.bandwidth - targetBandwidth).abs();
      return diffA < diffB ? a : b;
    });
  }
}

/// Media playlist containing segments
class HlsMediaPlaylist extends HlsPlaylist {
  final List<HlsSegment> segments;
  final double targetDuration;
  final int mediaSequence;
  final bool isLive;
  final String? encryption;
  final String? encryptionKeyUrl;

  HlsMediaPlaylist({
    required super.baseUrl,
    required this.segments,
    required this.targetDuration,
    required this.mediaSequence,
    required this.isLive,
    this.encryption,
    this.encryptionKeyUrl,
  });

  @override
  bool get isMaster => false;

  /// Total duration of all segments
  double get totalDuration =>
      segments.fold(0.0, (sum, seg) => sum + seg.duration);

  /// Get all segment URLs
  List<String> get segmentUrls => segments.map((s) => s.url).toList();
}

/// Variant stream in a master playlist
class HlsVariant {
  final String url;
  final int bandwidth;
  final String? resolution;
  final String? codecs;

  HlsVariant({
    required this.url,
    required this.bandwidth,
    this.resolution,
    this.codecs,
  });

  @override
  String toString() =>
      'HlsVariant(bandwidth: $bandwidth, resolution: $resolution)';
}

/// Segment in a media playlist
class HlsSegment {
  final String url;
  final double duration;
  final int sequence;
  final bool isEncrypted;

  HlsSegment({
    required this.url,
    required this.duration,
    required this.sequence,
    required this.isEncrypted,
  });

  @override
  String toString() => 'HlsSegment(seq: $sequence, duration: ${duration}s)';
}
