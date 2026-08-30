import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/widgets/video_controls/painters/buffer_range_painter.dart';
import 'package:plezy/widgets/video_controls/painters/media_marker_painter.dart';

Future<Uint8List> _rasterize(CustomPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(ui.Canvas(recorder), size);
  final image = await recorder.endRecording().toImage(size.width.round(), size.height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

int _alphaAt(Uint8List pixels, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return pixels[offset + 3];
}

void main() {
  group(MarkerBandPainter, () {
    const duration = Duration(minutes: 10);

    test('paints tinted bands for known marker types only', () async {
      final painter = MarkerBandPainter(
        markers: [
          MediaMarker(id: 1, type: 'intro', startTimeOffset: 0, endTimeOffset: 60000),
          MediaMarker(id: 2, type: 'credits', startTimeOffset: 540000, endTimeOffset: 600000),
          MediaMarker(id: 3, type: 'recap', startTimeOffset: 300000, endTimeOffset: 360000),
        ],
        duration: duration,
      );
      final pixels = await _rasterize(painter, const Size(600, 8));

      // Intro band [0, 60s] → x [0, 60]: alpha present, cyan (blue >= red).
      expect(_alphaAt(pixels, 600, 30, 4), greaterThan(0));
      final introOffset = (4 * 600 + 30) * 4;
      expect(pixels[introOffset], lessThanOrEqualTo(pixels[introOffset + 2]));

      // Recap band [300s, 360s] → x [300, 360]: green tint present.
      expect(_alphaAt(pixels, 600, 330, 4), greaterThan(0));

      // Credits band [540s, 600s] → x [540, 600]: warm (red > blue).
      expect(_alphaAt(pixels, 600, 570, 4), greaterThan(0));
      final creditsOffset = (4 * 600 + 570) * 4;
      expect(pixels[creditsOffset], greaterThan(pixels[creditsOffset + 2]));
    });

    test('rounds band caps only at the bar extremes', () async {
      final painter = MarkerBandPainter(
        markers: [
          MediaMarker(id: 1, type: 'intro', startTimeOffset: 0, endTimeOffset: 60000),
          MediaMarker(id: 2, type: 'credits', startTimeOffset: 540000, endTimeOffset: 600000),
          MediaMarker(id: 3, type: 'recap', startTimeOffset: 300000, endTimeOffset: 360000),
        ],
        duration: duration,
      );
      final pixels = await _rasterize(painter, const Size(600, 8));

      // Intro starts at the bar start: rounded left cap (corner pixel empty),
      // square right edge (top row filled).
      expect(_alphaAt(pixels, 600, 0, 0), 0);
      expect(_alphaAt(pixels, 600, 1, 4), greaterThan(0));
      expect(_alphaAt(pixels, 600, 59, 0), greaterThan(0));

      // Mid-track recap band: both edges square (top row filled at edges).
      expect(_alphaAt(pixels, 600, 300, 0), greaterThan(0));
      expect(_alphaAt(pixels, 600, 359, 0), greaterThan(0));

      // Credits end at the bar end: square left edge, rounded right cap.
      expect(_alphaAt(pixels, 600, 540, 0), greaterThan(0));
      expect(_alphaAt(pixels, 600, 599, 0), 0);
    });

    test('unknown marker types draw nothing', () async {
      final painter = MarkerBandPainter(
        markers: [MediaMarker(id: 1, type: 'commercial', startTimeOffset: 300000, endTimeOffset: 360000)],
        duration: duration,
      );
      final pixels = await _rasterize(painter, const Size(600, 8));
      expect(pixels.every((p) => p == 0), isTrue);
    });

    test('zero-length markers draw nothing', () async {
      final painter = MarkerBandPainter(
        markers: [MediaMarker(id: 1, type: 'intro', startTimeOffset: 60000, endTimeOffset: 60000)],
        duration: duration,
      );
      final pixels = await _rasterize(painter, const Size(600, 8));
      expect(pixels.every((p) => p == 0), isTrue);
    });
  });

  group(ChapterTickPainter, () {
    const duration = Duration(minutes: 10);
    final chapters = [
      MediaChapter(id: 1, startTimeOffset: 0), // start tick: skipped
      MediaChapter(id: 2, startTimeOffset: 300000), // mid
      MediaChapter(id: 3, startTimeOffset: 599000), // near end: drawn
      MediaChapter(id: 4, startTimeOffset: 600000), // at end: skipped
    ];

    test('draws ticks at chapter boundaries, skipping the ends', () async {
      final painter = ChapterTickPainter(chapters: chapters, duration: duration);
      final pixels = await _rasterize(painter, const Size(600, 16));

      // Mid chapter at 50% → tick centered on x=300 (2 px wide: 299–301).
      expect(_alphaAt(pixels, 600, 300, 8), greaterThan(0));
      expect(_alphaAt(pixels, 600, 297, 8), 0);

      // Chapter at 599s → x=599 has a tick; x=0 and the end-cap tick do not.
      expect(_alphaAt(pixels, 600, 599, 8), greaterThan(0));
      expect(_alphaAt(pixels, 600, 0, 8), 0);
    });

    test('ticks span the track height plus grow', () async {
      final painter = ChapterTickPainter(chapters: chapters, duration: duration);
      final pixels = await _rasterize(painter, const Size(600, 16));

      // Tick height 16 on a 16 px canvas: covers every row at x=300.
      for (final y in [0, 4, 8, 12, 15]) {
        expect(_alphaAt(pixels, 600, 300, y), greaterThan(0), reason: 'row $y');
      }
    });

    test('zero duration paints nothing', () async {
      final painter = ChapterTickPainter(chapters: chapters, duration: Duration.zero);
      final pixels = await _rasterize(painter, const Size(600, 16));
      expect(pixels.every((p) => p == 0), isTrue);
    });
  });
  group(BufferRangePainter, () {
    const duration = Duration(minutes: 10);

    test('background track rounds only its end caps; buffer edges stay square', () async {
      final painter = BufferRangePainter(
        ranges: [const BufferRange(start: Duration(seconds: 200), end: Duration(seconds: 300))],
        duration: duration,
      );
      final pixels = await _rasterize(painter, const Size(600, 8));

      // Background stadium: corners empty, body filled.
      expect(_alphaAt(pixels, 600, 0, 0), 0);
      expect(_alphaAt(pixels, 600, 300, 4), greaterThan(0));

      // Mid-track buffer chunk [200s, 300s]: square edges — the top row is
      // fully covered at the edges (a pill-rounded edge would half-cover:
      // bg 0.3 + square buffer 0.5 → alpha ≈166; rounded would be ≈121).
      expect(_alphaAt(pixels, 600, 200, 0), greaterThan(150));
      expect(_alphaAt(pixels, 600, 200, 4), greaterThan(150));
      expect(_alphaAt(pixels, 600, 299, 0), greaterThan(150));
    });
  });
}
