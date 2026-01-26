import 'package:flutter/material.dart';
import 'package:flutter_video_stream/flutter_video_stream.dart';

class GlobalControls extends StatefulWidget {
  const GlobalControls({super.key});

  @override
  State<GlobalControls> createState() => _GlobalControlsState();
}

class _GlobalControlsState extends State<GlobalControls> {
  @override
  void initState() {
    super.initState();
    // Listen to controller changes
    VideoStream.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    VideoStream.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _togglePlayPause() {
    VideoStream.controller.togglePlayPause();
  }

  void _toggleMute() {
    VideoStream.controller.toggleMute();
  }

  @override
  Widget build(BuildContext context) {
    final controller = VideoStream.controller;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildControlButton(
            icon: controller.isPaused ? Icons.play_arrow : Icons.pause,
            onTap: _togglePlayPause,
            tooltip: controller.isPaused ? 'Play' : 'Pause',
          ),
          const SizedBox(width: 8),
          _buildControlButton(
            icon: controller.isMuted ? Icons.volume_off : Icons.volume_up,
            onTap: _toggleMute,
            tooltip: controller.isMuted ? 'Unmute' : 'Mute',
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
