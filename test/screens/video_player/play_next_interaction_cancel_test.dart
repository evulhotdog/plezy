import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player/episode_session_state.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';

/// Any interaction — a pressed key (d-pad, arrows, remote) or a moved cursor —
/// stops the Play Next auto-play countdown and leaves the prompt up without a
/// time limit, so the viewer chooses in their own time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The screen's own periodic countdown, mirrored from _startAutoPlayTimer:
  /// whole-second ticks that advance the notifier and fire at zero.
  Timer startCountdown(EpisodeSessionState episode, {required void Function() onFire}) {
    episode.autoPlayCountdown.value = 5;
    episode.autoPlayCountdownStart = 5;
    return Timer.periodic(const Duration(seconds: 1), (timer) {
      final next = episode.autoPlayCountdown.value - 1;
      episode.autoPlayCountdown.value = next;
      if (next <= 0) {
        timer.cancel();
        onFire();
      }
    });
  }

  group('EpisodeSessionState.cancelAutoPlayCountdown', () {
    testWidgets('stops a running countdown and parks the prompt on the manual state', (tester) async {
      final episode = EpisodeSessionState();
      addTearDown(episode.dispose);
      var advanced = false;
      episode.autoPlayTimer = startCountdown(episode, onFire: () => advanced = true);

      expect(episode.cancelAutoPlayCountdown(), isTrue);
      expect(episode.autoPlayTimer!.isActive, isFalse);
      expect(episode.autoPlayCountdown.value, -1, reason: 'the manual-choice sentinel the fill reads');
      expect(episode.autoPlayCountdownStart, 0);

      // Well past the original deadline the advance never fires: the choice
      // has no time limit now.
      await tester.pump(const Duration(seconds: 30));
      expect(advanced, isFalse);
    });

    test('is a no-op when no countdown is running', () {
      final episode = EpisodeSessionState();
      addTearDown(episode.dispose);
      expect(episode.cancelAutoPlayCountdown(), isFalse);
      expect(episode.autoPlayCountdown.value, 5, reason: 'untouched initial state');
    });
  });

  testWidgets('a pressed key stops the play-next countdown but keeps the prompt', (tester) async {
    final nativeInitialize = Completer<bool>();

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) => nativeInitialize.future,
      eventHandler: (_) async => null,
      testBody: () async {
        final key = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(
          ChangeNotifierProvider(
            create: (_) => PlaybackStateProvider(),
            child: MaterialApp(
              home: VideoPlayerScreen(
                key: key,
                metadata: testMediaItem(title: 'Play next interaction cancel'),
                isOffline: true,
              ),
            ),
          ),
        );
        await tester.pump();

        final episode = key.currentState!.debugEpisodeForTesting;
        episode.showPlayNextDialog = true;
        var advanced = false;
        episode.autoPlayTimer = startCountdown(episode, onFire: () => advanced = true);

        // A d-pad press is interaction: the countdown stops, the prompt stays.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(episode.autoPlayTimer!.isActive, isFalse);
        expect(episode.autoPlayCountdown.value, -1);

        // No time limit: parked at the manual state, nothing advances.
        await tester.pump(const Duration(seconds: 10));
        expect(advanced, isFalse);

        // A key with no prompt up must not touch the idle state.
        episode.autoPlayCountdown.value = 5;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(episode.autoPlayCountdown.value, 5);

        await tester.pumpWidget(const SizedBox.shrink());
        nativeInitialize.complete(true);
        await tester.pump();
      },
    );
  });

  testWidgets('cursor movement over the player stops the play-next countdown', (tester) async {
    final episode = EpisodeSessionState();
    addTearDown(episode.dispose);
    episode.showPlayNextDialog = true;
    var advanced = false;
    episode.autoPlayTimer = startCountdown(episode, onFire: () => advanced = true);

    // The screen wires the chrome controller's pointer hook to the cancel;
    // drive the hook the way the full-surface hover region does.
    final controller = PlayerChromeController();
    addTearDown(controller.dispose);
    controller.onPointerActivity = episode.cancelAutoPlayCountdown;

    expect(controller.recordPointerActivity(), isTrue);
    expect(episode.autoPlayTimer!.isActive, isFalse);
    expect(episode.autoPlayCountdown.value, -1);
    expect(advanced, isFalse);

    // recordPointerActivity also arms the chrome auto-hide timer; retire it
    // so the test binding sees no pending timers.
    controller.cancelAutoHide();
  });
}
