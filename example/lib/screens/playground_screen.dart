import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import '../utils/formatters.dart';
import '../data/sample_videos.dart';

class PlaygroundScreen extends StatefulWidget {
  const PlaygroundScreen({super.key});

  @override
  State<PlaygroundScreen> createState() => _PlaygroundScreenState();
}

class _PlaygroundScreenState extends State<PlaygroundScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playground'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _BandwidthTestPanel(),
          SizedBox(height: 16),
          _CacheControlPanel(),
          SizedBox(height: 16),
          _HlsInspectorPanel(),
          SizedBox(height: 80),
        ],
      ),
    );
  }
}

class _BandwidthTestPanel extends StatefulWidget {
  const _BandwidthTestPanel();

  @override
  State<_BandwidthTestPanel> createState() => _BandwidthTestPanelState();
}

class _BandwidthTestPanelState extends State<_BandwidthTestPanel> {
  double _bandwidthLimit = 0; // 0 = unlimited
  bool _isTesting = false;
  String _testResult = '';
  Stopwatch? _stopwatch;

  Future<void> _runBandwidthTest() async {
    setState(() {
      _isTesting = true;
      _testResult = 'Starting download test...';
    });

    _stopwatch = Stopwatch()..start();

    try {
      // Use a sample video URL for testing
      final testUrl = sampleVideos.first.url;

      // Clear any existing cache for this URL
      await VideoStream.removeFromCache(testUrl);

      // Start precaching to trigger a download
      await VideoStream.precache([testUrl]);

      // Wait for download to complete by polling cache status
      CacheStatus status = CacheStatus.none;
      int pollCount = 0;
      while (status != CacheStatus.complete && pollCount < 120) {
        await Future.delayed(const Duration(milliseconds: 500));
        status = await VideoStream.getCacheStatus(testUrl);
        pollCount++;

        if (mounted) {
          setState(() {
            _testResult =
                'Downloading... (${formatDuration(Duration(seconds: pollCount ~/ 2))})';
          });
        }
      }

      _stopwatch!.stop();
      final elapsed = _stopwatch!.elapsed;

      if (status == CacheStatus.complete) {
        final metrics = VideoStream.getMetricsSnapshot();
        setState(() {
          _testResult =
              'Download complete!\n\nTime: ${formatDuration(elapsed)}\nAverage Speed: ${formatSpeed(metrics.recentAverageDownloadSpeed)}';
        });
      } else {
        setState(() {
          _testResult = 'Download timed out after ${formatDuration(elapsed)}';
        });
      }
    } catch (e) {
      setState(() {
        _testResult = 'Error: $e';
      });
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _buildPanel(
      title: 'Bandwidth Test',
      icon: Icons.speed,
      iconColor: Colors.purple,
      children: [
        Text(
          'Limit bandwidth (requires restart):',
          style: TextStyle(color: Colors.grey[400]),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _bandwidthLimit,
                min: 0,
                max: 10 * 1024 * 1024,
                divisions: 20,
                onChanged: (v) => setState(() => _bandwidthLimit = v),
              ),
            ),
            SizedBox(
              width: 80,
              child: Text(
                _bandwidthLimit == 0
                    ? 'Unlimited'
                    : formatSpeed(_bandwidthLimit.toInt()),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _isTesting ? null : _runBandwidthTest,
                icon: _isTesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_isTesting ? 'Testing...' : 'Run Download Test'),
              ),
            ),
          ],
        ),
        if (_testResult.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _testResult,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ],
    );
  }
}

class _CacheControlPanel extends StatefulWidget {
  const _CacheControlPanel();

  @override
  State<_CacheControlPanel> createState() => _CacheControlPanelState();
}

class _CacheControlPanelState extends State<_CacheControlPanel> {
  final _urlController = TextEditingController();
  String _statusResult = '';
  int _cacheSize = 0;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
    // Pre-fill with first sample video
    _urlController.text = sampleVideos.first.url;
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadCacheSize() async {
    final size = await VideoStream.getCacheSize();
    if (mounted) {
      setState(() => _cacheSize = size);
    }
  }

