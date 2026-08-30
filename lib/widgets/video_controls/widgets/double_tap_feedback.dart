import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../utils/formatters.dart';
import '../../../utils/platform_detector.dart';

/// Label for the skip feedback. Plain `Ns` stays readable up to a minute; beyond
/// that (reachable by held D-pad seeking, which accelerates) a raw second
/// count is unreadable, so fall back to the M:SS timestamp form.
@visibleForTesting
String formatSkipFeedbackLabel(int seconds) {
  if (seconds < 60) return '$seconds${t.settings.secondsShort}';
  return formatDurationTimestamp(Duration(seconds: seconds));
}

/// Port of silo-android's TvSeekVisualizer (ff-rw-ui, 8c391998): a tall, thin
/// chevron on the side the seek travels toward, sliding inward-to-rest on
/// arrival and pulsing once per press, with the burst's accumulated total
/// beside it.
///
/// Legibility comes from dark keylines behind every glyph rather than shadows —
/// the outline is centred on the glyph edge, so half lands outside and half is
/// covered by the fill, reading as a caption outline instead of a drop shadow.
///
/// Deliberately unbacked — no scrim, no puck. Anything large enough to read as a
/// surface also covers picture and subtitles, which is the complaint this
/// feedback exists to answer.
///
/// The amount is what the viewer reads, so it never moves; only the chevron
/// slides and pulses.
class DoubleTapFeedback extends StatefulWidget {
  final bool isForward;
  final ValueListenable<int> seconds;

  /// Bumps once per skip press. Same-direction presses stack the total without
  /// rebuilding this widget, so the nonce is what lets each press replay the
  /// pulse and extend the glide.
  final ValueListenable<int> nonce;

  /// The press's own direction, written before [nonce] fires. The widget's
  /// [isForward] is stale until the parent rebuilds, so this is what tells a
  /// flip (entrance replay, no pop) from a same-side repeat (pop).
  final ValueListenable<bool> pressForward;

  final bool animate;

  const DoubleTapFeedback({
    super.key,
    required this.isForward,
    required this.seconds,
    required this.nonce,
    required this.pressForward,
    required this.animate,
  });

  /// Inset from the anchored edge. TVs overscan roughly 5% of each edge, so
  /// derive it from the viewport rather than assuming 1080p logical geometry — a
  /// TV reporting 960dp at 2x would otherwise get double the intended inset.
  /// Clamped so the readout never sits tighter than the touch layout, never
  /// drifts toward centre on an ultra-wide viewport, and always leaves itself
  /// room on a narrow one.
  static double _horizontalInset(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final overscan = PlatformDetector.isTV() ? (width * 0.05).clamp(60.0, 160.0) : 60.0;
    return overscan.clamp(0.0, math.max(0.0, (width - _minReadoutWidth) / 2));
  }

  /// Chevron plus a few characters of label at the largest step.
  static const double _minReadoutWidth = 200;

  /// Type scale. A TV is read from across the room, so it needs a bigger step
  /// than a handset at arm's length even though the two report a similar
  /// logical width — 960dp at 2x versus roughly 900dp in landscape.
  static double _labelSize(BuildContext context) => PlatformDetector.isTV() ? 34 : 26;

  /// Chevron geometry, from the silo original: 28 dp wide with a 6 dp stroke,
  /// a quarter of the screen tall on TV so it reads from across the room.
  /// Clamped on handsets, where a quarter of a portrait frame is enormous.
  static const double _chevronWidth = 28;
  static const double _chevronStrokeWidth = 6;
  static double _chevronHeight(BuildContext context, double screenH) =>
      PlatformDetector.isTV() ? screenH * 0.25 : math.min(screenH * 0.25, 140);

  /// The chevron slides from this far inward out to its laid-out resting spot.
  /// Travel runs inward → 0 and never past 0, so it can't walk off the edge.
  /// Long enough that the glide reads as travel at TV viewing distance — a
  /// 40 dp drift with a decelerate curve reads as a flick, not a slide.
  static const double _slideDistance = 96;

  /// Per-press accent. Starts and ends at rest, so re-firing mid-flight has no
  /// discontinuity to cover and every press in a burst can safely replay it.
  static const double _pulseScale = 0.18;

  /// Entrance fade: the controller runs 1000 ms, but the visible fade occupies
  /// only its last 700 ms — the chevron stays transparent for the first 300 ms
  /// so the slide is under way before the glyphs arrive.
  static const Duration _fadeInDuration = Duration(milliseconds: 1000);
  static const Curve _fadeInCurveShape = Interval(0.3, 1.0, curve: Curves.easeOut);
  static const Duration _slideDuration = Duration(milliseconds: 3600);
  static const Duration _pulseDuration = Duration(milliseconds: 1200);

