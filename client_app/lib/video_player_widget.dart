import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoPlayerWidget extends StatefulWidget {
  final File file;
  const VideoPlayerWidget({super.key, required this.file});

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late final Player _player;
  late final VideoController _controller;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);

    // Listen for initialization/stream changes to set aspect ratio and reveal UI
    _player.stream.width.listen((value) {
      if (value! > 0 && !_isInitialized) {
        setState(() {
          _isInitialized = true;
        });
      }
    });

    // Open the file quietly without auto-playing immediately
    _player.open(Media(widget.file.path), play: false);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Container(
        width: 240,
        height: 160,
        color: Colors.black38,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    // Determine aspect ratio from video dimensions (fallback to 16/9 if unavailable)
    final width = _player.state.width;
    final height = _player.state.height;
    final aspectRatio = (width! > 0 && height! > 0) ? (width / height) : (16 / 9);

    return Container(
      constraints: const BoxConstraints(maxWidth: 240, maxHeight: 180),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Video(controller: _controller),
              _VideoControlsOverlay(player: _player),
              _VideoProgressBar(player: _player),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoControlsOverlay extends StatefulWidget {
  final Player player;
  const _VideoControlsOverlay({required this.player});

  @override
  State<_VideoControlsOverlay> createState() => _VideoControlsOverlayState();
}

class _VideoControlsOverlayState extends State<_VideoControlsOverlay> {
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.player.state.playing;
    widget.player.stream.playing.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      child: GestureDetector(
        onTap: () {
          widget.player.playOrPause();
        },
        child: Container(
          color: Colors.black26,
          child: Center(
            child: Icon(
              _isPlaying
                  ? Icons.pause_circle_filled_rounded
                  : Icons.play_circle_filled_rounded,
              color: Colors.white,
              size: 44.0,
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoProgressBar extends StatefulWidget {
  final Player player;
  const _VideoProgressBar({required this.player});

  @override
  State<_VideoProgressBar> createState() => _VideoProgressBarState();
}

class _VideoProgressBarState extends State<_VideoProgressBar> {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    widget.player.stream.position.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    widget.player.stream.duration.listen((dur) {
      if (mounted) setState(() => _duration = dur);
    });
  }

  @override
  Widget build(BuildContext context) {
    final double progress = (_duration.inMilliseconds > 0)
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: GestureDetector(
        onHorizontalDragUpdate: (details) {
          final RenderBox box = context.findRenderObject() as RenderBox;
          final double relativePos = details.localPosition.dx / box.size.width;
          final double targetMs = _duration.inMilliseconds * relativePos;
          widget.player.seek(Duration(milliseconds: targetMs.toInt().clamp(0, _duration.inMilliseconds)));
        },
        child: Container(
          height: 6,
          color: Colors.white10,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: progress,
            child: Container(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}