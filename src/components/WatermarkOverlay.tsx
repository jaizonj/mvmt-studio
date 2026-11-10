import { useEffect, useState } from 'react';
import { Image } from 'expo-image';
import { StyleSheet, View } from 'react-native';

// The logo lockup (assets/logo-lockup.png, 363×175).
const LOCKUP = require('../../assets/logo-lockup.png');

/**
 * The watermark as PREVIEWS show it: an overlay drawn by the app,
 * flipping between the top-left and bottom-right corners every 5s.
 *
 * Previews deliberately do NOT carry the native animation tool —
 * assigning a video composition with one to an AVPlayerItem throws
 * on device (crash log 2026-11-09-220942, the Edit-screen crash).
 * The EXPORT still burns the real stamp into the file through the
 * composition builder's animation tool (export path only), with the
 * same size/opacity/flip spec — this overlay is its visual stand-in
 * so what you preview is what you export.
 */
export function WatermarkOverlay({
  enabled,
  width,
}: {
  enabled: boolean;
  /** Width of the preview frame the overlay sits in. */
  width: number;
}) {
  const [topLeft, setTopLeft] = useState(true);
  useEffect(() => {
    if (!enabled) return;
    const t = setInterval(() => setTopLeft((v) => !v), 5000);
    return () => clearInterval(t);
  }, [enabled]);
  if (!enabled) return null;
  const w = width * 0.27;
  const m = width * 0.045;
  return (
    <View
      pointerEvents="none"
      style={[styles.box, topLeft ? { top: m, left: m } : { bottom: m, right: m }]}>
      <Image
        source={LOCKUP}
        style={{ width: w, height: (w * 175) / 363, opacity: 0.85 }}
        contentFit="contain"
      />
    </View>
  );
}

const styles = StyleSheet.create({
  box: { position: 'absolute' },
});