  /// Fixed minimum so the digit count changing (e.g. "5s" -> "15s") doesn't
  /// reflow the row and shift the number; it just grows away from the chevron.
  static const double _labelMinWidth = 72;

  /// Stroked text draws past the glyph advance the framework measures, so the
  /// outermost keyline needs slack or it gets sliced.
  static const double _labelOutlineBleed = 4;
  static const double _labelOutlineWidth = 3;

  /// Dark keyline behind each glyph, centred on its edge and NOT offset — half
  /// the width lands outside the glyph, half is covered by the fill on top, so
  /// it reads as a caption-style outline rather than a drop shadow.
  static const double _outlineStrokeScale = 1.5;
  static Color get _outlineColor => Colors.black.withValues(alpha: 0.25);

  @override
  State<DoubleTapFeedback> createState() => _DoubleTapFeedbackState();
}

class _DoubleTapFeedbackState extends State<DoubleTapFeedback> with TickerProviderStateMixin {
  /// 0 = inward origin, 1 = rest. Fresh arrivals snap to 0 and glide in; a
  /// repeat press keeps gliding from wherever the chevron currently sits.
  late final AnimationController _slide;
  late final Animation<double> _slideCurve;

  /// 0 → 1 per press; the pulse is (1 - value), so scale starts at +18% and
  /// settles back to rest.
  late final AnimationController _pulse;
  late final Animation<double> _pulseCurve;

  /// Entrance fade. The parent's AnimatedOpacity only animates when this
  /// widget survives a re-show — on first insertion it would render at full
  /// opacity instantly, which reads as the chevron just appearing.
  late final AnimationController _fadeIn;
  late final Animation<double> _fadeInCurve;

