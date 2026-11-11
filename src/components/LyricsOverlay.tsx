import { useMemo, useState, type ReactNode } from 'react';
import { StyleSheet, Text, View, type TextStyle, type ViewStyle } from 'react-native';

import type { CompositeLyrics, LyricAnimationParams, ResolvedLyricStyle } from '../lib/compositor';
import { lyricFontByPostScriptName } from '../lib/lyricFonts';

/**
 * LyricsOverlay — the PREVIEW renderer for lyrics, drawn by the app
 * over the native preview (the WatermarkOverlay pattern).
 *
 * Previews deliberately do NOT carry the native animation tool (it
 * throws when assigned to a player item — the Edit crash of
 * 2026-11-09), so the export burns the real text layers while this
 * overlay is their visual stand-in. Both renderers implement the ONE
 * parametric spec in src/lib/lyricAnimations.ts from the same
 * resolved payload (composition seconds), which is what keeps
 * preview == export.
 *
 * Props: the composite lyrics payload, the playhead in composition
 * seconds, and the stage width (font size = sizeRatio × width).
 */

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
const easeOutCubic = (x: number) => 1 - Math.pow(1 - x, 3);
const easeInCubic = (x: number) => x * x * x;
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

interface AnimState {
  opacity: number;
  scale: number;
  dxFrac: number;
  dyFrac: number;
  rotateDeg: number;
}

function enterE(anim: LyricAnimationParams, tIn: number): number {
  return anim.enterSecs <= 0 ? 1 : easeOutCubic(clamp01(tIn / anim.enterSecs));
}
function exitE(anim: LyricAnimationParams, tOut: number): number {
  return anim.exitSecs <= 0 ? 1 : easeInCubic(clamp01(tOut / anim.exitSecs));
}
function stateFromE(anim: LyricAnimationParams, e: number): AnimState {
  return {
    opacity: lerp(anim.fromOpacity, 1, e),
    scale: lerp(anim.fromScale, 1, e),
    dxFrac: anim.fromXOffsetFrac * (1 - e),
    dyFrac: anim.fromYOffsetFrac * (1 - e),
    rotateDeg: anim.fromRotateDeg * (1 - e),
  };
}

interface UnitStyle {
  opacity: number;
  transform: ViewStyle['transform'];
}

/** Text with an optional outline: eight offset copies behind the
 *  main glyph run — the four cardinal directions plus the diagonals
 *  at 0.71× (so wide strokes stay a continuous outline instead of
 *  four separated shadows). React Native Text has no stroke; the
 *  native renderer draws the real outline — this is its preview
 *  stand-in. The copy distance IS the stroke width in points
 *  (strokeWidthRatio × fontSize), so the width slider's range reads
 *  directly: at the default font size on a phone-width stage the
 *  ratio range 0.03–0.30 is roughly 1pt–9pt of outline. */
function OutlinedText({
  text,
  textStyle,
  strokeColor,
  strokeWidth,
  unitStyle,
}: {
  text: string;
  textStyle: TextStyle;
  strokeColor?: string;
  strokeWidth: number;
  unitStyle?: UnitStyle;
}) {
  const diag = strokeWidth * 0.71;
  const copies =
    strokeColor && strokeWidth > 0
      ? [
          { transform: [{ translateX: -strokeWidth }, { translateY: 0 }] },
          { transform: [{ translateX: strokeWidth }, { translateY: 0 }] },
          { transform: [{ translateX: 0 }, { translateY: -strokeWidth }] },
          { transform: [{ translateX: 0 }, { translateY: strokeWidth }] },
          { transform: [{ translateX: -diag }, { translateY: -diag }] },
          { transform: [{ translateX: diag }, { translateY: -diag }] },
          { transform: [{ translateX: -diag }, { translateY: diag }] },
          { transform: [{ translateX: diag }, { translateY: diag }] },
        ]
      : [];
  return (
    <View style={unitStyle}>
      <View>
        {copies.map((t, i) => (
          <Text
            key={i}
            style={[textStyle, styles.strokeCopy, { color: strokeColor, transform: t.transform }]}
            pointerEvents="none">
            {text}
          </Text>
        ))}
        <Text style={textStyle}>{text}</Text>
      </View>
    </View>
  );
}

