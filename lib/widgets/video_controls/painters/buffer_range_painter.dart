import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../../mpv/models.dart';

/// Custom painter that draws the background track and buffered range bars on
/// the video timeline slider. Chapter boundaries render separately via
/// [ChapterTickPainter], above the played fill.
class BufferRangePainter extends CustomPainter {
  final List<BufferRange> ranges;
  final Duration duration;

  BufferRangePainter({required this.ranges, required this.duration});

  @override
  void paint(Canvas canvas, Size size) {
    const trackHeight = 8.0;
    final radius = trackHeight / 2;
    final y = (size.height - trackHeight) / 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, y, size.width, trackHeight), Radius.circular(radius)),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill,
    );

    final durationMs = duration.inMilliseconds.toDouble();
    if (durationMs <= 0) return;

    final bufPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;

    for (final range in ranges) {
      final bufLeft = (range.start.inMilliseconds / durationMs).clamp(0.0, 1.0) * size.width;
      final bufRight = (range.end.inMilliseconds / durationMs).clamp(0.0, 1.0) * size.width;
      if (bufRight <= bufLeft) continue;
      // Buffer chunks: square interior edges — rounding mid-track reads as a
      // stray capsule next to the square marker band edges and chapter ticks.
      canvas.drawRect(Rect.fromLTWH(bufLeft, y, bufRight - bufLeft, trackHeight), bufPaint);
    }
  }

  @override
  bool shouldRepaint(BufferRangePainter oldDelegate) {
    return oldDelegate.duration != duration || !listEquals(oldDelegate.ranges, ranges);
  }
}
