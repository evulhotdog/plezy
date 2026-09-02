import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/media_source_info.dart';
import '../../../theme/mono_tokens.dart';
import '../../countdown_fill.dart';
import '../../app_icon.dart';

/// The "Skip Intro"/"Skip Credits" pill. Ported from silo-android's
/// `tv-skip-intro-shrinking-fill` branch: instead of a countdown number, the
/// button's own background carries the timer - a [CountdownFill] sweeping
/// left-to-right that lands full exactly as the auto-skip fires, then the
/// button either skips or reverts to the plain pill.
class SkipMarkerButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final isCredits = marker.isCredits;
    final creditsAtEnd =
        isCredits && playerDuration > Duration.zero && (playerDuration - marker.endTime).inMilliseconds <= 1000;
    final showNextEpisode = creditsAtEnd && hasNextEpisode;
    String baseButtonText;
    if (showNextEpisode) {
      baseButtonText = t.videoControls.nextEpisode;
    } else if (isCredits) {
      baseButtonText = t.videoControls.skipCredits;
    } else {
      baseButtonText = t.videoControls.skipIntro;
    }

    final buttonIcon = showNextEpisode ? Symbols.skip_next_rounded : Symbols.fast_forward_rounded;
    final showFill = isAutoSkipActive && shouldShowAutoSkip;

    return FocusableWrapper(
      focusNode: focusNode,
      onSelect: onActivate,
      borderRadius: tokens(context).radiusSm,
      useBackgroundFocus: true,
      autoScroll: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
          onFocusDown();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onActivate,
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
                    child: CountdownFill(
                      progress: autoSkipProgress,
                      total: Duration(seconds: autoSkipDelay),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
