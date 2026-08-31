import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// Rewind-temporary subtitles: a discrete left-D-pad skip with the chrome
/// hidden shows subtitles over the rewound span and reverts them once
/// playback returns to the press point.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final start = const Duration(minutes: 10);
  final justBelowAnchor = start - const Duration(milliseconds: 500);
  final track = const SubtitleTrack(id: 'sub-1', title: 'English', language: 'eng');

  group('rewind subtitles', () {
    late _RewindSubsPlayer player;
    late PlayerChromeController chrome;
    late PlayerToastController toast;
    late VideoVolumeController volume;
    late PlaybackStateProvider playbackState;
    late WatchTogetherProvider watchTogether;
    late AppDatabase database;

    setUp(() async {
      LocaleSettings.setLocaleSync(AppLocale.en);
      await initializeDateFormatting('en');
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.seekTimeSmall, 10);
      await settings.write(SettingsService.tempSubtitlesOnRewind, true);

      // Android TV: PlatformDetector.isTV() drives the directional-seek branch.
      TvDetectionService.debugSetAppleTVOverride(true);
      PlatformDetector.debugSetIsDesktopOSOverride(false);

      database = AppDatabase.forTesting(NativeDatabase.memory());
      player = _RewindSubsPlayer();
      chrome = PlayerChromeController();
      toast = PlayerToastController();
      volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
      playbackState = PlaybackStateProvider();
      watchTogether = WatchTogetherProvider();
    });

    tearDown(() async {
      TvDetectionService.debugSetAppleTVOverride(null);
      PlatformDetector.debugSetIsDesktopOSOverride(null);
      volume.dispose();
      playbackState.dispose();
      watchTogether.dispose();
      chrome.dispose();
      toast.dispose();
      await database.close();
      await player.dispose();
    });

    Future<void> pumpControls(WidgetTester tester, {bool isLive = false}) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppDatabase>.value(value: database),
            ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
            home: Scaffold(
              body: SizedBox(
                width: 1280,
                height: 720,
                child: PlexVideoControls(
                  player: player,
                  volumeController: volume,
                  metadata: testMediaItem(id: 'rewind-subtitles'),
                  toastController: toast,
                  chromeController: chrome,
                  canNavigateMediaItems: false,
                  isLive: isLive,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // The feature only arms with the chrome hidden — the D-pad skip path.
      chrome.hide();
      chrome.markControlsHidden();
      await tester.pump();
      expect(chrome.controlsVisible, isFalse);
    }

    Future<void> pressLeft(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
    }

    Future<void> teardown(WidgetTester tester) async {
      chrome.cancelAutoHide();
      toast.hide();
      await tester.pumpWidget(const SizedBox.shrink());
    }

    testWidgets('a left press with subtitles off enables them for the rewound span', (tester) async {
      await pumpControls(tester);

      await pressLeft(tester);

      expect(player.selections, [track]);
      expect(player.propertyValues, isEmpty, reason: 'visibility was already on; only the track is selected');
      await teardown(tester);
    });

    testWidgets('subtitles revert to off once playback returns to the anchor', (tester) async {
      await pumpControls(tester);
      await pressLeft(tester);

      // The deferred rewind lands: playhead drops below the press point, arming
      // the crossing check.
      player.emitPosition(justBelowAnchor);
      await tester.pump();
      player.emitPosition(start);
      await tester.pump();

      expect(player.selections.last, SubtitleTrack.off);
      expect(player.propertyValues, isEmpty);
      await teardown(tester);
    });

    testWidgets('ticks above the anchor while the rewind is pending do not revert', (tester) async {
      await pumpControls(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      // Still pinned above the anchor — the coalesced seek has not committed.
      player.emitPosition(start + const Duration(milliseconds: 250));
      await tester.pump();
      expect(player.selections, [track]);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      player.emitPosition(justBelowAnchor);
      await tester.pump();
      player.emitPosition(start);
      await tester.pump();
      expect(player.selections.last, SubtitleTrack.off);
      await teardown(tester);
    });

    testWidgets('a press is a no-op when subtitles are already on', (tester) async {
      await pumpControls(tester);
      player.selected = track;
      player.setPosition(start);

      await pressLeft(tester);

      expect(player.selections, isEmpty);
      expect(player.propertyValues, isEmpty);
      await teardown(tester);
    });

    testWidgets('a press is a no-op when the feature is disabled', (tester) async {
      final settings = SettingsService.instance;
      await settings.write(SettingsService.tempSubtitlesOnRewind, false);
      await pumpControls(tester);

      await pressLeft(tester);

      expect(player.selections, isEmpty);
      expect(player.propertyValues, isEmpty);
      await teardown(tester);
    });

    testWidgets('the turn-off point stays at the original press across additional presses', (tester) async {
      await pumpControls(tester);
      await pressLeft(tester);
      player.emitPosition(justBelowAnchor);
      await tester.pump();

      // A second skip-back at 9:59.5 must not move the anchor off 10:00: a
      // tick between the two positions reverts only under the moved anchor.
      player.setPosition(justBelowAnchor);
      await pressLeft(tester);
      player.emitPosition(start - const Duration(milliseconds: 250));
      await tester.pump();
      expect(player.selections, [track], reason: 'the second press position is not the turn-off point');

      player.emitPosition(start);
      await tester.pump();
      expect(player.selections.last, SubtitleTrack.off);
      await teardown(tester);
    });

    testWidgets('each press moves the turn-off point when the sub-option is on', (tester) async {
      final settings = SettingsService.instance;
      await settings.write(SettingsService.tempSubtitlesAnchorMoves, true);
      await pumpControls(tester);
      await pressLeft(tester);
      player.emitPosition(justBelowAnchor);
      await tester.pump();

      player.setPosition(justBelowAnchor);
      await pressLeft(tester);
      // A tick above the re-anchored point while the second rewind is still
      // pending must not count as returned: re-anchoring reset the arm.
      player.emitPosition(start - const Duration(milliseconds: 400));
      await tester.pump();
      expect(player.selections, [track], reason: 'not yet back below the new anchor');
      // The re-anchored rewind (to 9:49.5) lands, then playback climbs past
      // the NEW anchor — still below the original 10:00 — and reverts there.
      player.emitPosition(const Duration(minutes: 9, seconds: 50));
      await tester.pump();
      player.emitPosition(start - const Duration(milliseconds: 250));
      await tester.pump();

      expect(player.selections.last, SubtitleTrack.off, reason: 'the latest press re-anchored the window');
      await teardown(tester);
    });

    testWidgets('a forward press never opens the window', (tester) async {
      await pumpControls(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(player.selections, isEmpty);
      expect(player.propertyValues, isEmpty);
      await teardown(tester);
    });

    testWidgets('live TV never opens the window', (tester) async {
      await pumpControls(tester, isLive: true);

      await pressLeft(tester);

      expect(player.selections, isEmpty);
      expect(player.propertyValues, isEmpty);
      await teardown(tester);
    });

    testWidgets('a voided rewind burst undoes the temporary enable', (tester) async {
      await pumpControls(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(player.selections, [track]);

      // A jump from another source retires the pending burst: the rewind the
      // subtitles were enabled for never happens.
      player.reopenAt(start - const Duration(minutes: 1));
      await tester.pump();

      expect(player.selections.last, SubtitleTrack.off);
      await teardown(tester);
    });

    testWidgets('a manual visibility toggle during the window cancels the revert', (tester) async {
      await pumpControls(tester);
      await pressLeft(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(player.propertyValues, ['no'], reason: 'the toggle itself must have run');

      player.emitPosition(justBelowAnchor);
      await tester.pump();
      player.emitPosition(start);
      await tester.pump();
      expect(player.selections, [track], reason: 'the user took over; no forced revert');
      await teardown(tester);
    });

    testWidgets('a default-flagged track beats a forced one when picking the temp track', (tester) async {
      await pumpControls(tester);
      player.subtitleTracks
        ..clear()
        ..addAll([
          const SubtitleTrack(id: 'sub-forced', title: 'Forced', isForced: true),
          const SubtitleTrack(id: 'sub-def', title: 'Default', isDefault: true),
        ]);

      await pressLeft(tester);

      expect(player.selections.single.id, 'sub-def');
      await teardown(tester);
    });

    testWidgets('a forced-only catalog still opens the window', (tester) async {
      await pumpControls(tester);
      player.subtitleTracks
        ..clear()
        ..add(const SubtitleTrack(id: 'sub-forced', title: 'Forced', isForced: true));

      await pressLeft(tester);

      expect(player.selections.single.id, 'sub-forced');
      await teardown(tester);
    });

    testWidgets('reverting restores a hidden renderer and its selected track', (tester) async {
      await pumpControls(tester);
      player.selected = track;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(player.propertyValues, ['no']);

      await pressLeft(tester);
      expect(player.propertyValues, ['no', 'yes'], reason: 'the temp window re-reveals the hidden renderer');

      player.emitPosition(justBelowAnchor);
      await tester.pump();
      player.emitPosition(start);
      await tester.pump();
      expect(player.selections.single.id, 'sub-1', reason: 'the selected track was never off to begin with');
      expect(player.propertyValues.last, 'no', reason: 'and the renderer is hidden again');
      await teardown(tester);
    });

    testWidgets('a foreign selection during the window cancels the revert', (tester) async {
      await pumpControls(tester);
      await pressLeft(tester);

      // A cycle or source switch changed the selection without going through
      // the controls funnel: the window stands down.
      player.emitTrackSelection(const SubtitleTrack(id: 'sub-2', title: 'Other'));
      await tester.pump();

      player.emitPosition(justBelowAnchor);
      await tester.pump();
      player.emitPosition(start);
      await tester.pump();
      expect(player.selections, [track], reason: 'no forced revert after the user took over');
      await teardown(tester);
    });
  });
}

/// Player fake with subtitle-track state, a live position tick stream, and
/// recording [selectSubtitleTrack]/[setProperty] writes.
class _RewindSubsPlayer implements Player {
  _RewindSubsPlayer();

  final List<SubtitleTrack> subtitleTracks = [const SubtitleTrack(id: 'sub-1', title: 'English', language: 'eng')];
  final List<SubtitleTrack> selections = [];
  final List<String> propertyValues = [];
  final StreamController<Duration?> _jumpController = StreamController<Duration?>.broadcast();
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<TrackSelection> _trackController = StreamController<TrackSelection>.broadcast();

  final bool _playing = true;
  Duration _position = const Duration(minutes: 10);

  SubtitleTrack selected = SubtitleTrack.off;

  void setPosition(Duration value) => _position = value;

  /// Pushes a position tick the way the backend's throttled stream would.
  void emitPosition(Duration value) {
    _position = value;
    _positionController.add(value);
  }

  /// Announces a selection change the way the backend's property events do.
  void emitTrackSelection(SubtitleTrack track) {
    selected = track;
    _trackController.add(TrackSelection(subtitle: track));
  }

  /// Mirrors [PlayerBase.resetPlaybackProgress]: a stream rebuild at a new
  /// position announces a playhead jump the pending burst does not own.
  void reopenAt(Duration value) {
    _position = value;
    _jumpController.add(value);
  }

  @override
  String get playerType => 'mpv';

  @override
  Duration get currentPosition => _position;

  @override
  PlayerState get state => PlayerState(
    playing: _playing,
    position: _position,
    duration: const Duration(minutes: 45),
    seekable: true,
    tracks: Tracks(subtitle: subtitleTracks),
    track: TrackSelection(subtitle: selected),
  );

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: _positionController.stream,
    playheadJump: _jumpController.stream,
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: _trackController.stream,
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    selected = track;
    selections.add(track);
  }

  @override
  Future<void> setProperty(String name, String value) async {
    propertyValues.add(value);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    _jumpController.add(position);
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    await _jumpController.close();
    await _positionController.close();
    await _trackController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
