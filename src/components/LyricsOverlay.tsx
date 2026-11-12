import { useMemo, useState, type ReactNode } from 'react';
import { StyleSheet, Text, View, type TextStyle, type ViewStyle } from 'react-native';
import Svg, { Polygon } from 'react-native-svg';

import type {
  CompositeLyrics,
  LyricAnimationParams,
  ResolvedLyricDecor,
  ResolvedLyricStyle,
} from '../lib/compositor';
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

/** #RRGGBB → rgba() with the given alpha (for 'none' text opacity). */
function hexWithAlpha(hex: string, alpha: number): string {
  const m = /^#([0-9a-fA-F]{6})$/.exec(hex.trim());
  if (!m) return hex;
  const n = parseInt(m[1], 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`;
}

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
  const decor: ResolvedLyricDecor | undefined = lyrics.decor;
  const lineIndex = lyrics.lines.indexOf(active);
  const fontSize = Math.max(8, style.sizeRatio * width);
  const font = lyricFontByPostScriptName(style.fontPostScriptName);
  const duration = Math.max(0.01, active.endSeconds - active.startSeconds);
  const tIn = positionSeconds - active.startSeconds;
  const tOut = active.endSeconds - positionSeconds;

  // Duet: the fill alternates by line — sender lines in
  // decor.color, receiver lines in decor.secondaryColor (the
  // native burn-in mirrors this).
  const duetColor =
    decor?.kind === 'duet' ? (lineIndex % 2 === 0 ? decor.color : decor.secondaryColor) : style.color;
  // Kind 'none' (Whisper, Minimal Mono) carries no visual decor
  // — its opacity IS the line's text opacity.
  const textColor = decor?.kind === 'none' ? hexWithAlpha(duetColor, decor.opacity ?? 1) : duetColor;
  // Duet: lines alternate top/bottom by line index — sender
  // low, receiver high (the native burn-in mirrors this).
  const effectivePosition =
    decor?.kind === 'duet' ? (lineIndex % 2 === 0 ? 'bottom' : 'top') : style.position;
  // Horizontal alignment (Minimal Mono decor align): the line box
  // and the word row both follow it.
  const alignItems = decor?.align === 'left' ? 'flex-start' : decor?.align === 'right' ? 'flex-end' : 'center';
  // Letter-spacing in points (Minimal Mono decor tracking).
  const trackingPts = fontSize * (decor?.tracking ?? 0);
  const textStyle: TextStyle = {
    fontFamily: font?.family,
    fontSize,
    fontWeight: style.bold ? '700' : '400',
    color: textColor,
    textAlign: decor?.align ?? 'center',
    letterSpacing: trackingPts,
    lineHeight: fontSize * 1.22,
    // Glow decor (Neon Sign, Karaoke Pop): a soft halo around the
    // glyphs — the preview stand-in for the native shadow. Radius
    // 0.4 × font size and the decor's opacity, matching the Swift
    // burn-in (Stage 4 parity audit — the old full-strength
    // 0.5 × halo was stronger than export's).
    ...(decor?.kind === 'glow'
      ? {
          textShadowColor: hexWithAlpha(decor.color, decor.opacity ?? 0.6),
          textShadowOffset: { width: 0, height: 0 },
          textShadowRadius: fontSize * 0.4,
        }
      : {}),
    // Hard drop shadow (Big Bold Billboard): offset down-right,
    // tight radius — the native layer shadow's stand-in, at the
    // decor's opacity (Stage 4 audit — the old opaque shadow
    // was darker than export's 0.85).
    ...(decor?.kind === 'shadow'
      ? {
          textShadowColor: hexWithAlpha(decor.color, decor.opacity ?? 0.85),
          textShadowOffset: { width: fontSize * 0.08, height: fontSize * 0.08 },
          textShadowRadius: fontSize * 0.08,
        }
      : {}),
  };
  const strokeWidth = style.strokeColor ? Math.max(0, (style.strokeWidthRatio ?? 0) * fontSize) : 0;
  // Comic-burst emphasis: a flagged word renders 25% larger.
  const isEmphasisWord = (i: number) =>
    decor?.kind === 'comic-burst' && (active.emphasisWordIndices ?? []).includes(i);

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

  // The line's own content (no decor): either one whole-line unit
  // or one unit per word. `lineUnit` is the enter/exit transform
  // for the whole line — the emoji row shares it, so the emoji
  // enters with the line exactly like the native burn-in.
  let lineUnit: UnitStyle;
  let inner: ReactNode;
  if (wordMode === 'none' || words.length === 0) {
    const e = Math.min(enterE(anim, tIn), exitE(anim, tOut));
    const state = stateFromE(anim, e);
    // 'none'-mode emphasis: the breathing pulse from the shared spec.
    let pulse = 1;
    if (anim.emphasisScale !== 1) {
      const period = Math.min(1.2, Math.max(0.2, duration));
      pulse = 1 + (anim.emphasisScale - 1) * (0.5 - 0.5 * Math.cos((2 * Math.PI * tIn) / period));
    }
    lineUnit = toUnit(state, pulse);
    inner = (
      <OutlinedText
        text={active.text}
        textStyle={textStyle}
        strokeColor={style.strokeColor}
        strokeWidth={strokeWidth}
      />
    );
  } else {
    // Word modes: the exit envelope applies to the whole line; enter
    // behaviour is per word (stagger / karaoke / typewriter).
    lineUnit = toUnit(stateFromE(anim, exitE(anim, tOut)));
    const wordUnits = words.map((word, i) => {
      let unit: UnitStyle | undefined;
      let hidden = false;
      if (wordMode === 'stagger') {
        const e = enterE(anim, tIn - i * anim.wordStaggerSecs);
        let unitState = stateFromE(anim, e);
        if (decor?.kind === 'burst' || decor?.kind === 'rain') {
          // Word Explosion: words fly in from above, fanned
          // across the line (30°…150°); Rain is the same flight
          // straight down (90°).
          const count = Math.max(1, words.length);
          const angleDeg = decor?.kind === 'rain' ? 90 : 30 + (count > 1 ? (i / (count - 1)) * 120 : 60);
          const angle = (angleDeg * Math.PI) / 180;
          const distance = fontSize * 2.2 * (decor.scale ?? 1);
          const burst = 1 - e;
          unitState = {
            ...unitState,
            dxFrac: unitState.dxFrac + (Math.cos(angle) * distance * burst) / lineW,
            dyFrac: unitState.dyFrac - (Math.sin(angle) * distance * burst) / lineH,
            scale: unitState.scale * (0.3 + 0.7 * e),
          };
        } else if (decor?.kind === 'bounce') {
          // Bounce House: each word pops in with a scale wobble —
          // 1 + 0.3·sin(2πe)·(1−e), settling at e = 1.
          unitState = {
            ...unitState,
            scale: unitState.scale * (1 + 0.3 * Math.sin(e * 2 * Math.PI) * (1 - e)),
          };
        } else if (decor?.kind === 'wave-path') {
          // Wave Rider: words ride a sine wave across the line —
          // the same phase/amplitude the native burn-in uses
          // (amplitude 0.35 × font size × decor scale, one period
          // per three words).
          unitState = {
            ...unitState,
            dyFrac:
              unitState.dyFrac +
              (Math.sin((i * 2 * Math.PI) / 3) * fontSize * 0.35 * (decor.scale ?? 1)) / lineH,
          };
        }
        unit = toUnit(unitState, isEmphasisWord(i) ? 1.25 : 1);
      } else if (wordMode === 'karaoke') {
        const start = word.start ?? active.startSeconds;
        const end = word.end ?? active.endSeconds;
        // Comic-burst emphasis: a flagged word stays 25% larger.
        const emphasis = isEmphasisWord(i) ? 1.25 : 1;
        if (positionSeconds < start) unit = { opacity: 0.45, transform: [] };
        else if (positionSeconds < end)
          unit = { opacity: 1, transform: [{ scale: anim.emphasisScale * emphasis }] };
        else unit = { opacity: 1, transform: emphasis === 1 ? [] : [{ scale: emphasis }] };
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
    // Typewriter cursor: a block after the last word, blinking
    // every 0.5 s on LINE-relative time (Stage 4 parity audit —
    // the old absolute-playhead phase drifted against the
    // export's line-relative blink). Height matches the native
    // burn-in: 0.8 × the line height, at least 0.8 × font size.
    const cursorNode =
      decor?.kind === 'cursor' && wordMode === 'typewriter'
        ? (() => {
            const steps = Math.max(1, Math.floor(duration / 0.5));
            const stepDur = duration / steps;
            return (
              <View
                style={{
                  width: fontSize * 0.45,
                  height: Math.max(lineH * 0.8, fontSize * 0.8),
                  backgroundColor: decor.color,
                  borderRadius: 2,
                  opacity: Math.floor(tIn / stepDur) % 2 === 0 ? 1 : 0,
                }}
              />
            );
          })()
        : null;
    // Split Screen Words: two rows — even words on top, odd words
    // below — stacked with the same gap the native burn-in uses
    // (1.2 × font size). Otherwise one wrapping row. The gap
    // between words carries the tracking kern on both sides, like
    // the native gap width.
    const wordGap = fontSize * 0.24 + trackingPts * 2;
    inner =
      decor?.kind === 'split-screen' ? (
        <View style={{ flexDirection: 'column', gap: fontSize * 1.2 }}>
          {[0, 1].map((row) => (
            <View key={row} style={[styles.wordRow, { gap: wordGap, justifyContent: alignItems }]}>
              {wordUnits.filter((_, i) => i % 2 === row)}
              {row === 0 ? cursorNode : null}
            </View>
          ))}
        </View>
      ) : (
        <View style={[styles.wordRow, { gap: wordGap, justifyContent: alignItems }]}>
          {wordUnits}
          {cursorNode}
        </View>
      );
  }

  // Emoji row (Extra Styles): the line's stored emoji above the
  // text, inside the line's own animated unit. The 0.25 × font
  // size gap under the emoji matches the native burn-in (Stage 4
  // parity audit — the old preview glued the emoji to the text).
  const emojiNode =
    decor?.kind === 'emoji-row' && active.emoji ? (
      <Text
        style={{
          fontSize: fontSize * 1.15 * (decor.scale ?? 1),
          textAlign: 'center',
          marginBottom: fontSize * 0.25,
        }}>
        {active.emoji}
      </Text>
    ) : null;

  let content: ReactNode = (
    <View style={lineUnit}>
      {emojiNode}
      {inner}
    </View>
  );

  // Ghost trail (Extra Styles — Echo): a faded copy of the line,
  // offset down-right behind the live text. The copy shares the
  // line's own animated unit, so it moves with the line exactly
  // like the native burn-in's ghost layers.
  if (decor?.kind === 'ghost-trail') {
    const ghostShift = fontSize * 0.5 * (decor.scale ?? 1);
    content = (
      <View>
        <View style={{ position: 'absolute', top: ghostShift, left: ghostShift, opacity: decor.opacity }}>
          {content}
        </View>
        {content}
      </View>
    );
  }

  // Decor frames around the line (Extra Styles). Background shapes
  // are absolute layers behind the text; the bubble tail and the
  // comic "POW" label hang off the frame.
  if (decor?.kind === 'chat-bubble') {
    const isSender = lineIndex % 2 === 0;
    const bubbleColor = isSender ? decor.color : decor.secondaryColor;
    content = (
      <View
        style={{
          backgroundColor: bubbleColor,
          borderRadius: fontSize * 0.5,
          paddingHorizontal: fontSize * 0.55,
          paddingVertical: fontSize * 0.22,
          transform: [{ translateX: (isSender ? 1 : -1) * width * 0.06 }],
        }}>
        {content}
        <View
          style={{
            position: 'absolute',
            bottom: -fontSize * 0.22,
            ...(isSender ? { right: fontSize * 0.5 } : { left: fontSize * 0.5 }),
            width: 0,
            height: 0,
            borderLeftWidth: fontSize * 0.22,
            borderRightWidth: fontSize * 0.22,
            borderTopWidth: fontSize * 0.28,
            borderLeftColor: 'transparent',
            borderRightColor: 'transparent',
            borderTopColor: bubbleColor,
          }}
        />
      </View>
    );
  } else if (decor?.kind === 'comic-burst') {
    // Jagged 12-spike starburst (Stage 4 parity audit): the old
    // preview was a rounded rect, while the native burn-in draws
    // a starburst — the shape itself is the template's look, so
    // the preview now draws the same polygon. Points mirror the
    // Swift lyricStarburstPath (12 spikes, inner ratio 0.78,
    // inset −0.35 × font size), y-flipped into screen space.
    const burstPad = fontSize * 0.35;
    const burstW = lineW + fontSize * 1.4 + burstPad * 2;
    const burstH = lineH + fontSize * 0.7 + burstPad * 2;
    const burstCx = burstW / 2;
    const burstCy = burstH / 2;
    const burstPoints = Array.from({ length: 24 }, (_, i) => {
      const angle = (i * Math.PI) / 12 - Math.PI / 2;
      const r = i % 2 === 0 ? 1 : 0.78;
      const x = burstCx + Math.cos(angle) * (burstW / 2) * r;
      const y = burstCy - Math.sin(angle) * (burstH / 2) * r;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(' ');
    content = (
      <View
        style={{
          paddingHorizontal: fontSize * 0.7,
          paddingVertical: fontSize * 0.35,
          transform: [{ rotate: '-2deg' }],
        }}>
        <Svg
          width={burstW}
          height={burstH}
          style={{ position: 'absolute', left: -burstPad, top: -burstPad }}
          pointerEvents="none">
          <Polygon
            points={burstPoints}
            fill={decor.color}
            stroke={decor.secondaryColor}
            strokeWidth={Math.max(2, fontSize * 0.06)}
          />
        </Svg>
        {content}
        {decor.text ? (
          <Text
            style={{
              position: 'absolute',
              top: -fontSize * 0.35,
              right: -fontSize * 0.2,
              fontSize: fontSize * 0.55,
              fontWeight: '900',
              color: decor.secondaryColor,
              transform: [{ rotate: '8deg' }],
            }}>
            {decor.text}
          </Text>
        ) : null}
      </View>
    );
  } else if (decor?.kind === 'sticker-frame') {
    const dot = fontSize * 0.22;
    const dotStyle = (
      vertical: { top: number } | { bottom: number },
      horizontal: { left: number } | { right: number },
      color: string,
    ): ViewStyle => ({
      position: 'absolute',
      width: dot,
      height: dot,
      borderRadius: dot / 2,
      backgroundColor: color,
      ...vertical,
      ...horizontal,
    });
    content = (
      <View
        style={{
          borderWidth: Math.max(2, fontSize * 0.07),
          borderColor: '#FFFFFF',
          borderRadius: fontSize * 0.2,
          paddingHorizontal: fontSize * 0.4,
          paddingVertical: fontSize * 0.28,
          transform: [{ rotate: '-2deg' }],
        }}>
        {content}
        <View style={dotStyle({ top: -dot / 2 }, { left: -dot / 2 }, decor.color)} />
        <View style={dotStyle({ top: -dot / 2 }, { right: -dot / 2 }, decor.secondaryColor)} />
        <View style={dotStyle({ bottom: -dot / 2 }, { left: -dot / 2 }, decor.secondaryColor)} />
        <View style={dotStyle({ bottom: -dot / 2 }, { right: -dot / 2 }, decor.color)} />
      </View>
    );
  } else if (decor?.kind === 'pill') {
    content = (
      <View>
        <View
          style={{
            position: 'absolute',
            top: -fontSize * 0.2,
            bottom: -fontSize * 0.2,
            left: -fontSize * 0.9,
            right: -fontSize * 0.9,
            backgroundColor: decor.color,
            opacity: decor.opacity,
            borderRadius: fontSize * 0.4,
          }}
        />
        {content}
      </View>
    );
  } else if (decor?.kind === 'scanlines') {
    const scanCount = 8;
    content = (
      <View>
        {content}
        {Array.from({ length: scanCount }, (_, i) => (
          <View
            key={i}
            pointerEvents="none"
            style={{
              position: 'absolute',
              left: -fontSize * 0.5,
              right: -fontSize * 0.5,
              top: `${(((i + 0.5) / scanCount) * 100).toFixed(1)}%`,
              height: 2,
              backgroundColor: decor.color,
              opacity: (decor.opacity ?? 0.5) * 0.4,
            }}
          />
        ))}
      </View>
    );
  } else if (decor?.kind === 'rule') {
    // Thin rules above and below the line (Magazine, Elegant
    // Script, Storybook) — the same fractions the native
    // burn-in uses.
    const ruleH = Math.max(1, fontSize * 0.04);
    content = (
      <View>
        <View
          style={{
            height: ruleH,
            width: lineW,
            backgroundColor: decor.color,
            opacity: decor.opacity,
            marginBottom: fontSize * 0.25,
          }}
        />
        {content}
        <View
          style={{
            height: ruleH,
            width: lineW,
            backgroundColor: decor.color,
            opacity: decor.opacity,
            marginTop: fontSize * 0.25,
          }}
        />
      </View>
    );
  } else if (decor?.kind === 'spray') {
    // Scattered spray dots around the frame (Graffiti) — the
    // same deterministic spots the native burn-in uses.
    const dotSize = fontSize * 0.16;
    const spots: [number, number, number][] = [
      [0.02, 0.08, 0],
      [0.96, 0.04, 1],
      [0.06, 0.92, 1],
      [0.94, 0.95, 0],
      [0.48, 0.0, 0],
      [0.0, 0.45, 1],
      [0.99, 0.55, 0],
      [0.24, 1.0, 1],
      [0.76, 0.0, 0],
      [0.38, 0.0, 1],
    ];
    const dotColors = [decor.color, decor.secondaryColor];
    content = (
      <View>
        {content}
        {spots.map(([left, top, colorIndex], i) => (
          <View
            key={i}
            pointerEvents="none"
            style={{
              position: 'absolute',
              left: `${(left * 100).toFixed(1)}%`,
              top: `${(top * 100).toFixed(1)}%`,
              width: dotSize,
              height: dotSize,
              borderRadius: dotSize / 2,
              backgroundColor: dotColors[colorIndex],
            }}
          />
        ))}
      </View>
    );
  } else if (decor?.kind === 'typing-dots') {
    // A plain bubble, like chat-bubble without the tail, with
    // three dots bottom-right (Text Message Typing). The dots
    // sit at the same offsets the native burn-in uses
    // (rightmost centre 0.55 × font size from the edge).
    const isSender = lineIndex % 2 === 0;
    const bubbleColor = isSender ? decor.color : decor.secondaryColor;
    const dotSize = fontSize * 0.16;
    content = (
      <View
        style={{
          backgroundColor: bubbleColor,
          borderRadius: fontSize * 0.5,
          paddingHorizontal: fontSize * 0.55,
          paddingVertical: fontSize * 0.22,
          transform: [{ translateX: (isSender ? 1 : -1) * width * 0.06 }],
        }}>
        {content}
        <View
          style={{
            position: 'absolute',
            bottom: fontSize * 0.42,
            right: fontSize * 0.47,
            flexDirection: 'row',
            gap: fontSize * 0.16,
            opacity: tIn < 0.5 ? 1 : 0,
          }}>
          {[0, 1, 2].map((i) => (
            <View
              key={i}
              style={{
                width: dotSize,
                height: dotSize,
                borderRadius: dotSize / 2,
                backgroundColor: style.color,
              }}
            />
          ))}
        </View>
      </View>
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
            effectivePosition === 'top' ? 'flex-start' : effectivePosition === 'center' ? 'center' : 'flex-end',
          paddingTop: effectivePosition === 'top' ? width * 0.16 : 0,
          paddingBottom: effectivePosition === 'bottom' ? width * 0.2 : 0,
          paddingHorizontal: width * 0.04,
          // Fine vertical nudge: fraction of the stage height,
          // positive = up (screen space is y-down) — mirrors the
          // native burn-in's placement exactly.
          transform: [{ translateY: -(style.verticalOffsetRatio ?? 0) * stageH }],
        },
      ]}>
      <View
        // Width cap (Jaizon, 2026-11-12): the line box never
        // exceeds maxWidthRatio of the stage — the word row wraps
        // inside it, mirroring the native burn-in's wrap.
        style={[
          styles.lineBox,
          pillStyle,
          {
            maxWidth: width * (style.maxWidthRatio ?? 0.88),
            alignItems,
            alignSelf: alignItems,
            // Static rotation (Graffiti decor): on the line box,
            // outside the animated line unit — the native burn-in
            // rotates the gate layer the same way.
            ...(decor?.rotationDeg ? { transform: [{ rotate: `${decor.rotationDeg}deg` }] } : {}),
          },
        ]}
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
