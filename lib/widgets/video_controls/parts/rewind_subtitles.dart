part of '../video_controls.dart';

/// Rewind-temporary subtitles: a discrete left-D-pad skip with the chrome
/// hidden turns subtitles on for the rewound span and turns them back off
/// once playback returns to the press point (the anchor).
///
/// The window is anchored to the ORIGINAL press; the
/// `tempSubtitlesAnchorMoves` sub-option re-anchors on each additional
/// discrete press. Held-key repeats are acceleration of one gesture, never
/// discrete presses, so they neither open nor re-anchor the window.
///
/// Enable/revert talk to the player directly — never through the user funnel
/// (TrackManager.onSubtitleTrackSelectedByUser), which would persist the
/// temporary choice as the viewer's server-side track preference.
extension _PlexVideoControlsRewindSubtitlesMethods on _PlexVideoControlsState {
  bool get _tempSubsEnabled => _settings.read(SettingsService.tempSubtitlesOnRewind);
  bool get _tempSubsAnchorMoves => _settings.read(SettingsService.tempSubtitlesAnchorMoves);

  /// "Subtitles off" in the same sense the visibility toggle uses: nothing is
  /// rendered when the selection is Off/null OR the renderer is hidden (a
  /// track can stay selected under a hidden renderer on mpv).
  bool _subtitlesEffectivelyOff() {
    if (!_subtitlesVisible) return true;
    final selected = widget.player.state.track.subtitle;
    return selected == null || selected.id == SubtitleTrack.off.id;
  }

  /// Which track the temporary window shows: the viewer's own last non-Off
  /// pick when it still exists, else the default-flagged non-forced track,
  /// else any non-forced track, else whatever remains (a forced-only catalog
  /// still deserves dialogue re-reading).
  SubtitleTrack? _pickTempSubtitleCandidate() {
    final candidates = widget.player.state.tracks.subtitle.where(
      (track) => track.id != SubtitleTrack.auto.id && track.id != SubtitleTrack.off.id,
    );
    if (candidates.isEmpty) return null;
    final remembered = _lastNonOffSubtitleTrack;
    if (remembered != null) {
      for (final track in candidates) {
        if (track.id == remembered.id) return track;
      }
    }
    final nonForced = candidates.where((track) => !track.effectiveForced);
    for (final track in nonForced) {
      if (track.isDefault) return track;
    }
    return nonForced.isNotEmpty ? nonForced.first : candidates.first;
  }

  /// Left-D-pad backward skip hook, called BEFORE the seek so the anchor is
  /// the pre-seek press position — the coalesced seek lands up to 800 ms later.
  void _onRewindSkipPress() {
    if (!widget.canControl || widget.isLive) return;
    if (!_tempSubsEnabled) return;
    if (widget.player.state.duration.inMilliseconds <= 0) return;
    if (_hasBurnedSourceSubtitle()) return;

    final anchor = widget.player.currentPosition;
    if (_tempSubsActive) {
      if (_tempSubsAnchorMoves) {
        _tempSubsAnchor = anchor;
        _tempSubsArmed = false;
      }
      return;
    }
    if (!_subtitlesEffectivelyOff()) return;
    unawaited(_activateTempSubtitles(anchor));
  }

  Future<void> _activateTempSubtitles(Duration anchor) async {
    final candidate = _pickTempSubtitleCandidate();
    if (candidate == null) return;

    final restoreTrack = widget.player.state.track.subtitle ?? SubtitleTrack.off;
    _tempSubsAnchor = anchor;
    _tempSubsRestoreTrack = restoreTrack;
    _tempSubsRestoreVisibility = _subtitlesVisible;
    _tempSubsActive = true;
    _tempSubsArmed = false;
    _tempSubsCandidate = candidate;
    unawaited(_tempSubsPositionSubscription?.cancel());
    _tempSubsPositionSubscription = widget.player.streams.position.listen(_onTempSubsPositionTick);
    unawaited(_tempSubsTrackSubscription?.cancel());
    _tempSubsTrackSubscription = widget.player.streams.track.listen(_onTempSubsTrackEvent);

    // Restore visibility first: ExoPlayer hides by deselecting behind a
    // sticky hidden flag, so a selection made while hidden would be
    // swallowed as Off instead of shown.
    if (!_subtitlesVisible) _setSubtitleVisibility(true);
    if (candidate.id != restoreTrack.id) {
      await widget.player.selectSubtitleTrack(candidate);
    }
  }

  /// Crossing detection arms only once the rewind has actually dropped the
  /// playhead below the anchor: ticks above the anchor while the deferred
  /// seek is still pending must not count as "returned to where we started".
  void _onTempSubsPositionTick(Duration position) {
    if (!_tempSubsActive || !mounted) return;
    if (!_tempSubsArmed) {
      if (position < _tempSubsAnchor) _tempSubsArmed = true;
      return;
    }
    if (position >= _tempSubsAnchor) _revertTempSubtitles();
  }

  /// Any selection change this window did not make itself ends the window
  /// silently: a TrackSheet pick, a cycle (which routes through the screen's
  /// TrackManager funnel, not the controls callback), a source/version
  /// subtitle switch, or auto-selection has taken over. Only our own enable
  /// (the candidate) and the pre-press restore track are expected echoes.
  /// Selection changes also reach the progress tracker's stream reporting;
  /// the revert's own report re-states the pre-press selection, so the
  /// server-side reported selection converges with the user's choice.
  void _onTempSubsTrackEvent(TrackSelection selection) {
    if (!_tempSubsActive || !mounted) return;
    final selected = selection.subtitle;
    if (selected == null) return;
    if (selected.id == _tempSubsCandidate?.id || selected.id == _tempSubsRestoreTrack?.id) return;
    _cancelRewindSubtitles();
  }

  /// The pending rewind burst was voided before any seek committed (a peer
  /// seek, a timeline takeover, a jump echo): the rewound span does not
  /// exist, so the temporary enable is undone rather than left dangling.
  void _onRewindSkipBurstAbandoned() {
    if (!_tempSubsActive || _tempSubsArmed) return;
    _revertTempSubtitles();
  }

  /// Put the exact pre-press subtitle state back: the remembered selection
  /// (Off included) and, when the renderer was hidden, the hidden renderer.
  void _revertTempSubtitles() {
    final restoreTrack = _tempSubsRestoreTrack ?? SubtitleTrack.off;
    final restoreVisibility = _tempSubsRestoreVisibility;
    _cancelRewindSubtitles();
    unawaited(() async {
      await widget.player.selectSubtitleTrack(restoreTrack);
      if (!restoreVisibility) _setSubtitleVisibility(false);
    }());
  }

  /// Silent teardown: a manual subtitle interaction, a player/item swap, or
  /// unmount takes over — the feature writes nothing back afterwards.
  void _cancelRewindSubtitles() {
    _tempSubsPositionSubscription?.cancel();
    _tempSubsPositionSubscription = null;
    _tempSubsTrackSubscription?.cancel();
    _tempSubsTrackSubscription = null;
    _tempSubsActive = false;
    _tempSubsArmed = false;
  }
}
