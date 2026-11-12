/**
 * App-side access to the native media engine (the local Expo module in
 * `modules/mvmt-compositor`, iOS AVFoundation).
 *
 * The engine only exists in development / sideload builds — custom
 * native code cannot run in Expo Go. `isCompositorAvailable()` is the
 * gate: UI shows real preview/export actions when it's true and an
 * honest explanation when it isn't. Never call the engine without
 * checking availability first.
 */
export {
  addExportProgressListener,
  addPreviewProgressListener,
  addPreviewStatusListener,
  cancelExport,
  CapturePreview,
  createPreview,
  inspectAsset,
  isCaptureAvailable,
  isCompositorAvailable,
  measureTakeSync,
  prepareEqSong,
  prepareMixMasterSong,
  prepareSong,
  setCaptureExposureLock,
  setCaptureQuality,
  setCaptureStabilization,
  releasePreview,
  renderVideo,
  seekPreview,
  setPreviewPaused,
  startCapture,
  stopCapture,
  waveformPeaks,
  type AssetInfo,
  type CapturePreviewProps,
  type CaptureResult,
  type CaptureStartArgs,
  type CompositeClipInput,
  type CompositeLyricLine,
  type CompositeLyrics,
  type CompositeLyricWord,
  type CompositeRequest,
  type CompositeResult,
  type LyricAnimationParams,
  type ResolvedLookParams,
  type ResolvedLyricDecor,
  type ResolvedLyricStyle,
  type ExportProgressEvent,
  type PreviewProgressEvent,
  type PreviewStatus,
  type PreviewStatusEvent,
  type TakeSyncMeasurement,
  type TakeSyncStatus,
  type WaveformPeaks,
} from '../../modules/mvmt-compositor/src/index';