  Future<void> _checkStatus() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final status = await VideoStream.getCacheStatus(url);
      setState(() {
        _statusResult = 'Status: ${status.name}';
      });
    } catch (e) {
      setState(() {
        _statusResult = 'Error: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _precache() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      await VideoStream.precache([url]);
      setState(() {
        _statusResult = 'Precaching started for URL';
      });
      await _loadCacheSize();
    } catch (e) {
      setState(() {
        _statusResult = 'Error: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _removeFromCache() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      await VideoStream.removeFromCache(url);
      setState(() {
        _statusResult = 'Removed from cache';
      });
      await _loadCacheSize();
    } catch (e) {
      setState(() {
        _statusResult = 'Error: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Cache'),
        content: const Text('Are you sure you want to clear all cached data?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      await VideoStream.clearCache();
      setState(() {
        _statusResult = 'Cache cleared';
      });
      await _loadCacheSize();
    } catch (e) {
      setState(() {
        _statusResult = 'Error: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _buildPanel(
      title: 'Cache Control',
      icon: Icons.storage,
      iconColor: Colors.blue,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blue.withAlpha(26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total Cache Size'),
              Text(
                formatBytes(_cacheSize),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: 'Video URL',
            hintText: 'Enter video URL',
            border: OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 12),
          maxLines: 2,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _checkStatus,
              icon: const Icon(Icons.search, size: 16),
              label: const Text('Check'),
            ),
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _precache,
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Precache'),
            ),
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _removeFromCache,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Remove'),
            ),
            FilledButton.icon(
              onPressed: _isLoading ? null : _clearAll,
              icon: const Icon(Icons.delete_forever, size: 16),
              label: const Text('Clear All'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
              ),
            ),
          ],
        ),
        if (_statusResult.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Expanded(
                  child: Text(
                    _statusResult,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _HlsInspectorPanel extends StatefulWidget {
  const _HlsInspectorPanel();

  @override
  State<_HlsInspectorPanel> createState() => _HlsInspectorPanelState();
}

class _HlsInspectorPanelState extends State<_HlsInspectorPanel> {
  final _urlController = TextEditingController();
  String _result = '';
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Pre-fill with an HLS test stream
    _urlController.text =
        'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _parsePlaylist() async {
    if (kIsWeb) {
      setState(() {
        _result = 'HLS parsing not available on web platform (CORS)';
      });
      return;
    }

    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isLoading = true;
      _result = 'Fetching playlist...';
    });

    try {
      // Import HLS parser dynamically to avoid web issues
      final response = await _fetchHlsPlaylist(url);
      setState(() {
        _result = response;
      });
    } catch (e) {
      setState(() {
        _result = 'Error: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<String> _fetchHlsPlaylist(String url) async {
    // This will only work on mobile platforms
    // due to CORS restrictions on web
    try {
      final playlist = await _parseHlsUrl(url);
      return playlist;
    } catch (e) {
      return 'Failed to parse: $e';
    }
  }

  Future<String> _parseHlsUrl(String url) async {
    // Import and use the HLS parser from the library
    // Note: This is a simplified version - in production you'd import the actual parser
    final buffer = StringBuffer();

    try {
      // Fetch the playlist content
      final uri = Uri.parse(url);
      final client = await HttpClient().getUrl(uri);
      final response = await client.close();

      if (response.statusCode != 200) {
        return 'HTTP Error: ${response.statusCode}';
      }

      final content = await response.transform(const Utf8Decoder()).join();
      final lines = content.split('\n');

      buffer.writeln('=== HLS Playlist Analysis ===\n');

      // Check if master playlist
      final isMaster = lines.any((l) => l.contains('#EXT-X-STREAM-INF'));

      if (isMaster) {
        buffer.writeln('Type: Master Playlist\n');
        buffer.writeln('Variants:');

        for (int i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.startsWith('#EXT-X-STREAM-INF:')) {
            // Parse attributes
            final bandwidthMatch =
                RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
            final resolutionMatch =
                RegExp(r'RESOLUTION=([^,]+)').firstMatch(line);

            final bandwidth = bandwidthMatch?.group(1) ?? 'unknown';
            final resolution = resolutionMatch?.group(1) ?? 'unknown';

            // Get the URL from next line
            String variantUrl = '';
            for (int j = i + 1; j < lines.length; j++) {
              if (!lines[j].startsWith('#') && lines[j].trim().isNotEmpty) {
                variantUrl = lines[j].trim();
                break;
              }
            }

            buffer.writeln(
                '  - ${formatBytes(int.tryParse(bandwidth) ?? 0)}/s @ $resolution');
            if (variantUrl.isNotEmpty) {
              final shortUrl = variantUrl.length > 40
                  ? '${variantUrl.substring(0, 40)}...'
                  : variantUrl;
              buffer.writeln('    URL: $shortUrl');
            }
          }
        }
      } else {
        buffer.writeln('Type: Media Playlist\n');

        // Count segments
        int segmentCount = 0;
        double totalDuration = 0;
        bool isLive = true;

        for (final line in lines) {
          if (line.startsWith('#EXTINF:')) {
            segmentCount++;
            final durationStr = line.split(':').last.split(',').first;
            totalDuration += double.tryParse(durationStr) ?? 0;
          }
          if (line.contains('#EXT-X-ENDLIST')) {
            isLive = false;
          }
        }

        buffer.writeln('Segments: $segmentCount');
        buffer.writeln(
            'Total Duration: ${formatDuration(Duration(seconds: totalDuration.toInt()))}');
        buffer.writeln('Type: ${isLive ? "LIVE" : "VOD"}');

        // Check for encryption
        final isEncrypted = lines.any((l) =>
            l.contains('#EXT-X-KEY') && !l.contains('METHOD=NONE'));
        buffer.writeln('Encrypted: ${isEncrypted ? "Yes" : "No"}');
      }

      return buffer.toString();
    } catch (e) {
      return 'Parse error: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return _buildPanel(
      title: 'HLS Inspector',
      icon: Icons.live_tv,
      iconColor: Colors.orange,
      children: [
        if (kIsWeb)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withAlpha(26),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'HLS parsing unavailable on web due to CORS',
                    style: TextStyle(color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        if (!kIsWeb) ...[
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'HLS Playlist URL',
              hintText: 'Enter .m3u8 URL',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 12),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isLoading ? null : _parsePlaylist,
            icon: _isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.analytics),
            label: const Text('Parse Playlist'),
          ),
        ],
        if (_result.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _result,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

Widget _buildPanel({
  required String title,
  required IconData icon,
  required Color iconColor,
  required List<Widget> children,
}) {
  return Builder(
    builder: (context) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: iconColor.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const Divider(height: 24),
            ...children,
          ],
        ),
      ),
    ),
  );
}