  bool _shownForward = false;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(vsync: this, duration: DoubleTapFeedback._slideDuration);
    _slideCurve = CurvedAnimation(parent: _slide, curve: Curves.easeInOutSine);
    _pulse = AnimationController(vsync: this, duration: DoubleTapFeedback._pulseDuration);
    // Rest = fully settled (scale 1.0). A fresh arrival must not inherit the
    // popped size just because no pulse has run yet.
    _pulse.value = 1.0;
    _pulseCurve = CurvedAnimation(parent: _pulse, curve: Curves.linear);
    _fadeIn = AnimationController(vsync: this, duration: DoubleTapFeedback._fadeInDuration);
    _fadeInCurve = CurvedAnimation(parent: _fadeIn, curve: DoubleTapFeedback._fadeInCurveShape);
    _shownForward = widget.isForward;
    widget.nonce.addListener(_onPress);
    if (widget.animate) _onArrival(fresh: true);
  }

  @override
  void didUpdateWidget(DoubleTapFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The nonce listener runs before the parent rebuilds, so a direction flip
    // still carries the old isForward there and cannot see the flip. The
    // rebuild is where the flip becomes knowable: replay that side's whole
    // arrival — slide from its own inward origin plus the entrance fade, with
    // no pop. A same-side re-raise mid-fade is a repeat press: _onPress
    // already extended the glide and popped; the parent raising opacity
    // brings the readout back.
    if (oldWidget.isForward != widget.isForward) {
      _onArrival(fresh: true);
    }
  }

  @override
  void dispose() {
    widget.nonce.removeListener(_onPress);
    _slide.dispose();
    _pulse.dispose();
    _fadeIn.dispose();
    super.dispose();
  }

  /// A fresh arrival plays that side's full entrance: fade in from nothing,
  /// slide from its inward origin. A repeat press on the same side instead
  /// extends the current glide and pops the pulse — no fade replay.
  void _onArrival({required bool fresh}) {
    if (fresh || _shownForward != widget.isForward) {
      _shownForward = widget.isForward;
      _slide.value = 0;
      _fadeIn.forward(from: 0);
    }
    _slide.forward();
  }

  void _onPress() {
    if (!mounted || !widget.animate) return;
    // The widget's isForward is stale until the parent rebuilds; the press's
    // own direction arrives through [DoubleTapFeedback.pressForward] before
    // the nonce fires. A flip resolves at didUpdateWidget as a full entrance
    // (fade + slide, no pop); only a same-side press on a showing readout pops.
    if (widget.pressForward.value != _shownForward) return;
    _slide.forward();
    _pulse.forward(from: 0);
  }

  Widget _buildChevron(BuildContext context, double chevronHeight) {
    return AnimatedBuilder(
      animation: Listenable.merge([_slideCurve, _pulseCurve]),
      builder: (context, child) {
        final inward = (widget.isForward ? -1.0 : 1.0) * DoubleTapFeedback._slideDistance * (1 - _slideCurve.value);
        final scale = 1 + (1 - _pulseCurve.value) * DoubleTapFeedback._pulseScale;
        return Transform.translate(
          key: const ValueKey('seekChevronSlide'),
          offset: Offset(inward, 0),
          child: Transform.scale(key: const ValueKey('seekChevronPulse'), scale: scale, child: child),
        );
      },
      child: CustomPaint(
        size: Size(DoubleTapFeedback._chevronWidth, chevronHeight),
        painter: _SeekChevronPainter(forward: widget.isForward),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isForward = widget.isForward;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final amountStyle = TextStyle(
      color: Colors.white,
      fontSize: DoubleTapFeedback._labelSize(context),
      fontWeight: FontWeight.w900,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final chevronHeight = DoubleTapFeedback._chevronHeight(context, constraints.maxHeight);
        return Align(
          alignment: isForward ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: DoubleTapFeedback._horizontalInset(context)),
            child: FadeTransition(
              opacity: _fadeInCurve,
              child: Row(
                mainAxisSize: .min,
                children: [
                  // Chevron leads on the side the seek travels toward.
                  if (!isForward) ...[_buildChevron(context, chevronHeight), const SizedBox(width: 8)],
                  ValueListenableBuilder<int>(
                    valueListenable: widget.seconds,
                    builder: (context, seconds, _) {
                      // The amount is also the live-region leaf. Keeping the listener
                      // here updates text and semantics without rebuilding the chevron.
                      return Semantics(
                        container: true,
                        liveRegion: true,
                        excludeSemantics: true,
                        label: isForward
                            ? t.videoControls.seekForwardButton(seconds: seconds)
                            : t.videoControls.seekBackwardButton(seconds: seconds),
                        child: _OutlinedAmountLabel(
                          label: formatSkipFeedbackLabel(seconds),
                          style: amountStyle,
                          devicePixelRatio: dpr,
                          growTowardChevron: !isForward,
                        ),
                      );
                    },
                  ),
                  if (isForward) ...[const SizedBox(width: 8), _buildChevron(context, chevronHeight)],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The burst total with silo's caption-style keyline: a stroked copy of the
/// text underneath the filled copy. Both copies share identical text and
/// constraints so the fill lands exactly on the outline.
class _OutlinedAmountLabel extends StatelessWidget {
  final String label;
  final TextStyle style;
  final double devicePixelRatio;

  /// Which side the chevron sits on: digit growth extends away from it.
  final bool growTowardChevron;

  const _OutlinedAmountLabel({
    required this.label,
    required this.style,
    required this.devicePixelRatio,
    required this.growTowardChevron,
  });

  @override
  Widget build(BuildContext context) {
    final textAlign = growTowardChevron ? TextAlign.left : TextAlign.right;
    final outlineStyle = style.copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = DoubleTapFeedback._labelOutlineWidth * devicePixelRatio
        ..strokeJoin = StrokeJoin.round
        ..color = DoubleTapFeedback._outlineColor,
    );

    Widget text(TextStyle s) => Text(label, style: s, maxLines: 1, softWrap: false, textAlign: textAlign);

    return Padding(
      // Stroked text draws past the glyph advance, so the outermost keyline
      // needs slack or it gets sliced.
      padding: const EdgeInsets.symmetric(horizontal: DoubleTapFeedback._labelOutlineBleed),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: DoubleTapFeedback._labelMinWidth),
        // Both copies share identical text and width so the fill lands exactly
        // on the outline.
        child: IntrinsicWidth(child: Stack(children: [text(outlineStyle), text(style)])),
      ),
    );
  }
}

/// Custom-drawn chevron: tall and skinny, white stroke over a dark keyline.
class _SeekChevronPainter extends CustomPainter {
  final bool forward;

  _SeekChevronPainter({required this.forward});

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = DoubleTapFeedback._chevronStrokeWidth;
    final path = ui.Path();
    if (forward) {
      // ">" — vertex on the skipped-to side, arms opening back the way we came.
      path.moveTo(0, 0);
      path.lineTo(size.width, size.height / 2);
      path.lineTo(0, size.height);
    } else {
      // "<" — vertex on the left, arms open to the right.
      path.moveTo(size.width, 0);
      path.lineTo(0, size.height / 2);
      path.lineTo(size.width, size.height);
    }

    void draw(double width, Color color) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      );
    }

    // Keyline first, fill on top.
    draw(strokeWidth * DoubleTapFeedback._outlineStrokeScale, DoubleTapFeedback._outlineColor);
    draw(strokeWidth, Colors.white);
  }

  @override
  bool shouldRepaint(_SeekChevronPainter oldDelegate) => oldDelegate.forward != forward;
}
