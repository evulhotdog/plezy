import 'package:flutter/material.dart';

/// A left-to-right fill that sweeps across its parent as a countdown elapses,
/// landing full exactly when the countdown fires. Pure decoration: it never
/// intercepts pointers.
///
/// Shared by the "Skip Intro"/"Next Episode" pill and the Play Next prompt's
/// confirm button. Ported from silo-android's `tv-skip-intro-shrinking-fill`
/// branch.
///
/// The fill is driven by the frame clock (vsync) and re-anchored from the
/// quantized countdown [progress] on every tick: the controller interpolates
/// from the last known progress to 1.0 over the remaining wall-clock time, so
/// the sweep is smooth and converges precisely when the countdown fires - the
/// same scheme as silo's `withFrameMillis` fill.
///
/// `preserve` matters on devices that report animations disabled (several
/// Android TV boxes ship with window/transition animation scales at 0): the
/// default behavior then compresses every controller to 5% duration, and this
/// fill would machine-gun to full each tick instead of tracking the countdown.
/// The fill is a progress semantic, not decoration - it must track wall-clock
/// exactly like the timer that feeds it.
class CountdownFill extends StatefulWidget {
  /// Quantized elapsed fraction of the countdown, 0..1 (e.g. the skip
  /// timer's `autoSkipProgress`, or `1 - remaining/total`).
  final double progress;

  /// Full countdown duration. Each re-anchor interpolates to full over the
  /// remaining fraction of this duration.
  final Duration total;

  /// The fill color. The default (black at 28%) is the mirror of silo's
  /// white-14%-on-black pill: on a light button the inverted polarity needs
  /// more alpha to read at TV distance - at 12% a full sweep read as a
  /// plain white button.
  final Color color;

  const CountdownFill({super.key, required this.progress, required this.total, this.color = const Color(0x47000000)});

  @override
  State<CountdownFill> createState() => _CountdownFillState();
}

class _CountdownFillState extends State<CountdownFill> with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
  );

  @override
  void initState() {
    super.initState();
    _syncFill();
  }

  @override
  void didUpdateWidget(CountdownFill oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-anchor whenever the countdown timer advances. A pause stops the
    // countdown, which unmounts this widget (the caller only builds it while
    // the countdown runs), so there is no stop-on-pause path here.
    if (widget.progress != oldWidget.progress || widget.total != oldWidget.total) {
      _syncFill();
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  void _syncFill() {
    final p = widget.progress.clamp(0.0, 1.0);
    final remainingFraction = 1.0 - p;
    if (remainingFraction <= 0.0) {
      _fill.value = p;
      return;
    }
    // AnimationController.forward(from:) trims its duration by the remaining
    // fraction (duration x (1 - p)), so requesting the full countdown duration
    // makes the effective sweep exactly the remaining wall-clock time and the
    // fill converge to full when the countdown fires. At a duration pre-trimmed
    // to the remaining time, the controller would outpace the countdown and
    // every timer tick would snap the overshoot back - a repeated fast fill
    // instead of one sweep.
    _fill
      ..duration = widget.total
      ..forward(from: p);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _fill,
        builder: (context, _) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: _fill.value.clamp(0.0, 1.0),
              // heightFactor 1: widthFactor alone leaves the height loose and
              // a childless ColoredBox would collapse to zero height - an
              // invisible fill.
              heightFactor: 1.0,
              child: ColoredBox(color: widget.color),
            ),
          );
        },
      ),
    );
  }
}
