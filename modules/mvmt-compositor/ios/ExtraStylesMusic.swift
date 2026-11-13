import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 4 re-scope: Music-Driven family (§17 #26–30)
//
// LYRIC-ONLY (Jaizon, 2026-11-13 ~10:28 MST): "no styles that take
// up the whole screen just lyrics with cool animations and stuff."
// The video is the star, so every style here is now lyrics with
// audio-reactive animation — no full-screen background gradients,
// no full-frame washes, flashes, rings, particle fields, or bars.
// What survives, reinterpreted as typography:
//   Soundwave — words above a SMALL waveform strip under the line
//     (the 3 baked amplitude variants crossfaded by loudness —
//     the engine cannot modulate a baked path's amplitude per
//     frame, so the strip stays small instead of full-frame).
//   Beat Reactor — words popping on the beat grid, downbeat words
//     in the accent colour, one small beat bar under the line.
//   Frequency Universe — a TINY spectrum strip under the lyric
//     line (one small bar per band), lyrics above it.
//   Rhythm Typography — syllables bouncing/stretching/popping on
//     the beat (was already lyric-only; background removed).
//   Audio Energy World — the words themselves swelling with
//     loudness, plus a small loudness meter under the line.
//
// Legibility: every lyric node gets a dark outline stroke (the
// engine has no blur/glow property), so words read over any
// footage. Emphasis words (stored lyric intelligence) pop in the
// style's accent colour with a bigger spring.
//
// All five styles keep needsAudioAutomation = true — audio
// reactivity IS lyric animation here. Style IDs are unchanged.

// MARK: - Shared music helpers (file-private)

/// Warm white — the lyric colour used across the family.
private let musicWarmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)

/// Dark outline every lyric node gets, so words read over any footage.
private let musicInkOutline = ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.07, a: 1)

private func musicStrokeWidth(_ sizePoints: CGFloat) -> CGFloat {
  max(2, sizePoints * 0.05)
}

/// Band count for bar-style layouts: the automation's band centres
/// when present, otherwise a fixed 8 (the §17 fallback).
private func musicBandCount(_ input: ExtraStyleBuildInput) -> Int {
  let count = input.automation?.bandCentersHz.count ?? 0
  guard count > 0 else { return 8 }
  return min(count, 12)
}

/// Vowel-group syllable split — a DETERMINISTIC HEURISTIC, documented
/// as approximate, never phonetic (§17 #29): a word is split at the
/// start of each vowel group (a run of a-e-i-o-u); leading consonants
/// attach to the first syllable, trailing consonants to the last. A
/// word with no vowel group is one syllable. Same word → same split,
/// in preview and export.
private func musicSyllables(of word: String) -> [String] {
  let vowels = Set("aeiouAEIOU")
  let chars = Array(word)
  guard !chars.isEmpty else { return [] }
  var starts: [Int] = []
  for i in chars.indices where vowels.contains(chars[i]) {
    if i == 0 || !vowels.contains(chars[i - 1]) { starts.append(i) }
  }
  guard !starts.isEmpty else { return [word] }
  var chunks: [String] = []
  for (k, s) in starts.enumerated() {
    let e = k + 1 < starts.count ? starts[k + 1] : chars.count
    chunks.append(String(chars[s..<e]))
  }
  if starts[0] > 0 { chunks[0] = String(chars[0..<starts[0]]) + chunks[0] }
  return chunks.filter { !$0.isEmpty }
}

