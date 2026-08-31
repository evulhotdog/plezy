import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/media_source_info.dart';
import '../../../theme/mono_tokens.dart';
import '../../app_icon.dart';

/// The "Skip Intro"/"Skip Credits" pill. Ported from silo-android's
/// `tv-skip-intro-shrinking-fill` branch: instead of a countdown number, the
/// button's own background carries the timer - a fill sweeping left-to-right
/// that lands full exactly as the auto-skip fires, then the button either
/// skips or reverts to the plain pill.
class SkipMarkerButton extends StatefulWidget {
  final MediaMarker marker;
  final Duration playerDuration;
  final bool hasNextEpisode;
  final bool isAutoSkipActive;
  final bool shouldShowAutoSkip;
  final int autoSkipDelay;
  final double autoSkipProgress;
  final FocusNode focusNode;
  final VoidCallback onActivate;
  final VoidCallback onFocusDown;

  const SkipMarkerButton({
    super.key,
    required this.marker,
    required this.playerDuration,
    required this.hasNextEpisode,
    required this.isAutoSkipActive,
    required this.shouldShowAutoSkip,
    required this.autoSkipDelay,
    required this.autoSkipProgress,
    required this.focusNode,
    required this.onActivate,
    required this.onFocusDown,
  });

  @override
  State<SkipMarkerButton> createState() => _SkipMarkerButtonState();
}

class _SkipMarkerButtonState extends State<SkipMarkerButton> with SingleTickerProviderStateMixin {
  /// The countdown fill. Driven by the frame clock (vsync), re-anchored from
  /// the quantized countdown timer on every tick: the controller interpolates
  /// from the last known progress to 1.0 over the remaining wall-clock time,
  /// so the sweep is smooth and converges precisely when the auto-skip fires -
  /// the same scheme as silo's `withFrameMillis` fill.
  late final AnimationController _fill = AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
    if (widget.isAutoSkipActive && widget.shouldShowAutoSkip) {
      _syncFill();
    }
  }

  @override
  void didUpdateWidget(SkipMarkerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isAutoSkipActive && widget.shouldShowAutoSkip) {
      // Re-anchor whenever the countdown timer advances; also covers becoming
      // active with an unchanged (zero) progress.
      if (widget.autoSkipProgress != oldWidget.autoSkipProgress ||
          !(oldWidget.isAutoSkipActive && oldWidget.shouldShowAutoSkip)) {
        _syncFill();
      }
    } else if (_fill.isAnimating) {
      // Countdown stopped (pause, user interaction): the fill hides with the
      // overlay and re-anchors from zero if the countdown resumes.
      _fill.stop();
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  void _syncFill() {
    final remainingMs = (widget.autoSkipDelay * (1 - widget.autoSkipProgress) * 1000).round();
    _fill
      ..duration = Duration(milliseconds: remainingMs)
      ..forward(from: widget.autoSkipProgress.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final isCredits = widget.marker.isCredits;
    final creditsAtEnd =
        isCredits &&
        widget.playerDuration > Duration.zero &&
        (widget.playerDuration - widget.marker.endTime).inMilliseconds <= 1000;
    final showNextEpisode = creditsAtEnd && widget.hasNextEpisode;
    String baseButtonText;
    if (showNextEpisode) {
      baseButtonText = t.videoControls.nextEpisode;
    } else if (isCredits) {
      baseButtonText = t.videoControls.skipCredits;
    } else {
      baseButtonText = t.videoControls.skipIntro;
    }

    final buttonIcon = showNextEpisode ? Symbols.skip_next_rounded : Symbols.fast_forward_rounded;
    final showFill = widget.isAutoSkipActive && widget.shouldShowAutoSkip;

    return FocusableWrapper(
      focusNode: widget.focusNode,
      onSelect: _activate,
      borderRadius: tokens(context).radiusSm,
      useBackgroundFocus: true,
      autoScroll: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
          widget.onFocusDown();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _activate,
          borderRadius: BorderRadius.circular(tokens(context).radiusSm),
          child: Stack(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(tokens(context).radiusSm),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2)),
                  ],
                ),
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    Text(
                      baseButtonText,
                      style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: .w600),
                    ),
                    const SizedBox(width: 8),
                    AppIcon(buttonIcon, fill: 1, color: Colors.black, size: 20),
                  ],
                ),
              ),
              if (showFill)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(tokens(context).radiusSm),
                    child: AnimatedBuilder(
                      animation: _fill,
                      builder: (context, _) {
                        return Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FractionallySizedBox(
                            widthFactor: _fill.value.clamp(0.0, 1.0),
                            // Silo's fill is white-on-black; mirrored polarity
                            // for this white pill: a subtle black sweep.
                            child: const ColoredBox(color: Color(0x1F000000)),
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _activate() => widget.onActivate();
}
