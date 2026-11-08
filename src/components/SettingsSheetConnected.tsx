import { Alert } from 'react-native';

import { effectiveRegion } from '../lib/analysis';
import { saveToPhotoLibrary } from '../lib/media';
import { useStudio } from '../store/StudioContext';
import { formatTime } from '../theme';
import { SettingsSheet } from './SettingsSheet';

interface SettingsSheetConnectedProps {
  visible: boolean;
  onClose: () => void;
  /** Track picking lives on the Record stage — screens route back there. */
  onPickTrack: () => void;
  onOpenRegion: () => void;
  /** The Settings "Export video" action: to Export when a cut exists, else to the branch choice. */
  onExportAction: () => void;
  /** Override the default save-latest-take behaviour (camera uses its notice toast). */
  onSaveTake?: () => void;
}

/**
 * SettingsSheet pre-wired to the studio store: every flow screen opens
 * the SAME configuration sheet with the REAL current values (camera
 * prefs live in the store, so changes made here apply on the camera).
 * Only navigation differs per screen, hence the callbacks.
 */
export function SettingsSheetConnected({
  visible,
  onClose,
  onPickTrack,
  onOpenRegion,
  onExportAction,
  onSaveTake,
}: SettingsSheetConnectedProps) {
  const studio = useStudio();
  const { track, takes } = studio;
  const eff = effectiveRegion(studio.trackRegion, track?.durationSeconds);
  return (
    <SettingsSheet
      visible={visible}
      onClose={onClose}
      countdown={studio.countdown}
      onCountdownChange={studio.setCountdown}
      resolution={studio.resolution}
      onResolutionChange={studio.setResolution}
      frameRate={studio.frameRate}
      onFrameRateChange={studio.setFrameRate}
      mirror={studio.mirror}
      onMirrorChange={studio.setMirror}
      gridOverlay={studio.gridOverlay}
      onGridOverlayChange={studio.setGridOverlay}
      levelGuide={studio.levelGuide}
      onLevelGuideChange={studio.setLevelGuide}
      trackName={track?.name ?? null}
      regionLabel={eff ? `${formatTime(eff.startSeconds)}–${formatTime(eff.endSeconds)}` : 'Full'}
      onPickTrack={onPickTrack}
      onOpenRegion={onOpenRegion}
      audioOffsetMs={studio.audioOffsetMs}
      onAudioOffsetChange={studio.setAudioOffsetMs}
      countInBeats={studio.countInBeats}
      onCountInBeatsChange={studio.setCountInBeats}
      metronome={studio.metronome}
      onMetronomeChange={studio.setMetronome}
      autosave={studio.autosave}
      onAutosaveChange={studio.setAutosave}
      exportQuality={studio.exportQuality}
      onExportQualityChange={studio.setExportQuality}
      onSaveTake={
        onSaveTake ??
        (async () => {
          const latest = takes[0];
          if (!latest) return;
          Alert.alert(
            'Save to Photos',
            (await saveToPhotoLibrary(latest.uri)) ? 'Saved.' : 'Photos permission was not granted.',
          );
        })
      }
      onExportAction={onExportAction}
    />
  );
}
