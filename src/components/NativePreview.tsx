import { requireNativeView } from 'expo';
import { forwardRef, useEffect, useImperativeHandle, useRef, useState } from 'react';
import { StyleSheet, Text, View, type ViewStyle } from 'react-native';

import {
  addPreviewProgressListener,
  addPreviewStatusListener,
  createPreview,
  isCompositorAvailable,
  releasePreview,
  seekPreview,
  setPreviewPaused,
  type CompositeRequest,
  type PreviewStatus,
} from '../lib/compositor';
import { colors, radius, spacing } from '../theme';

/**
 * NativePreview — the ONLY preview player in the overhauled app.
 *
 * The composition is built ONCE natively (the same builder the exporter
 * uses) and played by a single AVPlayer: cut boundaries live inside the
 * composition, the song is one continuous track, and JavaScript never
 * polls, swaps players, or chases sync. Progress/status events are
 * informational — they drive the playhead and labels, never playback.
 *
 * Rebuilds happen only when `requestKey` changes (i.e. the edit itself
 * changed) — never for play/pause or position updates.
 */

export interface NativePreviewHandle {
  seek: (seconds: number) => void;
}

interface NativePreviewProps {
  request: CompositeRequest;
  /** Change this string when the edit changes to rebuild the composition. */
  requestKey: string;
  paused: boolean;
  onProgress?: (positionSeconds: number, playing: boolean) => void;
  onStatus?: (status: PreviewStatus) => void;
  style?: ViewStyle;
}

type NativeViewComponent = React.ComponentType<{ previewId?: string; style?: ViewStyle }>;
let cachedNativeView: NativeViewComponent | null | undefined;
function nativeView(): NativeViewComponent | null {
  if (cachedNativeView !== undefined) return cachedNativeView;
  try {
    cachedNativeView = isCompositorAvailable()
      ? (requireNativeView('MvmtCompositor') as NativeViewComponent)
      : null;
  } catch {
    cachedNativeView = null;
  }
  return cachedNativeView;
}

export const NativePreview = forwardRef<NativePreviewHandle, NativePreviewProps>(function NativePreview(
  { request, requestKey, paused, onProgress, onStatus, style },
  ref,
) {
  const [previewId, setPreviewId] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const previewIdRef = useRef<string | null>(null);
  const onProgressRef = useRef(onProgress);
  const onStatusRef = useRef(onStatus);
  useEffect(() => {
    onProgressRef.current = onProgress;
    onStatusRef.current = onStatus;
  }, [onProgress, onStatus]);

  // Build (or rebuild, when the edit changed) the native composition.
  useEffect(() => {
    if (!isCompositorAvailable()) return;
    let alive = true;
    setFailed(false);
    void (async () => {
      try {
        const id = await createPreview(request);
        if (!alive) {
          void releasePreview(id);
          return;
        }
        previewIdRef.current = id;
        setPreviewId(id);
      } catch {
        if (alive) setFailed(true);
      }
    })();
    return () => {
      alive = false;
      const id = previewIdRef.current;
      previewIdRef.current = null;
      setPreviewId(null);
      if (id) void releasePreview(id);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [requestKey]);

  // Play/pause follows the prop — a control, not a rebuild.
  useEffect(() => {
    if (previewId) void setPreviewPaused(previewId, paused);
  }, [previewId, paused]);

  // Informational events, filtered to this preview.
  useEffect(() => {
    if (!previewId) return;
    const progressSub = addPreviewProgressListener((event) => {
      if (event.previewId === previewId) onProgressRef.current?.(event.positionSeconds, event.playing);
    });
    const statusSub = addPreviewStatusListener((event) => {
      if (event.previewId === previewId) onStatusRef.current?.(event.status);
    });
    return () => {
      progressSub.remove();
      statusSub.remove();
    };
  }, [previewId]);

  useImperativeHandle(ref, () => ({
    seek: (seconds: number) => {
      const id = previewIdRef.current;
      if (id) void seekPreview(id, seconds);
    },
  }));

  const NativeView = nativeView();
  if (!NativeView || failed) {
    return (
      <View style={[styles.fallback, style]}>
        <Text style={styles.fallbackTitle}>{failed ? 'Preview unavailable' : 'Native engine not in this build'}</Text>
        <Text style={styles.fallbackBody}>
          {failed
            ? 'The composition could not be built from these takes. Try re-shuffling or removing a take.'
            : 'Composition preview needs the native engine (sideload/dev build) — it cannot run in Expo Go.'}
        </Text>
      </View>
    );
  }

  return (
    <View style={[styles.wrap, style]}>
      {previewId ? <NativeView previewId={previewId} style={StyleSheet.absoluteFill} /> : null}
    </View>
  );
});

const styles = StyleSheet.create({
  wrap: { backgroundColor: '#000', borderRadius: radius.lg, overflow: 'hidden' },
  fallback: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    padding: spacing.xl,
  },
  fallbackTitle: { color: colors.label, fontSize: 16, fontWeight: '700', textAlign: 'center' },
  fallbackBody: { color: colors.labelSecondary, fontSize: 13, lineHeight: 18, textAlign: 'center' },
});
