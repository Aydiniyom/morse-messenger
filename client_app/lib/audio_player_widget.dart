import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

class AudioPlayerWidget extends StatefulWidget {
  final File file;

  /// Called when the user wants to save this attachment to their device.
  /// Omit to hide the download button (e.g. while it's still transferring).
  final VoidCallback? onDownload;

  const AudioPlayerWidget({super.key, required this.file, this.onDownload});

  @override
  State<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<AudioPlayerWidget> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  bool _isLoaded = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();

    // Without this, some platforms release the underlying player resource
    // as soon as playback completes, so pressing play again after a track
    // finishes silently does nothing.
    _player.setReleaseMode(ReleaseMode.stop);

    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
    // The state stream above doesn't reliably report a distinct
    // "completed" state on every platform, which used to leave the slider
    // stuck at the end and the icon stuck on pause after a track finished
    // - the only way to "resume" was to drag the slider back manually.
    // Resetting explicitly on completion fixes that.
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _player.pause();
      return;
    }

    // Bug fix: previously this always called play(DeviceFileSource(...)),
    // which loads the source fresh every time - so pressing pause then
    // play again restarted the track from 0:00 instead of resuming from
    // where it was paused. Only load a fresh source the first time (or
    // after the track has finished/reset); otherwise just resume.
    if (!_isLoaded || _position == Duration.zero) {
      await _player.play(DeviceFileSource(widget.file.path));
      _isLoaded = true;
    } else {
      await _player.resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final double maxMs = _duration.inMilliseconds.toDouble() > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;

    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
            color: Theme.of(context).colorScheme.primary,
            onPressed: _togglePlayback,
          ),
          Expanded(
            child: Slider(
              activeColor: Theme.of(context).colorScheme.primary,
              inactiveColor: Colors.white12,
              value: _position.inMilliseconds.toDouble().clamp(0.0, maxMs),
              max: maxMs,
              onChanged: (val) {
                _player.seek(Duration(milliseconds: val.toInt()));
              },
            ),
          ),
          if (widget.onDownload != null)
            IconButton(
              icon: const Icon(Icons.download_rounded, size: 18, color: Colors.white60),
              onPressed: widget.onDownload,
            ),
        ],
      ),
    );
  }
}