/// Per-word lyric nodes on one centred line, with a dark outline
/// stroke and emphasis words in `emphasisColor` (when set).
/// Words without timings stagger in 3 frames apart, like
/// `extraStyleWordNodes`. The caller supplies the tracks per word:
/// (wordIndex, wordStartFrame, wordEndFrame, isEmphasis).
private func musicWordNodes(
  line: ExtraStyleInputLine, lineIndex: Int, fps: Double,
  lineStartFrame: Int, lineEndFrame: Int,
  y: CGFloat, sizePoints: CGFloat, color: ExtraStyleRGBA,
  emphasisColor: ExtraStyleRGBA?,
  font: String, zIndex: Int, canvasWidth: CGFloat,
  trackBuilder: (Int, Int, Int, Bool) -> [ExtraStyleTrack]
) -> [ExtraStyleNode] {
  let words = line.words
  guard !words.isEmpty else { return [] }
  let emphasis = Set(line.emphasisWordIndices)
  let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
  let widths = words.map { extraStyleTextWidth($0.text, fontPostScriptName: font, sizePoints: sizePoints) }
  let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, words.count - 1))
  var cursorX = (canvasWidth - totalWidth) / 2
  var nodes: [ExtraStyleNode] = []
  for (index, word) in words.enumerated() {
    let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
    let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
    let startFrame = wordEndFrame > wordStartFrame
      ? wordStartFrame : min(lineEndFrame, lineStartFrame + index * 3)
    let endFrame = wordEndFrame > wordStartFrame ? wordEndFrame : lineEndFrame
    guard endFrame > startFrame else {
      cursorX += widths[index] + spaceWidth
      continue
    }
    let isEmphasis = emphasis.contains(index)
    let wordColor = isEmphasis ? (emphasisColor ?? color) : color
    nodes.append(extraStyleTextNode(
      id: "word-\(lineIndex)-\(index)",
      text: word.text, font: font, sizePoints: sizePoints,
      color: wordColor,
      position: CGPoint(x: cursorX + widths[index] / 2, y: y),
      zIndex: zIndex, visibleRange: startFrame...endFrame,
      strokeColor: musicInkOutline, strokeWidthPoints: musicStrokeWidth(sizePoints),
      tracks: trackBuilder(index, startFrame, endFrame, isEmphasis)
    ))
    cursorX += widths[index] + spaceWidth
  }
  return nodes
}

/// Whole-line fallback for lines with no word timings: one centred
/// node with the dark outline stroke.
private func musicLineNode(
  id: String, line: ExtraStyleInputLine,
  lineStartFrame: Int, lineEndFrame: Int,
  y: CGFloat, sizePoints: CGFloat, color: ExtraStyleRGBA,
  font: String, zIndex: Int, canvasWidth: CGFloat,
  tracks: [ExtraStyleTrack]
) -> ExtraStyleNode {
  extraStyleTextNode(
    id: id,
    text: line.text, font: font, sizePoints: sizePoints,
    color: color,
    position: CGPoint(x: canvasWidth / 2, y: y),
    zIndex: zIndex, visibleRange: lineStartFrame...lineEndFrame,
    maxWidthPoints: canvasWidth * 0.88,
    strokeColor: musicInkOutline, strokeWidthPoints: musicStrokeWidth(sizePoints),
    tracks: tracks
  )
}

// MARK: - #26 Soundwave Typography (music)

