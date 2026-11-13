import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 4 re-scope, Experimental family, part A
//
// Styles 31–35 (docs/EXTRA-STYLES-2.0.md §17):
//   31 Glitch Reality — 32 Surveillance System — 33 Newspaper Explosion
//   34 VHS Dream — 35 Optical Illusion
//
// LYRIC-ONLY (Jaizon, 2026-11-13 ~10:28 MST): "no styles that take
// up the whole screen just lyrics with cool animations and stuff."
// The video is the star, so every style here is now lyrics with
// cool animation — no full-screen backgrounds, washes, HUDs,
// scan sweeps, tracking bands, scanlines, pattern fields, or
// full-frame displacement. What survives, reinterpreted:
//   Glitch Reality — words glitching on the line only: RGB-split
//     ghost copies per word, seeded jitter, scatter-settle shards.
//   Surveillance System — RETIRED + REPLACED under the same id:
//     the face-box tracker / full HUD is gone (it cannot work as
//     lyrics-only); the replacement is a transcript readout —
//     mono words typed in as sung, the sung word highlighted in
//     HUD colour under a small corner REC tag.
//   Newspaper Explosion — headline words bursting in/out, kicker
//     + lyric-width rule; masthead, paper background, halftone,
//     columns and body copy are gone.
//   VHS Dream — mono words with a cyan ghost copy, wobble and
//     word-level tracking jumps; the full-frame displacement,
//     tracking bands, scanlines and chrome are gone.
//   Optical Illusion — a small shifting pattern BEHIND the words
//     only, sized to the lyric block; the full-frame rings,
//     checker, spiral, waves and triangle fields are gone.
//
// ENGINE LIMITS that shaped this re-scope (verified in
// ExtraStylesCompositor.swift): a displacement node distorts the
// WHOLE composed frame (video included) — there is no per-node /
// text-only displacement, so Glitch and VHS lose their
// displacement waves entirely; the wave is faked with word-level
// motion instead. Legibility: every lyric node gets a dark
// outline stroke (no blur/glow property exists), except the
// Newspaper headline, whose dark ink gets a paper-white outline.
//
// Flags match the authoritative TS static map
// (src/lib/extra-styles/catalog.ts STYLE_CAPABILITY_MAP) — the
// coordinator updates that map for the one flag change here:
// surveillance-system needsSubjectMasks true → FALSE (no face
// boxes, no subject tint, no tracking group remain).

// MARK: - Shared helpers (this file only)

/// Dark outline every light lyric node gets, so words read over any footage.
private let experimentalInkOutline = ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.07, a: 1)

/// Light outline for dark-ink lyrics (Newspaper headline).
private let experimentalPaperOutline = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)

/// Return a copy of a text node with an outline stroke applied.
/// `extraStyleWordNodes` / `extraStyleCharNodes` take no stroke
/// argument, so strokes on helper-built nodes go through here.
private func experimentalStroked(
  _ node: ExtraStyleNode, color: ExtraStyleRGBA, width: CGFloat
) -> ExtraStyleNode {
  var copy = node
  copy.text?.strokeColor = color
  copy.text?.strokeWidthPoints = width
  return copy
}

/// Seeded position jitter keyframes: one key every `stepFrames`
/// frames, values in [-amplitude, +amplitude]. Deterministic.
private func experimentalJitterKeys(
  start: Int, end: Int, stepFrames: Int, amplitude: Double, seed: UInt64
) -> [ExtraStyleKeyframe] {
  var random = ExtraStyleSeededRandom(seed: seed)
  var keys: [ExtraStyleKeyframe] = []
  var frame = start
  while frame <= end {
    keys.append(ExtraStyleKeyframe(
      frame: frame, value: random.nextRange(min: -amplitude, max: amplitude),
      easing: .linear))
    frame += max(1, stepFrames)
  }
  if keys.isEmpty {
    keys.append(ExtraStyleKeyframe(frame: start, value: 0, easing: .linear))
  }
  return keys
}

// MARK: - Style 31: Glitch Reality (experimental)

