import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../../media/media_source_info.dart';

/// Band color for a marker type, mirroring the silo-android player:
/// cyan intro, light-green recap, amber credits, purple preview.
/// Unknown types return null (nothing drawn).
Color? markerBandColor(String type) {
  return switch (type) {
    'intro' => const Color(0xFF00FFFF),
    'recap' => const Color(0xFF8BC34A),
    'credits' => const Color(0xFFFFB74D),
    'preview' => const Color(0xFFBA68C8),
    _ => null,
  };
}

/// Paints tinted bands for intro/recap/credits/preview markers on the video
/// timeline slider. Drawn ABOVE the played fill so marker colors stay visible
/// after their section has played. Interior edges are square; a band keeps a
/// rounded cap only where it meets the bar's absolute start or end.
class MarkerBandPainter extends CustomPainter {
  final List<MediaMarker> markers;
  final Duration duration;

  static const _trackHeight = 8.0;

  MarkerBandPainter({required this.markers, required this.duration});

  @override
  void paint(Canvas canvas, Size size) {
    final durationMs = duration.inMilliseconds.toDouble();
    if (durationMs <= 0) return;

    const alpha = 0.34;
    final y = (size.height - _trackHeight) / 2;

    for (final marker in markers) {
      final color = markerBandColor(marker.type);
      if (color == null) continue;
      final left = (marker.startTimeOffset / durationMs).clamp(0.0, 1.0) * size.width;
      final right = (marker.endTimeOffset / durationMs).clamp(0.0, 1.0) * size.width;
      if (right - left < 1) continue;
      final cap = Radius.circular(_trackHeight / 2);
      final leftCap = left <= 0.5 ? cap : Radius.zero;
      final rightCap = right >= size.width - 0.5 ? cap : Radius.zero;
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          left,
          y,
          right,
          y + _trackHeight,
          topLeft: leftCap,
          bottomLeft: leftCap,
          topRight: rightCap,
          bottomRight: rightCap,
        ),
        Paint()..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(MarkerBandPainter oldDelegate) {
    return oldDelegate.duration != duration || !listEquals(oldDelegate.markers, markers);
  }
}

/// Paints vertical chapter tick marks on the video timeline slider. Drawn
/// ABOVE the played fill so chapters stay readable while seeking past them
/// (silo-android parity). The chapter-0 tick is skipped so it doesn't sit
/// under the slider's endcap.
class ChapterTickPainter extends CustomPainter {
  final List<MediaChapter> chapters;
  final Duration duration;

  static const _trackHeight = 8.0;
  static const _tickGrow = 8.0;

  ChapterTickPainter({required this.chapters, required this.duration});

  @override
  void paint(Canvas canvas, Size size) {
    final durationMs = duration.inMilliseconds.toDouble();
    if (durationMs <= 0) return;

    const width = 2.0;
    final height = _trackHeight + _tickGrow;
    final y = (size.height - height) / 2;
    final tickPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..style = PaintingStyle.fill;

    for (final chapter in chapters) {
      final ms = chapter.startTimeOffset ?? 0;
      if (ms <= 0) continue;
      final fraction = (ms / durationMs).clamp(0.0, 1.0);
      if (fraction <= 0.001 || fraction >= 0.999) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(fraction * size.width - width / 2, y, width, height),
          Radius.circular(width / 2),
        ),
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(ChapterTickPainter oldDelegate) {
    return oldDelegate.duration != duration || !listEquals(oldDelegate.chapters, chapters);
  }
}
