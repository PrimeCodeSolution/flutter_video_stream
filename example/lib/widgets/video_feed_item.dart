import 'package:flutter/material.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';
import 'package:video_player/video_player.dart';
import '../data/sample_videos.dart';
import '../utils/formatters.dart';

class VideoFeedItem extends StatefulWidget {
  final VideoItem video;
  final bool isActive;
  final String cacheStatus;
  final int index;

  const VideoFeedItem({
    super.key,
    required this.video,
    required this.isActive,
    required this.cacheStatus,
    required this.index,
  });

  @override
  State<VideoFeedItem> createState() => _VideoFeedItemState();
}

class _VideoFeedItemState extends State<VideoFeedItem> {
  VideoPlayerController? _controller;
  bool _isPaused = false;
  bool _showPauseIcon = false;
  bool _isBuffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Video Player
        GestureDetector(
          onTap: _togglePlayPause,
          child: VideoStreamPlayer(
            url: widget.video.url,
            autoPlay: widget.isActive,
            looping: true,
            muted: false,
            fit: BoxFit.cover,
            placeholder: _buildPlaceholder(),
            priorityIndex: widget.index,
            onInitialized: (controller) {
              _controller = controller;
              _updateDuration();
              controller.addListener(_onControllerUpdate);
            },
            onBuffering: (isBuffering) {
              if (mounted) {
                setState(() => _isBuffering = isBuffering);
              }
            },
            onProgress: (position, duration) {
              if (mounted) {
                setState(() {
                  _position = position;
                  _duration = duration;
                });
              }
            },
          ),
        ),

        // Gradient overlay for text readability
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 200,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
          ),
        ),

        // Bottom info
        Positioned(left: 10, right: 80, bottom: 50, child: _buildVideoInfo()),

        // Progress bar at the bottom
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _buildProgressBar(),
        ),

        // Top badges row
        Positioned(
          top: 10,
          right: 10,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTypeBadge(),
              const SizedBox(width: 8),
              _buildCacheIndicator(),
            ],
          ),
        ),

        // Buffering indicator
        if (_isBuffering)
          const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),

        // Play/Pause Indicator (shows briefly when toggled)
        if (_showPauseIcon && !_isBuffering)
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(40),
              ),
              child: Icon(
                _isPaused ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 40,
              ),
            ),
          ),
      ],
    );
  }

  void _onControllerUpdate() {
    if (_controller != null && mounted) {
      final position = _controller!.value.position;
      final duration = _controller!.value.duration;
      if (position != _position || duration != _duration) {
        setState(() {
          _position = position;
          _duration = duration;
        });
      }
    }
  }

  void _updateDuration() {
    if (_controller != null) {
      setState(() {
        _duration = _controller!.value.duration;
      });
    }
  }

  void _togglePlayPause() {
    if (_controller == null) return;

    setState(() {
      _isPaused = !_isPaused;
      _showPauseIcon = true;
    });

    if (_isPaused) {
      _controller!.pause();
    } else {
      _controller!.play();
    }

    // Hide the icon after a short delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() => _showPauseIcon = false);
      }
    });
  }

  Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey[900],
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  Widget _buildVideoInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.video.username,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.video.description,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.favorite, color: Colors.white70, size: 14),
            const SizedBox(width: 4),
            Text(
              formatCompactNumber(widget.video.likes),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(width: 12),
            Icon(Icons.chat_bubble_outline, color: Colors.white70, size: 14),
            const SizedBox(width: 4),
            Text(
              formatCompactNumber(widget.video.comments),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProgressBar() {
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Time display
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                formatDuration(_position),
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
              Text(
                formatDuration(_duration),
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // Progress bar
        SizedBox(
          height: 3,
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.pink),
          ),
        ),
      ],
    );
  }

  Widget _buildTypeBadge() {
    final isHls = widget.video.isHls;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isHls ? Colors.purple.withAlpha(204) : Colors.blue.withAlpha(204),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isHls ? Icons.live_tv : Icons.video_file,
            color: Colors.white,
            size: 12,
          ),
          const SizedBox(width: 4),
          Text(
            isHls ? 'HLS' : 'MP4',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCacheIndicator() {
    Color color;
    String text;

    switch (widget.cacheStatus) {
      case 'complete':
        color = Colors.green;
        text = 'CACHED';
        break;
      case 'partial':
        color = Colors.orange;
        text = 'PARTIAL';
        break;
      default:
        color = Colors.red;
        text = 'NOT CACHED';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
