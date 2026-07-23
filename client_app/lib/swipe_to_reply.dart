import 'package:flutter/material.dart';

/// Wraps a chat message bubble with swipe-to-reply: dragging the bubble
/// horizontally reveals a reply icon on the side being dragged away from,
/// and releasing past a distance threshold fires [onReply]. The bubble
/// always snaps back to its resting offset afterward - this is a gesture
/// shortcut for starting a reply, not a persistent layout change, exactly
/// like the equivalent gesture in Telegram/WhatsApp.
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;

  /// Set false to disable the gesture entirely (e.g. for a chat that
  /// doesn't support replies), while still rendering [child] normally.
  final bool enabled;

  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  /// How far the bubble is allowed to visually slide.
  static const double _maxDrag = 64.0;

  /// How far it has to be dragged before releasing counts as "reply".
  static const double _triggerDrag = 48.0;

  double _dragExtent = 0.0;
  bool _triggered = false;

  void _handleDragUpdate(DragUpdateDetails details) {
    setState(() {
      // Left-drag only: accumulate negative offset, clamped so the bubble
      // can't be dragged off past _maxDrag no matter how far the finger
      // travels.
      _dragExtent = (_dragExtent + details.delta.dx).clamp(-_maxDrag, 0.0);
      _triggered = _dragExtent <= -_triggerDrag;
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    final bool shouldReply = _triggered;
    setState(() {
      _dragExtent = 0.0;
      _triggered = false;
    });
    if (shouldReply) {
      widget.onReply();
    }
  }

  void _handleDragCancel() {
    setState(() {
      _dragExtent = 0.0;
      _triggered = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final theme = Theme.of(context);
    final double iconProgress = (-_dragExtent / _triggerDrag).clamp(0.0, 1.0);

    return GestureDetector(
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      onHorizontalDragCancel: _handleDragCancel,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          if (_dragExtent < 0)
            Positioned(
              right: 6,
              child: Opacity(
                opacity: iconProgress,
                child: Icon(
                  Icons.reply_rounded,
                  color: _triggered ? theme.colorScheme.primary : Colors.white38,
                  size: 20,
                ),
              ),
            ),
          AnimatedContainer(
            duration: _dragExtent == 0.0
                ? const Duration(milliseconds: 180)
                : Duration.zero,
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dragExtent, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