/// Words glitching on the lyric line only: seeded jitter, an
/// RGB-split ghost copy per word (accent + magenta, screen blend,
/// flickering), and — in shards/both modes — words scattering in
/// from a seeded offset and settling onto the line, then
/// scattering out again. No background, no full-frame
/// displacement wave (displacement distorts the whole composed
/// frame, video included — there is no text-only displacement),
/// no full-width glitch bands, no centre starburst.
final class GlitchRealityExtraStyle: ExtraStyleDefinition {
  let id = "glitch-reality"
  let version = 1
  let name = "Glitch Reality"
  let tagline = "The words glitch, split and rebuild on the accent."
  let category = "experimental"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "glitchIntensity", label: "Glitch intensity", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "motion"
      ),
      extraStyleSegmentedParam(
        id: "breakMode", label: "Break apart",
        options: [("bands", "Bands"), ("shards", "Shards"), ("both", "Both")],
        default: "both", affects: "layout"
      ),
      extraStyleColorParam(id: "accent", label: "Glitch colour", default: "#00F0FF", affects: "appearance"),
      extraStyleToggleParam(id: "onsetBreak", label: "Break on the accent", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "subtle", "label": "Subtle", "values": ["glitchIntensity": 0.35, "breakMode": "bands"]],
      ["id": "total", "label": "Total breakdown", "values": ["glitchIntensity": 1, "breakMode": "both"]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  var rebuildParamIds: [String] { ["glitchIntensity", "breakMode"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let intensity = extraStyleParamDouble(input.params, "glitchIntensity", 0.7)
    let breakMode = extraStyleParamString(input.params, "breakMode", "both")
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#00F0FF"))
    let magenta = ExtraStyleRGBA(r: 1, g: 0.18, b: 0.39, a: 1)
    let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    let useShards = breakMode != "bands"
    let useJitter = breakMode != "shards"
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centerY = canvas.height * 0.5
      let sizePoints = canvas.width * 0.075
      let emphasis = Set(line.emphasisWordIndices)

      // Measured centred layout, one node per word.
      let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
      let widths = line.words.map { extraStyleTextWidth($0.text, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints) }
      let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, line.words.count - 1))
      var cursorX = (canvas.width - totalWidth) / 2

      // Fallback when the line has no word timings: the whole
      // line glitches as one unit.
      if line.words.isEmpty {
        builder.add(extraStyleTextNode(
          id: "glitch-line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: warmWhite,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: experimentalInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: experimentalJitterKeys(
                start: lineStartFrame, end: lineEndFrame, stepFrames: 5,
                amplitude: 10 * intensity, seed: input.seed ^ UInt64(lineIndex + 1))),
              startFrame: lineStartFrame
            ),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .onset, base: 1, gain: 0.08),
              startFrame: lineStartFrame,
              enabledParamId: "onsetBreak"
            ),
          ]
        ))
        continue
      }

      for (wordIndex, word) in line.words.enumerated() {
        let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
        let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
        let (startFrame, endFrame): (Int, Int) = wordEndFrame > wordStartFrame
          ? (wordStartFrame, wordEndFrame)
          : (min(lineEndFrame, lineStartFrame + wordIndex * 3), lineEndFrame)
        guard endFrame > startFrame else {
          cursorX += widths[wordIndex] + spaceWidth
          continue
        }
        let wordCenterX = cursorX + widths[wordIndex] / 2
        let isEmphasis = emphasis.contains(wordIndex)
        var shardRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 1000 + wordIndex * 17 + 3))
        let angle = shardRandom.nextDouble() * 2 * Double.pi
        let scatterDistance = shardRandom.nextRange(min: 40, max: 140) * intensity * (isEmphasis ? 1.5 : 1)
        let dx = cos(angle) * scatterDistance
        let dy = sin(angle) * scatterDistance * 0.6
        let settleFrame = min(endFrame, startFrame + 12)
        let scatterFrame = max(startFrame, endFrame - 12)

        var tracks: [ExtraStyleTrack] = []
        if useShards {
          // Scatter in, settle on the line, hold, scatter out.
          // Jitter (bands mode) is baked into the middle keys
          // when breakMode is "both", so each axis keeps ONE
          // keyframe track.
          let midJitterX = useJitter ? shardRandom.nextRange(min: -8, max: 8) * intensity : 0
          let midJitterY = useJitter ? shardRandom.nextRange(min: -5, max: 5) * intensity : 0
          tracks.append(ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: startFrame, value: dx, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(endFrame, startFrame + 6), value: dx * 0.3 + midJitterX, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: scatterFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: endFrame, value: dx * 0.7, easing: .easeInCubic),
            ]),
            startFrame: startFrame
          ))
          tracks.append(ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: startFrame, value: dy, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(endFrame, startFrame + 6), value: dy * 0.3 + midJitterY, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: scatterFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: endFrame, value: dy * 0.7, easing: .easeInCubic),
            ]),
            startFrame: startFrame
          ))
          tracks.append(extraStyleSpringInTrack(start: startFrame, from: 0.5, stiffness: 200, damping: 10))
        } else {
          // Bands mode: the word stays on the line and jitters
          // in seeded slices, with a small onset pop.
          tracks.append(ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: experimentalJitterKeys(
              start: startFrame, end: endFrame, stepFrames: 4,
              amplitude: 12 * intensity,
              seed: input.seed ^ UInt64(lineIndex * 31 + wordIndex * 7 + 101))),
            startFrame: startFrame
          ))
          tracks.append(ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.08),
            startFrame: startFrame,
            enabledParamId: "onsetBreak"
          ))
        }
        tracks.append(extraStyleEnterExitOpacityTrack(start: startFrame, end: endFrame, enterFrames: 4, exitFrames: 4))
        builder.add(extraStyleTextNode(
          id: "word-\(lineIndex)-\(wordIndex)",
          text: word.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: isEmphasis ? accent : warmWhite,
          position: CGPoint(x: wordCenterX, y: centerY),
          zIndex: 10, visibleRange: startFrame...endFrame,
          strokeColor: experimentalInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: tracks
        ))

        // RGB-split ghost copies: the same word twice, small
        // seeded offsets, screen blend, flickering — the glitch
        // identity, attached to the word, never the frame.
        for ghost in 0..<2 {
          var ghostRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 31 + wordIndex * 7 + ghost * 13 + 11))
          let gx = ghostRandom.nextRange(min: -14, max: 14) * intensity
          let gy = ghostRandom.nextRange(min: -8, max: 8) * intensity
          let ghostColor = ghost == 0 ? accent.withAlpha(0.6) : magenta.withAlpha(0.6)
          builder.add(ExtraStyleNode(
            id: "glitch-ghost-\(lineIndex)-\(wordIndex)-\(ghost)", kind: .text,
            position: CGPoint(x: wordCenterX + CGFloat(gx), y: centerY + CGFloat(gy)),
            anchor: CGPoint(x: 0.5, y: 0.5),
            opacity: 0.6,
            zIndex: 11,
            blendMode: .screen,
            visibleRange: startFrame...endFrame,
            text: ExtraStyleTextContent(
              text: word.text,
              fontPostScriptName: ExtraStyleFonts.black,
              sizePoints: sizePoints,
              color: ghostColor,
              colorParamId: ghost == 0 ? "accent" : nil,
              strokeColor: nil,
              strokeWidthPoints: 0,
              alignment: .center,
              maxWidthPoints: nil
            ),
            tracks: [
              extraStyleFlickerTrack(
                start: startFrame, end: endFrame, base: 0.6, amplitude: 0.4,
                seed: input.seed ^ UInt64(lineIndex * 31 + wordIndex * 7 + ghost * 13 + 202), stepFrames: 3),
            ]
          ))
        }
        cursorX += widths[wordIndex] + spaceWidth
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 32: Surveillance System (experimental)
//
// RETIRED + REPLACED under the same id (lyric-only re-scope,
// 2026-11-13). The old style — face-box tracking group, lock
// ring, subject tint, scan sweep, REC/timestamp/transcript HUD —
// cannot work as lyrics-only: it WAS a full-screen HUD, and its
// subject masks are gone (needsSubjectMasks is now FALSE; the
// coordinator updates the TS capability map). The replacement
// keeps the surveillance flavour as typography: the lyrics read
// like a transcript — mono words typed in as sung, the sung word
// highlighted in HUD colour under a small corner REC tag.
final class SurveillanceSystemExtraStyle: ExtraStyleDefinition {
  let id = "surveillance-system"
  let version = 1
  let name = "Surveillance System"
  let tagline = "The lyrics, logged like a transcript — the sung word is highlighted."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "hudColor", label: "HUD colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleToggleParam(id: "karaoke", label: "Highlight sung word", default: true, affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "stealth", "label": "Stealth", "values": ["hudColor": "#C9F36B"]],
      ["id": "alert", "label": "Alert", "values": ["hudColor": "#FF5C5C"]],
    ]
  }

  var inputs: [String] { ["lines", "words"] }

  var rebuildParamIds: [String] { [] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let hud = extraStyleColor(extraStyleParamString(input.params, "hudColor", "#7DF9FF"))
    let karaoke = extraStyleParamBool(input.params, "karaoke", true)
    let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    var builder = ExtraStyleSceneBuilder()

    // Small corner tag only — the one surviving piece of HUD chrome.
    builder.add(extraStyleTextNode(
      id: "surv-rec",
      text: "● REC  CAM 01", font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.03,
      color: hud,
      position: CGPoint(x: canvas.width * 0.12, y: canvas.height * 0.055),
      zIndex: 20,
      colorParamId: "hudColor"
    ))

    let sizePoints = canvas.width * 0.058
    let centerY = canvas.height * 0.5
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      guard !line.words.isEmpty else {
        builder.add(extraStyleTextNode(
          id: "surv-line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
          color: warmWhite,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: experimentalInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
        ))
        continue
      }
      // Transcript words: measured centred layout; each word
      // springs in at its sung start (type-on feel). With
      // karaoke on, the sung word is HUD-coloured with a
      // highlight bar behind it; other words are warm white.
      // (Word nodes exist only inside their sung window, so the
      // highlight IS the current word — there is no colour-track
      // highlight on text nodes in the engine.)
      let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.mono, sizePoints: sizePoints)
      let widths = line.words.map { extraStyleTextWidth($0.text, fontPostScriptName: ExtraStyleFonts.mono, sizePoints: sizePoints) }
      let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, line.words.count - 1))
      var cursorX = (canvas.width - totalWidth) / 2
      for (wordIndex, word) in line.words.enumerated() {
        let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
        let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
        let (startFrame, endFrame): (Int, Int) = wordEndFrame > wordStartFrame
          ? (wordStartFrame, wordEndFrame)
          : (min(lineEndFrame, lineStartFrame + wordIndex * 3), lineEndFrame)
        guard endFrame > startFrame else {
          cursorX += widths[wordIndex] + spaceWidth
          continue
        }
        let wordCenterX = cursorX + widths[wordIndex] / 2
        if karaoke {
          builder.add(extraStyleShapeNode(
            id: "surv-highlight-\(lineIndex)-\(wordIndex)",
            shape: extraStyleRectShape(width: widths[wordIndex] + 18, height: sizePoints * 1.3),
            fill: hud.withAlpha(0.22),
            position: CGPoint(x: wordCenterX, y: centerY),
            zIndex: 9,
            visibleRange: startFrame...endFrame,
            fillColorParamId: "hudColor"
          ))
        }
        builder.add(extraStyleTextNode(
          id: "surv-word-\(lineIndex)-\(wordIndex)",
          text: word.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
          color: karaoke ? hud : warmWhite,
          position: CGPoint(x: wordCenterX, y: centerY),
          zIndex: 10, visibleRange: startFrame...endFrame,
          strokeColor: experimentalInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [
            extraStyleSpringInTrack(start: startFrame, from: 0.4, stiffness: 200, damping: 11),
            extraStyleEnterExitOpacityTrack(start: startFrame, end: endFrame, enterFrames: 3, exitFrames: 4),
          ]
        ))
        cursorX += widths[wordIndex] + spaceWidth
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 33: Newspaper Explosion (experimental)

/// Headline words bursting in from a seeded scatter and
/// scattering out again, with a kicker above and a lyric-width
/// rule below. No paper background, no halftone, no masthead,
/// no dateline, no column blocks, no body-copy duplicate.
/// Emphasis words print in the kicker red. The dark ink gets a
/// paper-white outline so it reads over any footage.
final class NewspaperExplosionExtraStyle: ExtraStyleDefinition {
  let id = "newspaper-explosion"
  let version = 1
  let name = "Newspaper Explosion"
  let tagline = "Hot off the press — the headline bursts in, word by word."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "headlineScale", label: "Headline scale", min: 0.8, max: 1.6, step: 0.05,
        default: 1.1, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "scatter", label: "Scatter", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "motion"
      ),
      extraStyleColorParam(id: "inkColor", label: "Ink colour", default: "#101114", affects: "appearance"),
      extraStyleToggleParam(id: "showRules", label: "Rule lines", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "broadsheet", "label": "Broadsheet", "values": ["scatter": 0.5, "headlineScale": 1.2]],
      ["id": "tabloid", "label": "Tabloid", "values": ["scatter": 1, "headlineScale": 1.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["scatter"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let scatter = extraStyleParamDouble(input.params, "scatter", 0.7)
    let ink = extraStyleColor(extraStyleParamString(input.params, "inkColor", "#101114"))
    let showRules = extraStyleParamBool(input.params, "showRules", true)
    let red = ExtraStyleRGBA(r: 0.75, g: 0.22, b: 0.17, a: 1)
    var builder = ExtraStyleSceneBuilder()

    let rulePath = CGMutablePath()
    rulePath.move(to: CGPoint(x: 0, y: 0))
    rulePath.addLine(to: CGPoint(x: canvas.width * 0.88, y: 0))

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let headlineY = canvas.height * 0.3
      let emphasis = Set(line.emphasisWordIndices)

      // Kicker above the headline.
      builder.add(extraStyleTextNode(
        id: "news-kicker-\(lineIndex)",
        text: "★ BREAKING ★", font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
        color: red,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.2),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          extraStyleSpringInTrack(start: lineStartFrame, from: 0.4),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
        ]
      ))

      // Headline = per-word nodes: each word springs in from a
      // seeded radial scatter, holds, then scatters out at the
      // line end — the explosion. Emphasis words print red.
      let headlineWords = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: headlineY, sizePoints: canvas.width * 0.07,
        color: ink, font: ExtraStyleFonts.serif, zIndex: 11,
        canvasWidth: canvas.width,
        colorParamId: "inkColor"
      ) { index, wordStartFrame, wordEndFrame in
        var wordRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 1000 + index * 19 + 5))
        let angle = wordRandom.nextDouble() * 2 * Double.pi
        let distance = wordRandom.nextRange(min: 60, max: 220) * scatter
        let dx = cos(angle) * distance
        let dy = sin(angle) * distance * 0.6
        let settleFrame = min(wordEndFrame, wordStartFrame + 14)
        let scatterFrame = max(wordStartFrame, wordEndFrame - 14)
        return [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: dx, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: scatterFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: wordEndFrame, value: dx, easing: .easeInCubic),
            ]),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: dy, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: scatterFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: wordEndFrame, value: dy, easing: .easeInCubic),
            ]),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.5, to: 1, stiffness: 160, damping: 11, initialVelocity: 0),
            startFrame: wordStartFrame,
            paramScale: "headlineScale"
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 5), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: wordEndFrame, value: 0, easing: .linear),
            ]),
            startFrame: wordStartFrame
          ),
        ]
      }
      // Words come back in word order: outline them all in paper
      // white (dark ink over video) and print emphasis words red.
      for (wordIndex, wordNode) in headlineWords.enumerated() {
        var node = experimentalStroked(wordNode, color: experimentalPaperOutline, width: max(2, canvas.width * 0.07 * 0.05))
        if emphasis.contains(wordIndex) {
          node.text?.color = red
          node.text?.colorParamId = nil
        }
        builder.add(node)
      }

      // Rule under the headline (lyric-width only).
      if showRules {
        builder.add(ExtraStyleNode(
          id: "news-rule-\(lineIndex)", kind: .path,
          position: CGPoint(x: canvas.width * 0.06, y: canvas.height * 0.38),
          anchor: .zero, zIndex: 10,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: rulePath, strokeColor: ink, strokeWidth: 2, dash: nil)
        ))
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 34: VHS Dream (experimental)