/// Lyrics above a SMALL waveform strip under the line. The strip
/// is lyric-width (0.82W) and only a few dozen points tall —
///
/// the engine cannot modulate a baked path's amplitude per frame,
/// so the strip is still THREE amplitude variants (0.5× / 1× /
/// 1.6×) crossfaded by loudness, plus a small dot travelling the
/// 1× strip. The words sit on the lyric line itself and wobble
/// per-word on their band energy, with an onset pop; emphasis
/// words take the wave colour.
final class SoundwaveTypographyExtraStyle: ExtraStyleDefinition {
  let id = "soundwave-typography"
  let version = 1
  let name = "Soundwave Typography"
  let tagline = "Lyrics ride a small waveform strip — every word bends with the sound."
  let category = "music"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "waveAmplitude", label: "Wave height", min: 4, max: 48, step: 2,
        default: 18, affects: "layout"
      ),
      extraStyleSegmentedParam(
        id: "waveCycles", label: "Wave cycles",
        options: [("2", "2"), ("3", "3"), ("4", "4")],
        default: "3", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "distort", label: "Distortion", min: 0, max: 1.5, step: 0.05,
        default: 0.8, affects: "motion"
      ),
      extraStyleColorParam(id: "waveColor", label: "Wave colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleToggleParam(id: "showWaveform", label: "Show waveform strip", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "calm", "label": "Calm", "values": ["waveAmplitude": 10, "distort": 0.4]],
      ["id": "wild", "label": "Wild", "values": ["waveAmplitude": 36, "distort": 1.3]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  /// Wave geometry and the baked distortion gains are structural.
  var rebuildParamIds: [String] { ["waveAmplitude", "waveCycles", "distort", "showWaveform"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let amplitude = CGFloat(extraStyleParamDouble(input.params, "waveAmplitude", 18))
    let cycles = Double(extraStyleParamString(input.params, "waveCycles", "3")) ?? 3
    let distort = extraStyleParamDouble(input.params, "distort", 0.8)
    let showWaveform = extraStyleParamBool(input.params, "showWaveform", true)
    let waveColor = extraStyleColor(extraStyleParamString(input.params, "waveColor", "#7DF9FF"))
    let bandCount = musicBandCount(input)
    var builder = ExtraStyleSceneBuilder()

    let centerY = canvas.height * 0.44
    let sizePoints = canvas.width * 0.062
    // The strip: lyric-width, just below the lyric line.
    let stripWidth = canvas.width * 0.82
    let stripLeft = (canvas.width - stripWidth) / 2
    let stripCenterY = centerY + sizePoints * 1.45
    var waveRandom = ExtraStyleSeededRandom(seed: input.seed ^ 0x5357_4156_0001)
    let phase = waveRandom.nextDouble() * .pi * 2
    func waveY(at x: CGFloat, amplitudeScale: CGFloat = 1) -> CGFloat {
      stripCenterY
        + sin(CGFloat(cycles) * .pi * 2 * (x - stripLeft) / stripWidth + CGFloat(phase))
        * amplitude * amplitudeScale
    }
    func wavePoints(amplitudeScale: CGFloat) -> [CGPoint] {
      var points: [CGPoint] = []
      var x = stripLeft
      while x <= stripLeft + stripWidth {
        points.append(CGPoint(x: x, y: waveY(at: x, amplitudeScale: amplitudeScale)))
        x += 12
      }
      points.append(CGPoint(x: stripLeft + stripWidth, y: waveY(at: stripLeft + stripWidth, amplitudeScale: amplitudeScale)))
      return points
    }
    func wavePath(amplitudeScale: CGFloat) -> CGPath {
      let path = CGMutablePath()
      for (index, point) in wavePoints(amplitudeScale: amplitudeScale).enumerated() {
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      return path
    }

    if showWaveform {
      // Three amplitude variants, layered by loudness: the quiet
      // wave is visible when the song is quiet, the tall wave
      // fades in as loudness rises, so the strip appears to grow
      // with the song. Opacity tracks are loudness reactions.
      let variants: [(id: String, scale: CGFloat, base: Double, gain: Double, width: CGFloat, alpha: Double)] = [
        ("wave-low", 0.5, 0.85, -0.7, 3, 0.8),
        ("wave-mid", 1.0, 0.1, 0.75, 3, 0.6),
        ("wave-high", 1.6, 0.0, 1.0, 2, 0.5),
      ]
      for variant in variants {
        builder.add(ExtraStyleNode(
          id: variant.id, kind: .path,
          position: .zero, anchor: .zero, zIndex: 2,
          path: ExtraStylePathContent(
            path: wavePath(amplitudeScale: variant.scale),
            strokeColor: waveColor.withAlpha(CGFloat(variant.alpha)),
            strokeWidth: variant.width,
            dash: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .reaction(input: .loudness, base: variant.base, gain: variant.gain),
              startFrame: 0
            ),
          ]
        ))
      }

      // A small glow dot travelling the 1× strip over the scene.
      // .path tracks work only on .positionX and give absolute
      // canvas points — the dot's base position is irrelevant.
      builder.add(ExtraStyleNode(
        id: "wave-dot", kind: .shape,
        position: .zero, anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 3,
        shape: ExtraStyleShapeContent(
          shape: extraStyleEllipseShape(width: 14, height: 14),
          fill: waveColor,
          stroke: nil, strokeWidth: 0
        ),
        tracks: [
          ExtraStyleTrack(
            property: .positionX,
            kind: .path(points: wavePoints(amplitudeScale: 1), durationFrames: input.durationFrames, easing: .linear),
            startFrame: 0
          ),
        ]
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      guard !line.words.isEmpty else {
        builder.add(musicLineNode(
          id: "line-\(lineIndex)", line: line,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: centerY, sizePoints: sizePoints, color: musicWarmWhite,
          font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width,
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
            ExtraStyleTrack(
              property: .positionY,
              kind: .reaction(input: .band(index: 0), base: 0, gain: 26 * distort),
              startFrame: lineStartFrame
            ),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .onset, base: 1, gain: 0.18 * distort),
              startFrame: lineStartFrame
            ),
          ]
        ))
        continue
      }
      // One node per word on the lyric line, each wobbling on its
      // own band; emphasis words take the wave colour and pop harder.
      let wordNodes = musicWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints, color: musicWarmWhite,
        emphasisColor: waveColor,
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { wordIndex, wordStartFrame, wordEndFrame, isEmphasis in
        let bandIndex = wordIndex % bandCount
        return [
          extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
          ExtraStyleTrack(
            property: .positionY,
            kind: .reaction(input: .band(index: bandIndex), base: 0, gain: 26 * distort),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: (isEmphasis ? 0.3 : 0.18) * distort),
            startFrame: wordStartFrame
          ),
        ]
      }
      for wordNode in wordNodes { builder.add(wordNode) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - #27 Beat Reactor (music)

/// Words popping on the beat grid — no background, no full-frame
/// flash, no reactor ring, no downbeat ring bursts. Each word
/// springs in at its sung start and pulses with the beat phase;
/// words landing on a downbeat (and emphasis words) take the
/// accent colour and pop harder. One small beat bar under the
/// lyric line breathes with the grid.
///
/// beatPhase(at:) returns nil when beatConfidence < 0.5 — the
/// reaction then reads 0 and the pulses sit at their base value
/// (no wrong beat is ever rendered as if it were confident).
/// needsAudioAutomation = true guarantees automation was supplied;
/// confidence can still be low, and the style degrades to a
/// steady, unpulsed render in that case.
final class BeatReactorExtraStyle: ExtraStyleDefinition {
  let id = "beat-reactor"
  let version = 1
  let name = "Beat Reactor"
  let tagline = "Every beat lands — the words pop on the grid."
  let category = "music"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "pulseStrength", label: "Pulse strength", min: 0, max: 0.6, step: 0.05,
        default: 0.3, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#FF5C8A", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "club", "label": "Club", "values": ["pulseStrength": 0.5]],
      ["id": "subtle", "label": "Subtle", "values": ["pulseStrength": 0.15]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  /// The pulse gain is baked into the reaction tracks at build time.
  var rebuildParamIds: [String] { ["pulseStrength"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let pulseStrength = extraStyleParamDouble(input.params, "pulseStrength", 0.3)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FF5C8A"))
    var builder = ExtraStyleSceneBuilder()

    let sizePoints = canvas.width * 0.07
    let centerY = canvas.height * 0.46

    // Small beat bar under the lyric line: it breathes with the
    // beat phase (1 right after a beat, decaying to 0 by the next).
    builder.add(extraStyleShapeNode(
      id: "beat-bar",
      shape: extraStyleRectShape(width: canvas.width * 0.5, height: 6),
      fill: accent,
      position: CGPoint(x: canvas.width / 2, y: centerY + sizePoints * 1.1),
      zIndex: 9,
      fillColorParamId: "accent",
      tracks: [
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .beatPhase, base: 0.35, gain: 0.65),
          startFrame: 0
        ),
        ExtraStyleTrack(
          property: .scale,
          kind: .reaction(input: .beatPhase, base: 0.85, gain: 0.15),
          startFrame: 0
        ),
      ]
    ))

    func startsOnDownbeat(seconds: Double) -> Bool {
      guard let automation = input.automation else { return false }
      return automation.beats.contains {
        $0.isDownbeat && abs($0.timeSeconds - seconds) < 0.25
      }
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      guard !line.words.isEmpty else {
        builder.add(musicLineNode(
          id: "line-\(lineIndex)", line: line,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: centerY, sizePoints: sizePoints, color: musicWarmWhite,
          font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width,
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .beatPhase, base: 1, gain: 0.9 * pulseStrength),
              startFrame: lineStartFrame
            ),
          ]
        ))
        continue
      }
      // Per-word nodes: each word springs in and pulses on the
      // beat grid; downbeat and emphasis words pop harder in accent.
      let wordNodes = musicWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints, color: musicWarmWhite,
        emphasisColor: accent,
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { wordIndex, wordStartFrame, wordEndFrame, isEmphasis in
        let wordSeconds = line.words[wordIndex].startSeconds
        let isDownbeat = startsOnDownbeat(seconds: wordSeconds)
        let hot = isEmphasis || isDownbeat
        return [
          extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
          extraStyleSpringInTrack(
            start: wordStartFrame, from: hot ? 0.2 : 0.5,
            stiffness: 220, damping: 9
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .beatPhase, base: 1, gain: (hot ? 1.4 : 0.9) * pulseStrength),
            startFrame: wordStartFrame
          ),
        ]
      }
      for wordNode in wordNodes { builder.add(wordNode) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - #28 Frequency Universe (music)

/// A TINY spectrum strip under the lyric line — no background, no
/// treble glow wash, no particle fields, no full-width bar field.
/// One small bar per band, base pinned to a lyric-width baseline,
/// height following its band energy; the lyric line sits above
/// the strip and pops on onsets, emphasis words in accent.
///
/// Bars use a scale reaction on .band(index). Scale is uniform,
/// so a bar also widens as it grows — the bars are kept narrow
/// and the gain modest so the width breathing reads as part of
/// the meter, and the anchor (0.5, 1.0) pins each bar's base to
/// the baseline so it grows upward only.
final class FrequencyUniverseExtraStyle: ExtraStyleDefinition {
  let id = "frequency-universe"
  let version = 1
  let name = "Frequency Universe"
  let tagline = "A tiny spectrum strip under the lyrics, alive with the song."
  let category = "music"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "sensitivity", label: "Sensitivity", min: 0.3, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C9F36B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "club", "label": "Club", "values": ["sensitivity": 1.5]],
      ["id": "calm", "label": "Calm", "values": ["sensitivity": 0.6]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  /// The sensitivity is baked into the band gains at build time.
  var rebuildParamIds: [String] { ["sensitivity"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let sensitivity = extraStyleParamDouble(input.params, "sensitivity", 1)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    let bandCount = musicBandCount(input)
    var builder = ExtraStyleSceneBuilder()

    // The mini spectrum: lyric-width, just below the lyric line.
    let lineY = canvas.height * 0.42
    let sizePoints = canvas.width * 0.06
    let barAreaWidth = canvas.width * 0.8
    let barAreaLeft = (canvas.width - barAreaWidth) / 2
    let slotWidth = barAreaWidth / CGFloat(bandCount)
    let barWidth = slotWidth * 0.6
    let maxBarHeight = canvas.height * 0.09
    let baselineY = lineY + sizePoints * 1.5 + maxBarHeight
    for bandIndex in 0..<bandCount {
      let x = barAreaLeft + (CGFloat(bandIndex) + 0.5) * slotWidth
      builder.add(ExtraStyleNode(
        id: "bar-\(bandIndex)", kind: .shape,
        position: CGPoint(x: x, y: baselineY),
        anchor: CGPoint(x: 0.5, y: 1.0),
        zIndex: 5,
        shape: ExtraStyleShapeContent(
          shape: extraStyleRectShape(width: barWidth, height: maxBarHeight),
          fill: accent,
          fillColorParamId: "accent",
          stroke: nil, strokeWidth: 0
        ),
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .band(index: bandIndex), base: 0.12, gain: 0.88 * sensitivity),
            startFrame: 0
          ),
        ]
      ))
    }
    // Baseline rule the bars stand on (lyric-width only).
    builder.add(ExtraStyleNode(
      id: "baseline", kind: .path,
      position: .zero, anchor: .zero, zIndex: 5,
      path: ExtraStylePathContent(
        path: {
          let path = CGMutablePath()
          path.move(to: CGPoint(x: barAreaLeft, y: baselineY))
          path.addLine(to: CGPoint(x: barAreaLeft + barAreaWidth, y: baselineY))
          return path
        }(),
        strokeColor: musicWarmWhite.withAlpha(0.35),
        strokeWidth: 2,
        dash: nil
      )
    ))

    // The lyric line above the strip, popping on onsets.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      guard !line.words.isEmpty else {
        builder.add(musicLineNode(
          id: "line-\(lineIndex)", line: line,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: lineY, sizePoints: sizePoints, color: musicWarmWhite,
          font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width,
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .onset, base: 1, gain: 0.12),
              startFrame: lineStartFrame
            ),
          ]
        ))
        continue
      }
      let wordNodes = musicWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: lineY, sizePoints: sizePoints, color: musicWarmWhite,
        emphasisColor: accent,
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { _, wordStartFrame, wordEndFrame, isEmphasis in
        [
          extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
          extraStyleSpringInTrack(start: wordStartFrame, from: isEmphasis ? 0.2 : 0.5, stiffness: 200, damping: 10),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: isEmphasis ? 0.2 : 0.12),
            startFrame: wordStartFrame
          ),
        ]
      }
      for wordNode in wordNodes { builder.add(wordNode) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - #29 Rhythm Typography (music)

/// Per-word / per-syllable nodes: each syllable gets its own
/// rhythmic animation (bounce / stretch / pop), and phrase
/// transitions ride the beat phase. This style was already
/// lyric-only — the re-scope removes only its full-screen
/// background gradient. Syllables now also get the dark outline
/// stroke, and syllables of emphasis words take the accent colour.
///
/// Syllables come from musicSyllables(of:) — the vowel-group
/// heuristic, APPROXIMATE by design (see that function's comment);
/// it is never claimed to be phonetic. Automation is always
/// supplied (needsAudioAutomation = true); the build-time choice
/// is only which reaction input pulses the syllables: .beatPhase
/// when beatConfidence >= 0.5, the onset envelope otherwise.
final class RhythmTypographyExtraStyle: ExtraStyleDefinition {
  let id = "rhythm-typography"
  let version = 1
  let name = "Rhythm Typography"
  let tagline = "Every syllable dances — bounce, stretch, and pop on the beat."
  let category = "music"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "rhythmStyle", label: "Rhythm",
        options: [("bounce", "Bounce"), ("stretch", "Stretch"), ("pop", "Pop")],
        default: "bounce", affects: "motion"
      ),
      extraStyleSliderParam(
        id: "bounceHeight", label: "Bounce height", min: 8, max: 48, step: 1,
        default: 22, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#FFD93D", affects: "appearance"),
      extraStyleToggleParam(id: "syllablePop", label: "Syllable pop", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "pop", "label": "Pop", "values": ["rhythmStyle": "pop"]],
      ["id": "stretch", "label": "Stretch", "values": ["rhythmStyle": "stretch", "bounceHeight": 12]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  /// The rhythm style and bounce height are baked into the
  /// per-syllable keyframes at build time.
  var rebuildParamIds: [String] { ["rhythmStyle", "bounceHeight"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let rhythmStyle = extraStyleParamString(input.params, "rhythmStyle", "bounce")
    let bounceHeight = extraStyleParamDouble(input.params, "bounceHeight", 22)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FFD93D"))
    // Beat grid when confident; the onset envelope otherwise.
    // Decided here, at build time, from the supplied automation.
    let beatConfident = (input.automation?.beatConfidence ?? 0) >= 0.5
    let pulseInput: ExtraStyleReactionInput = beatConfident ? .beatPhase : .onset
    let pulseGain = beatConfident ? 0.18 : 0.25
    var builder = ExtraStyleSceneBuilder()

    let sizePoints = canvas.width * 0.065
    let centerY = canvas.height * 0.48
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let emphasis = Set(line.emphasisWordIndices)

      // The line's stored emoji rides above the syllables.
      if let hero = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.3),
        sizePoints: canvas.width * 0.09, zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(hero)
      }

      // Phrase accent: an underline bar whose opacity rides the
      // pulse input — the phrase transition marker.
      builder.add(extraStyleShapeNode(
        id: "phrase-bar-\(lineIndex)",
        shape: extraStyleRectShape(width: canvas.width * 0.5, height: 6),
        fill: accent,
        position: CGPoint(x: canvas.width / 2, y: centerY + sizePoints),
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        fillColorParamId: "accent",
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .reaction(input: pulseInput, base: 0.35, gain: 0.65),
            startFrame: lineStartFrame
          ),
        ]
      ))

      guard !line.words.isEmpty else {
        // No word timings: the whole line bounces as one unit.
        builder.add(musicLineNode(
          id: "line-\(lineIndex)", line: line,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: centerY, sizePoints: sizePoints, color: musicWarmWhite,
          font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width,
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
            ExtraStyleTrack(
              property: .positionY,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame, value: -bounceHeight, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 10), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: lineStartFrame
            ),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: pulseInput, base: 1, gain: pulseGain),
              startFrame: lineStartFrame
            ),
          ]
        ))
        continue
      }

      // Syllable layout: split each word (heuristic), split its
      // time span evenly across its syllables, lay everything out
      // on one centred line with measured widths.
      struct Syllable {
        var text: String
        var width: CGFloat
        var startFrame: Int
        var endFrame: Int
        var wordIndex: Int
        var partIndex: Int
      }
      let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
      var syllables: [Syllable] = []
      var totalWidth: CGFloat = 0
      for (wordIndex, word) in line.words.enumerated() {
        let wordStartFrame = max(
          lineStartFrame, Int((word.startSeconds * fps).rounded()))
        let wordEndFrame = min(
          lineEndFrame, Int((word.endSeconds * fps).rounded()))
        let (spanStart, spanEnd): (Int, Int) = wordEndFrame > wordStartFrame
          ? (wordStartFrame, wordEndFrame)
          : (min(lineEndFrame, lineStartFrame + wordIndex * 6),
             min(lineEndFrame, lineStartFrame + (wordIndex + 1) * 6))
        let parts = musicSyllables(of: word.text)
        let span = max(1, spanEnd - spanStart)
        for (partIndex, part) in parts.enumerated() {
          let partStart = spanStart + span * partIndex / parts.count
          let partEnd = partIndex + 1 < parts.count
            ? spanStart + span * (partIndex + 1) / parts.count
            : spanEnd
          guard partEnd > partStart else { continue }
          let width = extraStyleTextWidth(part, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
          syllables.append(Syllable(
            text: part, width: width, startFrame: partStart, endFrame: partEnd,
            wordIndex: wordIndex, partIndex: partIndex
          ))
          totalWidth += width
        }
        if wordIndex + 1 < line.words.count { totalWidth += spaceWidth }
      }
      // One centred pass over the syllables in order. Word gaps
      // are spaces between words, never between a word's own
      // syllables; the gap is added after a word's last kept
      // syllable, so a dropped zero-span part cannot misalign
      // the text that follows it.
      var cursorX = (canvas.width - totalWidth) / 2
      for (syllableIndex, syllable) in syllables.enumerated() {
        let isEmphasis = emphasis.contains(syllable.wordIndex)
        var tracks: [ExtraStyleTrack] = [
          extraStyleEnterExitOpacityTrack(start: syllable.startFrame, end: lineEndFrame, enterFrames: 4, exitFrames: 9),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: pulseInput, base: 1, gain: pulseGain),
            startFrame: syllable.startFrame
          ),
        ]
        switch rhythmStyle {
        case "stretch":
          // Scale is uniform (no independent x/y), so the
          // stretch is a wide-then-settle scale pulse.
          tracks.append(ExtraStyleTrack(
            property: .scale,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: syllable.startFrame, value: 0.75, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEndFrame, syllable.startFrame + 6), value: 1.18, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEndFrame, syllable.startFrame + 14), value: 1, easing: .easeOutCubic),
            ]),
            startFrame: syllable.startFrame
          ))
        case "pop":
          tracks.append(ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 220, damping: 9, initialVelocity: 0),
            startFrame: syllable.startFrame,
            enabledParamId: "syllablePop"
          ))
        default: // bounce
          tracks.append(ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: syllable.startFrame, value: -bounceHeight, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEndFrame, syllable.startFrame + 10), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: syllable.startFrame
          ))
          tracks.append(ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.6, to: 1, stiffness: 180, damping: 11, initialVelocity: 0),
            startFrame: syllable.startFrame,
            enabledParamId: "syllablePop"
          ))
        }
        builder.add(extraStyleTextNode(
          id: "syl-\(lineIndex)-\(syllable.wordIndex)-\(syllable.partIndex)",
          text: syllable.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: isEmphasis ? accent : musicWarmWhite,
          position: CGPoint(x: cursorX + syllable.width / 2, y: centerY),
          zIndex: 10, visibleRange: syllable.startFrame...lineEndFrame,
          strokeColor: musicInkOutline, strokeWidthPoints: musicStrokeWidth(sizePoints),
          tracks: tracks
        ))
        cursorX += syllable.width
        let nextIsNewWord = syllableIndex + 1 >= syllables.count
          || syllables[syllableIndex + 1].wordIndex != syllable.wordIndex
        if nextIsNewWord && syllable.wordIndex + 1 < line.words.count {
          cursorX += spaceWidth
        }
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - #30 Audio Energy World (music)

