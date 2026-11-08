/**
 * App-side access to the native compositing engine (the local Expo
 * module in `modules/mvmt-compositor`, iOS AVFoundation).
 *
 * The engine only exists in development / EAS builds — custom native
 * code cannot run in Expo Go. `isCompositorAvailable()` is the gate:
 * Export shows the real "Render video" action when it's true and an
 * honest explanation when it isn't. Never call `renderVideo` without
 * checking availability first.
 */
export {
  isCompositorAvailable,
  renderVideo,
  type CompositeClipInput,
  type CompositeRequest,
  type CompositeResult,
} from '../../modules/mvmt-compositor/src/index';