/// Retro mono words with a cyan ghost copy offset (chromatic
/// aberration), a slow wobble, and word-level tracking jumps and
/// flicker. No dark wash, no full-frame displacement (displacement
/// distorts the whole composed frame, video included — there is
/// no text-only displacement), no full-width tracking bands, no
/// scanlines, no PLAY/TRACKING chrome, no tape timestamp.
/// `distortion` now drives the wobble amplitude and ghost offset;
/// `trackingAmount` drives the word-level jumps. Emphasis words
/// print cyan.
final class VHSDreamExtraStyle: ExtraStyleDefinition {
  let id = "vhs-dream"
  let version = 1
  let name = "VHS Dream"
  let tagline = "Retro type with tracking errors and a cyan ghost — on the words only."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "trackingAmount", label: "Tracking errors", min: 0, max: 1, step: 0.05,
        default: 0.6, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "distortion", label: "Analog distortion", min: 0, max: 1, step: 0.05,
        default: 0.5, affects: "motion"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "clean-tape", "label": "Clean tape", "values": ["trackingAmount": 0.2, "distortion": 0.2]],
      ["id": "worn-out", "label": "Worn out", "values": ["trackingAmount": 1, "distortion": 1]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["trackingAmount", "distortion"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let trackingAmount = extraStyleParamDouble(input.params, "trackingAmount", 0.6)
    let distortion = extraStyleParamDouble(input.params, "distortion", 0.5)
    let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    let cyan = ExtraStyleRGBA(r: 0.49, g: 0.98, b: 1, a: 1)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centerY = canvas.height * 0.5
      let sizePoints = canvas.width * 0.06
      let emphasis = Set(line.emphasisWordIndices)
      // Wobble amplitude follows the distortion param.
      let wobble = 3 + 5 * distortion
      let ghostOffset = CGFloat(2 + 4 * distortion)

      // Measured centred layout, one node per word.
      let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.mono, sizePoints: sizePoints)
      let widths = line.words.map { extraStyleTextWidth($0.text, fontPostScriptName: ExtraStyleFonts.mono, sizePoints: sizePoints) }
      let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, line.words.count - 1))
      var cursorX = (canvas.width - totalWidth) / 2

      guard !line.words.isEmpty else {
        builder.add(extraStyleTextNode(
          id: "vhs-line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
          color: warmWhite,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: experimentalInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
        ))
        continue
      }

      for (wordIndex, word) in line.words.enumerated() {
        let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
        let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
        let (startFrame, endFrame): (Int, Int) = wordEndFrame > wordStartFrame
          ? (wordStartFrame, wordEndFrame)
          : (min(lineEndFrame, lineStartFrame + wordIndex * 3), lineEndFrame)
        guard endFrame > startFrame else {
          cursorX += widths[wordIndex] + spaceWidth
          continue
        }
        let wordCenterX = cursorX + widths[wordIndex] / 2
        let isEmphasis = emphasis.contains(wordIndex)
        // Tracking-error jumps for this word: mostly 0, sometimes
        // a seeded vertical jump — word-level, never full-width.
        var jumpKeys: [ExtraStyleKeyframe] = []
        var jumpRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 1000 + wordIndex * 29 + 97))
        var frame = startFrame
        while frame <= endFrame {
          let value: Double = jumpRandom.nextDouble() < 0.65
            ? 0
            : jumpRandom.nextRange(min: -18, max: 18) * trackingAmount
          jumpKeys.append(ExtraStyleKeyframe(frame: frame, value: value, easing: .linear))
          frame += 9
        }
        if jumpKeys.isEmpty {
          jumpKeys.append(ExtraStyleKeyframe(frame: startFrame, value: 0, easing: .linear))
        }
        let wobbleTrack = ExtraStyleTrack(
          property: .positionX,
          kind: .loop(periodFrames: 120, periodParamId: nil, keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 30, value: wobble, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 60, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 90, value: -wobble, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 120, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: startFrame
        )
        // Cyan ghost copy (chromatic aberration), offset by the
        // distortion amount, flickering faintly.
        builder.add(ExtraStyleNode(
          id: "vhs-ghost-\(lineIndex)-\(wordIndex)", kind: .text,
          position: CGPoint(x: wordCenterX + ghostOffset, y: centerY + 2),
          anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 9,
          blendMode: .screen,
          visibleRange: startFrame...endFrame,
          text: ExtraStyleTextContent(
            text: word.text,
            fontPostScriptName: ExtraStyleFonts.mono,
            sizePoints: sizePoints,
            color: cyan.withAlpha(0.5),
            strokeColor: nil,
            strokeWidthPoints: 0,
            alignment: .center,
            maxWidthPoints: nil
          ),
          tracks: [
            extraStyleEnterExitOpacityTrack(start: startFrame, end: endFrame, enterFrames: 4, exitFrames: 4),
            wobbleTrack,
          ]
        ))
        builder.add(extraStyleTextNode(
          id: "vhs-word-\(lineIndex)-\(wordIndex)",
          text: word.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
          color: isEmphasis ? cyan : warmWhite,
          position: CGPoint(x: wordCenterX, y: centerY),
          zIndex: 10, visibleRange: startFrame...endFrame,
          strokeColor: experimentalInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [
            extraStyleEnterExitOpacityTrack(start: startFrame, end: endFrame, enterFrames: 4, exitFrames: 4),
            wobbleTrack,
            ExtraStyleTrack(property: .positionY, kind: .keyframes(keys: jumpKeys), startFrame: startFrame),
            extraStyleFlickerTrack(
              start: startFrame, end: endFrame, base: 0.92, amplitude: 0.08 * trackingAmount + 0.02,
              seed: input.seed ^ UInt64(lineIndex * 1000 + wordIndex * 13 + 151), stepFrames: 5),
          ]
        ))
        cursorX += widths[wordIndex] + spaceWidth
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 35: Optical Illusion (experimental)

/// A small shifting pattern lives BEHIND the words only, sized
/// to the lyric block — no background, no full-frame ring/square/
/// checker/spiral/wave fields, no impossible triangle, no
/// perspective-warped text group. Per line, one pattern group
/// (rings / checker / spiral / waves, rotating slowly) fills
/// exactly the lyric block's rect; the words drift in phase with
/// it on a shared 240-frame period, spring in word by word, and
/// emphasis words take the accent colour.
final class OpticalIllusionExtraStyle: ExtraStyleDefinition {
  let id = "optical-illusion"
  let version = 1
  let name = "Optical Illusion"
  let tagline = "A shifting pattern lives behind the words — sized to the line, never the frame."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "patternSpeed", label: "Pattern speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleSegmentedParam(
        id: "patternStyle", label: "Pattern",
        options: [
          ("rings", "Rings"), ("checker", "Checker"),
          ("spiral", "Spiral"), ("waves", "Waves"),
        ],
        default: "rings", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "illusionIntensity", label: "Illusion strength", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C9F36B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "hypnotic", "label": "Hypnotic", "values": ["patternStyle": "spiral", "patternSpeed": 0.6, "illusionIntensity": 1]],
      ["id": "subtle", "label": "Subtle", "values": ["patternStyle": "rings", "patternSpeed": 1, "illusionIntensity": 0.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["patternStyle", "illusionIntensity"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let patternStyle = extraStyleParamString(input.params, "patternStyle", "rings")
    let intensity = extraStyleParamDouble(input.params, "illusionIntensity", 0.7)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    // The shared loop period (240 frames at speed 1): the pattern
    // group AND the words read this same period, so the text moves
    // in phase with the pattern.
    let period = 240
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.07
      let textCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.55)
      let emphasis = Set(line.emphasisWordIndices)

      // Lyric block size, measured from the words (or the whole
      // line when there are no word timings) — the pattern fills
      // exactly this rect, plus a little air.
      let blockWidth: CGFloat = {
        if line.words.isEmpty {
          return extraStyleTextWidth(line.text, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints) + 64
        }
        let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
        let widths = line.words.map { extraStyleTextWidth($0.text, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints) }
        return widths.reduce(0, +) + spaceWidth * CGFloat(max(0, line.words.count - 1)) + 64
      }()
      let blockHeight = sizePoints * 2.4
      let blockLeft = textCenter.x - blockWidth / 2
      let blockTop = textCenter.y - blockHeight / 2

      // Pattern group, centred on the lyric block, rotating
      // slowly on the shared period.
      var patternMembers: [String] = []
      switch patternStyle {
      case "checker":
        let cell: CGFloat = 28
        let columns = max(1, Int(blockWidth / cell))
        let rows = max(1, Int(blockHeight / cell))
        for row in 0..<rows {
          for column in 0..<columns {
            let cellId = "opt-checker-\(lineIndex)-\(row)-\(column)"
            let isAccent = (row + column) % 2 == 0
            builder.addChild(extraStyleShapeNode(
              id: cellId,
              shape: extraStyleRectShape(width: cell, height: cell),
              fill: isAccent ? accent.withAlpha(0.25 * CGFloat(intensity) + 0.05) : warmWhite.withAlpha(0.1),
              position: CGPoint(
                x: blockLeft + CGFloat(column) * cell + cell / 2 - textCenter.x,
                y: blockTop + CGFloat(row) * cell + cell / 2 - textCenter.y),
              zIndex: 0
            ))
            patternMembers.append(cellId)
          }
        }
      case "spiral":
        for step in 0..<5 {
          let diameter = blockWidth * (0.9 - CGFloat(step) * 0.14)
          let spiralId = "opt-spiral-\(lineIndex)-\(step)"
          builder.addChild(extraStyleShapeNode(
            id: spiralId,
            shape: extraStyleEllipseShape(width: diameter, height: blockHeight * (0.9 - CGFloat(step) * 0.12)),
            fill: nil,
            stroke: step % 2 == 0 ? accent.withAlpha(0.7) : warmWhite.withAlpha(0.5),
            strokeWidth: 2,
            position: CGPoint(x: CGFloat(step) * 6, y: CGFloat(step) * 6),
            zIndex: 0
          ))
          patternMembers.append(spiralId)
        }
      case "waves":
        for wave in 0..<2 {
          let phase = Double(wave) * .pi / 2
          let wavePath = CGMutablePath()
          var x: CGFloat = 0
          var first = true
          while x <= blockWidth {
            let y = sin(Double(x) / Double(blockWidth) * .pi * 4 + phase) * blockHeight * 0.18
            if first { wavePath.move(to: CGPoint(x: x, y: y)); first = false }
            else { wavePath.addLine(to: CGPoint(x: x, y: y)) }
            x += 24
          }
          let waveId = "opt-wave-\(lineIndex)-\(wave)"
          let waveStroke: ExtraStyleRGBA = wave % 2 == 0 ? accent.withAlpha(0.8) : warmWhite.withAlpha(0.5)
          let waveContent = ExtraStylePathContent(
            path: wavePath,
            strokeColor: waveStroke,
            strokeWidth: 2, dash: nil)
          let wavePosition = CGPoint(
            x: -blockWidth / 2,
            y: (CGFloat(wave) - 0.5) * blockHeight * 0.3)
          let waveNode = ExtraStyleNode(
            id: waveId, kind: .path,
            position: wavePosition,
            anchor: .zero, zIndex: 0,
            path: waveContent
          )
          builder.addChild(waveNode)
          patternMembers.append(waveId)
        }
      default: // "rings"
        for ring in 0..<3 {
          let ringId = "opt-ring-\(lineIndex)-\(ring)"
          builder.addChild(extraStyleShapeNode(
            id: ringId,
            shape: extraStyleEllipseShape(
              width: blockWidth * (0.95 - CGFloat(ring) * 0.22),
              height: blockHeight * (0.95 - CGFloat(ring) * 0.22)),
            fill: nil,
            stroke: ring % 2 == 0 ? accent.withAlpha(0.7) : warmWhite.withAlpha(0.5),
            strokeWidth: 2,
            position: .zero, zIndex: 0
          ))
          patternMembers.append(ringId)
        }
      }
      builder.add(ExtraStyleNode(
        id: "opt-pattern-\(lineIndex)", kind: .group,
        children: patternMembers,
        position: textCenter, anchor: .zero,
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: period, value: 360, easing: .linear),
            ]),
            startFrame: lineStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
        ]
      ))

      // Words drifting in phase with the pattern, springing in
      // word by word. Emphasis words take the accent colour.
      let phaseX = { (startFrame: Int) in
        ExtraStyleTrack(
          property: .positionX,
          kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: period / 4, value: 14 * intensity, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: period / 2, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: period * 3 / 4, value: -14 * intensity, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: period, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: startFrame
        )
      }
      let phaseY = { (startFrame: Int) in
        ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: period / 4, value: -10 * intensity, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: period / 2, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: period * 3 / 4, value: 10 * intensity, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: period, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: startFrame
        )
      }
      if line.words.isEmpty {
        builder.add(extraStyleTextNode(
          id: "opt-line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: warmWhite,
          position: textCenter,
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: experimentalInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
            phaseX(lineStartFrame), phaseY(lineStartFrame),
          ]
        ))
        continue
      }
      let wordNodes = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: textCenter.y, sizePoints: sizePoints, color: warmWhite,
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { _, wordStartFrame, wordEndFrame in
        [
          extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
          extraStyleSpringInTrack(start: wordStartFrame, from: 0.4, stiffness: 180, damping: 11),
          phaseX(wordStartFrame), phaseY(wordStartFrame),
        ]
      }
      // Words come back in word order: outline them all and tint
      // emphasis words in accent.
      for (wordIndex, wordNode) in wordNodes.enumerated() {
        var node = experimentalStroked(wordNode, color: experimentalInkOutline, width: max(2, sizePoints * 0.05))
        if emphasis.contains(wordIndex) {
          node.text?.color = accent
        }
        builder.add(node)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (Experimental A)

extension ExtraStylesPhase3 {
  static func registerExperimentalA(into registry: ExtraStyleRegistry) {
    registry.register(GlitchRealityExtraStyle())
    registry.register(SurveillanceSystemExtraStyle())
    registry.register(NewspaperExplosionExtraStyle())
    registry.register(VHSDreamExtraStyle())
    registry.register(OpticalIllusionExtraStyle())
  }
}
