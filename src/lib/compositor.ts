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
  releasePreview,
  renderVideo,
  seekPreview,
  setPreviewPaused,
  startCapture,
  stopCapture,
  type AssetInfo,
  type CapturePreviewProps,
  type CaptureResult,
  type CaptureStartArgs,
  type CompositeClipInput,
  type CompositeRequest,
  type CompositeResult,
  type ExportProgressEvent,
  type PreviewProgressEvent,
  type PreviewStatus,
  type PreviewStatusEvent,
  type TakeSyncMeasurement,
  type TakeSyncStatus,
} from '../../modules/mvmt-compositor/src/index';