/// The words themselves are the visualizer — no background, no
/// glow wash, no energy warp, no particle layers, no pulsing
/// core, no halo rings, no full-width energy bar. Every word
/// swells and brightens with the loudness curve; emphasis words
/// swell harder in accent. One small loudness meter sits under
/// the lyric line.
///
/// The loudness reaction maps LUFS-like dB (~-60..0) to 0...1
/// inside the evaluator; every track here is a .loudness
/// reaction with its own base/gain.
///
/// ENGINE LIMIT: the old "energy warp" was a displacement node,
/// and displacement distorts the WHOLE composed frame (video
/// included) — there is no per-node / text-only displacement, so
/// the warp is gone entirely rather than shrunk. The swell is
/// the warp now, on the words only.
final class AudioEnergyWorldExtraStyle: ExtraStyleDefinition {
  let id = "audio-energy-world"
  let version = 1
  let name = "Audio Energy World"
  let tagline = "The words themselves swell and breathe with the song's energy."
  let category = "music"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "intensity", label: "Intensity", min: 0.3, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C9F36B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "supernova", "label": "Supernova", "values": ["intensity": 1.6]],
      ["id": "ember", "label": "Ember", "values": ["intensity": 0.6]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  /// Intensity is baked into the loudness gains at build time.
  var rebuildParamIds: [String] { ["intensity"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let intensity = extraStyleParamDouble(input.params, "intensity", 1)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    var builder = ExtraStyleSceneBuilder()

    let centerY = canvas.height * 0.5
    let sizePoints = canvas.width * 0.058

    // Small loudness meter under the lyric line: uniform scale
    // grows its short height too, but only from ~0.5 pt to 6 pt.
    builder.add(extraStyleShapeNode(
      id: "energy-meter",
      shape: extraStyleRectShape(width: canvas.width * 0.6, height: 6),
      fill: accent,
      position: CGPoint(x: canvas.width / 2, y: centerY + sizePoints * 1.3),
      zIndex: 9,
      fillColorParamId: "accent",
      tracks: [
        ExtraStyleTrack(
          property: .scale,
          kind: .reaction(input: .loudness, base: 0.08, gain: 0.92 * intensity),
          startFrame: 0
        ),
      ]
    ))

    // Lyrics: every word scales and brightens with the same
    // loudness curve.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      guard !line.words.isEmpty else {
        builder.add(musicLineNode(
          id: "line-\(lineIndex)", line: line,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: centerY, sizePoints: sizePoints, color: musicWarmWhite,
          font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width,
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .loudness, base: 0.95, gain: 0.12 * intensity),
              startFrame: lineStartFrame
            ),
            ExtraStyleTrack(
              property: .opacity,
              kind: .reaction(input: .loudness, base: 0.55, gain: 0.45),
              startFrame: lineStartFrame
            ),
          ]
        ))
        continue
      }
      let wordNodes = musicWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints, color: musicWarmWhite,
        emphasisColor: accent,
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { _, wordStartFrame, wordEndFrame, isEmphasis in
        [
          extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
          extraStyleSpringInTrack(start: wordStartFrame, from: isEmphasis ? 0.2 : 0.5, stiffness: 200, damping: 10),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .loudness, base: 0.95, gain: (isEmphasis ? 0.22 : 0.12) * intensity),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .reaction(input: .loudness, base: 0.55, gain: 0.45),
            startFrame: wordStartFrame
          ),
        ]
      }
      for wordNode in wordNodes { builder.add(wordNode) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (Music-Driven family)

extension ExtraStylesPhase3 {
  static func registerMusicRest(into registry: ExtraStyleRegistry) {
    registry.register(SoundwaveTypographyExtraStyle())
    registry.register(BeatReactorExtraStyle())
    registry.register(FrequencyUniverseExtraStyle())
    registry.register(RhythmTypographyExtraStyle())
    registry.register(AudioEnergyWorldExtraStyle())
  }
}
