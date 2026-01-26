/// Video type enum
enum VideoType {
  mp4,
  hls,
}

class VideoItem {
  final String url;
  final String username;
  final String description;
  final int likes;
  final int comments;
  final VideoType type;

  const VideoItem({
    required this.url,
    required this.username,
    required this.description,
    required this.likes,
    required this.comments,
    this.type = VideoType.mp4,
  });

  /// Check if this is an HLS stream
  bool get isHls => type == VideoType.hls || url.endsWith('.m3u8');
}

const List<VideoItem> sampleVideos = [
  // HLS streams first for testing
  VideoItem(
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    username: '@hls_demo',
    description: 'Big Buck Bunny - HLS Stream Test',
    likes: 99000,
    comments: 5400,
    type: VideoType.hls,
  ),
  VideoItem(
    url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8',
    username: '@apple_test',
    description: 'Apple BipBop - Multi-bitrate HLS',
    likes: 78000,
    comments: 3200,
    type: VideoType.hls,
  ),
  VideoItem(
    url: 'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
    username: '@unified_stream',
    description: 'Tears of Steel - Unified Streaming HLS',
    likes: 56000,
    comments: 2800,
    type: VideoType.hls,
  ),
  // MP4 videos
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    username: '@animation_studio',
    description: 'Big Buck Bunny - A classic open movie project',
    likes: 45000,
    comments: 1200,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
    username: '@dream_works',
    description: 'Elephants Dream - The first open movie',
    likes: 23000,
    comments: 890,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
    username: '@tech_guy',
    description: 'Testing Chromecast with bigger blazes',
    likes: 5600,
    comments: 230,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
    username: '@travel_daily',
    description: 'Escaping the ordinary',
    likes: 8900,
    comments: 450,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4',
    username: '@fun_times',
    description: 'More fun than ever!',
    likes: 12000,
    comments: 670,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4',
    username: '@gear_head',
    description: 'Joyride time',
    likes: 15600,
    comments: 890,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4',
    username: '@robot_life',
    description: 'System meltdown imminent',
    likes: 3400,
    comments: 120,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
    username: '@fantasy_world',
    description: 'Sintel - A fantasy adventure',
    likes: 89000,
    comments: 4500,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackOnStreetAndDirt.mp4',
    username: '@auto_review',
    description: 'Subaru Outback: Street and Dirt test',
    likes: 7800,
    comments: 340,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
    username: '@scifi_channel',
    description: 'Tears of Steel - Sci-fi match tracking',
    likes: 67000,
    comments: 3200,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4',
    username: '@supercars',
    description: 'We are going on Bullrun!',
    likes: 45000,
    comments: 2100,
    type: VideoType.mp4,
  ),
  VideoItem(
    url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WhatCarCanYouGetForAGrand.mp4',
    username: '@budget_cars',
    description: 'What car can you get for a grand?',
    likes: 9800,
    comments: 560,
    type: VideoType.mp4,
  ),
];