export function LyricsOverlay({
  lyrics,
  positionSeconds,
  width,
}: {
  lyrics: CompositeLyrics | null;
  /** Playhead, composition seconds. */
  positionSeconds: number;
  /** Stage width in points. */
  width: number;
}) {
  const [lineSize, setLineSize] = useState({ w: 0, h: 0 });
  const [stageH, setStageH] = useState(0);
  const active = useMemo(() => {
    if (!lyrics) return null;
    return lyrics.lines.find((l) => positionSeconds >= l.startSeconds && positionSeconds < l.endSeconds) ?? null;
  }, [lyrics, positionSeconds]);

  if (!lyrics || !active || width <= 0) return null;

  const style: ResolvedLyricStyle = lyrics.style;
  const anim = style.animation;
  const fontSize = Math.max(8, style.sizeRatio * width);
  const font = lyricFontByPostScriptName(style.fontPostScriptName);
  const duration = Math.max(0.01, active.endSeconds - active.startSeconds);
  const tIn = positionSeconds - active.startSeconds;
  const tOut = active.endSeconds - positionSeconds;

  const textStyle: TextStyle = {
    fontFamily: font?.family,
    fontSize,
    fontWeight: style.bold ? '700' : '400',
    color: style.color,
    textAlign: 'center',
    lineHeight: fontSize * 1.22,
  };
  const strokeWidth = style.strokeColor ? Math.max(0, (style.strokeWidthRatio ?? 0) * fontSize) : 0;

  const lineW = lineSize.w > 0 ? lineSize.w : width * 0.8;
  const lineH = lineSize.h > 0 ? lineSize.h : fontSize * 1.3;
  const toUnit = (s: AnimState, extraScale = 1): UnitStyle => ({
    opacity: s.opacity,
    transform: [
      { translateX: s.dxFrac * lineW },
      { translateY: s.dyFrac * lineH },
      { scale: s.scale * extraScale },
      { rotate: `${s.rotateDeg}deg` },
    ],
  });

  // Word units: timed words when the line carries them, else tokens.
  const hasWordTimes = !!active.words && active.words.length > 0;
  const words = hasWordTimes
    ? active.words!.map((w) => ({ text: w.text, start: w.startSeconds, end: w.endSeconds }))
    : active.text
        .split(/\s+/)
        .filter(Boolean)
        .map((text) => ({ text, start: null as number | null, end: null as number | null }));

  // Karaoke without word timings degrades to line-level ('none').
  const wordMode = anim.wordMode === 'karaoke' && !hasWordTimes ? 'none' : anim.wordMode;

  let content: ReactNode;
  if (wordMode === 'none' || words.length === 0) {
    const e = Math.min(enterE(anim, tIn), exitE(anim, tOut));
    const state = stateFromE(anim, e);
    // 'none'-mode emphasis: the breathing pulse from the shared spec.
    let pulse = 1;
    if (anim.emphasisScale !== 1) {
      const period = Math.min(1.2, Math.max(0.2, duration));
      pulse = 1 + (anim.emphasisScale - 1) * (0.5 - 0.5 * Math.cos((2 * Math.PI * tIn) / period));
    }
    content = (
      <OutlinedText
        text={active.text}
        textStyle={textStyle}
        strokeColor={style.strokeColor}
        strokeWidth={strokeWidth}
        unitStyle={toUnit(state, pulse)}
      />
    );
  } else {
    // Word modes: the exit envelope applies to the whole line; enter
    // behaviour is per word (stagger / karaoke / typewriter).
    const wrapUnit = toUnit(stateFromE(anim, exitE(anim, tOut)));
    const wordUnits = words.map((word, i) => {
      let unit: UnitStyle | undefined;
      let hidden = false;
      if (wordMode === 'stagger') {
        unit = toUnit(stateFromE(anim, enterE(anim, tIn - i * anim.wordStaggerSecs)));
      } else if (wordMode === 'karaoke') {
        const start = word.start ?? active.startSeconds;
        const end = word.end ?? active.endSeconds;
        if (positionSeconds < start) unit = { opacity: 0.45, transform: [] };
        else if (positionSeconds < end) unit = { opacity: 1, transform: [{ scale: anim.emphasisScale }] };
        else unit = { opacity: 1, transform: [] };
      } else {
        // typewriter
        const start = word.start ?? active.startSeconds + (duration * i) / Math.max(1, words.length);
        hidden = positionSeconds < start;
        unit = { opacity: hidden ? 0 : 1, transform: [] };
      }
      return (
        <OutlinedText
          key={i}
          text={word.text}
          textStyle={textStyle}
          strokeColor={style.strokeColor}
          strokeWidth={strokeWidth}
          unitStyle={unit}
        />
      );
    });
    content = (
      <View style={[styles.wordRow, { gap: fontSize * 0.24 }, wrapUnit]}>{wordUnits}</View>
    );
  }

  const pillStyle: ViewStyle =
    style.background === 'pill'
      ? {
          backgroundColor: style.backgroundColor ?? 'rgba(10,10,12,0.55)',
          borderRadius: fontSize * 0.35,
          paddingHorizontal: fontSize * 0.45,
          paddingVertical: fontSize * 0.16,
        }
      : {};

  return (
    <View
      pointerEvents="none"
      onLayout={(e) => {
        const h = e.nativeEvent.layout.height;
        if (h > 0 && Math.abs(h - stageH) > 1) setStageH(h);
      }}
      style={[
        styles.anchor,
        {
          justifyContent:
            style.position === 'top' ? 'flex-start' : style.position === 'center' ? 'center' : 'flex-end',
          paddingTop: style.position === 'top' ? width * 0.16 : 0,
          paddingBottom: style.position === 'bottom' ? width * 0.2 : 0,
          paddingHorizontal: width * 0.04,
          // Fine vertical nudge: fraction of the stage height,
          // positive = up (screen space is y-down) — mirrors the
          // native burn-in's placement exactly.
          transform: [{ translateY: -(style.verticalOffsetRatio ?? 0) * stageH }],
        },
      ]}>
      <View
        style={[styles.lineBox, pillStyle]}
        onLayout={(e) => {
          const { width: w, height: h } = e.nativeEvent.layout;
          if (Math.abs(w - lineSize.w) > 1 || Math.abs(h - lineSize.h) > 1) setLineSize({ w, h });
        }}>
        {content}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  anchor: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, alignItems: 'center' },
  lineBox: { alignItems: 'center', maxWidth: '100%' },
  wordRow: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', alignItems: 'center' },
  strokeCopy: { position: 'absolute', top: 0, left: 0, right: 0 },
});
