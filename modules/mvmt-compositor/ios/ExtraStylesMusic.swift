import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3: Music-Driven family (§17 #26–30)
//
// All five styles declare needsAudioAutomation = true, matching
// src/lib/extra-styles/catalog.ts (STYLE_CAPABILITY_MAP), which is
// authoritative: the UI prepares automation from the live catalog
// and prepareScene throws when a required input is missing, so the
// static spec and the runtime truth must agree. Automation is
// therefore always supplied at build time; the only fallback any
// style here needs is Rhythm Typography's low-confidence beat
// grid (beatPhase(at:) returns nil when beatConfidence < 0.5 —
// that style falls back to the onset envelope, decided at build
// time from the supplied confidence).
//
// Shared evaluator facts these builders rely on (verified in
// ExtraStylesCompositor.swift — resolveNode / trackValue):
//   - positionX/Y tracks are OFFSETS; scale tracks are ABSOLUTE
//     factors (× base); opacity tracks are ABSOLUTE (× base).
//   - a reaction track evaluates to base + gain × reaction.
//   - paramScale multiplies the WHOLE evaluated value, so it is
//     safe on opacity tracks (0...1 magnitudes) but NOT on scale
//     reaction tracks with base 1 (it would shrink the node to
//     the param's fraction). Scale sensitivity is therefore baked
//     into the gain at build time and the param is listed in
//     rebuildParamIds, so a slider drag rebuilds the scene.
//   - a .path track works ONLY on .positionX and REPLACES the
//     node's position with the absolute path point (positionY
//     offsets are ignored while a path track is present).
//   - an emitter's rate cannot be driven by a reaction track
//     (rate reads only rateParamId); density following audio is
//     expressed with layered emitters whose OPACITY tracks are
//     audio reactions (see Frequency Universe / Audio Energy World).

// MARK: - Shared music helpers (file-private)

/// Warm white — the lyric colour used across the family.
private let musicWarmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)

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

// MARK: - #26 Soundwave Typography (music)

/// Text deformed along a waveform path, with a waveform line.
/// The style IS audio-reactive: per-word vertical wobble and
/// stretch are keyed to band energies and the onset envelope.
///
/// Approach note: the evaluator cannot modulate a baked path's
/// amplitude per frame, so the waveform is baked as THREE
/// amplitude variants (0.5× / 1× / 1.6×) whose opacities are
/// loudness reactions — the visible wave grows with the song's
/// energy. The words themselves sit on the 1× wave (base y from
/// the sine at each word's centre x) and wobble on top via
/// per-word .band reaction tracks.
final class SoundwaveTypographyExtraStyle: ExtraStyleDefinition {
  let id = "soundwave-typography"
  let version = 1
  let name = "Soundwave Typography"
  let tagline = "Lyrics ride the waveform — every word bends with the sound."
  let category = "music"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "waveAmplitude", label: "Wave height", min: 10, max: 120, step: 2,
        default: 48, affects: "layout"
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
      extraStyleToggleParam(id: "showWaveform", label: "Show waveform", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "calm", "label": "Calm", "values": ["waveAmplitude": 24, "distort": 0.4]],
      ["id": "wild", "label": "Wild", "values": ["waveAmplitude": 90, "distort": 1.3]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  /// Wave geometry and the baked distortion gains are structural.
  var rebuildParamIds: [String] { ["waveAmplitude", "waveCycles", "distort", "showWaveform"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let amplitude = CGFloat(extraStyleParamDouble(input.params, "waveAmplitude", 48))
    let cycles = Double(extraStyleParamString(input.params, "waveCycles", "3")) ?? 3
    let distort = extraStyleParamDouble(input.params, "distort", 0.8)
    let showWaveform = extraStyleParamBool(input.params, "showWaveform", true)
    let waveColor = extraStyleColor(extraStyleParamString(input.params, "waveColor", "#7DF9FF"))
    let bandCount = musicBandCount(input)
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.04, g: 0.06, b: 0.10, a: 1),
        ExtraStyleRGBA(r: 0.01, g: 0.02, b: 0.03, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    let centerY = canvas.height * 0.5
    var waveRandom = ExtraStyleSeededRandom(seed: input.seed ^ 0x5357_4156_0001)
    let phase = waveRandom.nextDouble() * .pi * 2
    func waveY(at x: CGFloat, amplitudeScale: CGFloat = 1) -> CGFloat {
      centerY
        + sin(CGFloat(cycles) * .pi * 2 * x / canvas.width + CGFloat(phase))
        * amplitude * amplitudeScale
    }
    func wavePoints(amplitudeScale: CGFloat) -> [CGPoint] {
      var points: [CGPoint] = []
      var x: CGFloat = 0
      while x <= canvas.width {
        points.append(CGPoint(x: x, y: waveY(at: x, amplitudeScale: amplitudeScale)))
        x += 12
      }
      points.append(CGPoint(x: canvas.width, y: waveY(at: canvas.width, amplitudeScale: amplitudeScale)))
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
      // fades in as loudness rises, so the wave appears to grow
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

      // A glow dot travelling the 1× wave over the whole scene.
      // .path tracks work only on .positionX and give absolute
      // canvas points — the dot's base position is irrelevant.
      builder.add(ExtraStyleNode(
        id: "wave-dot", kind: .shape,
        position: .zero, anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 3,
        shape: ExtraStyleShapeContent(
          shape: extraStyleEllipseShape(width: 22, height: 22),
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

    let sizePoints = canvas.width * 0.062
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let words = line.words
      guard !words.isEmpty else {
        // No word timings: one centred line node riding the wave
        // as a whole, wobbling on the lowest band.
        builder.add(extraStyleTextNode(
          id: "line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: musicWarmWhite,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
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
      // Measured centred layout, one node per word, each sitting
      // on the wave at its own centre x.
      let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
      let widths = words.map { extraStyleTextWidth($0.text, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints) }
      let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, words.count - 1))
      var cursorX = (canvas.width - totalWidth) / 2
      for (wordIndex, word) in words.enumerated() {
        let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
        let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
        guard wordEndFrame > wordStartFrame else {
          cursorX += widths[wordIndex] + spaceWidth
          continue
        }
        let wordCenterX = cursorX + widths[wordIndex] / 2
        let bandIndex = wordIndex % bandCount
        builder.add(extraStyleTextNode(
          id: "word-\(lineIndex)-\(wordIndex)",
          text: word.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: musicWarmWhite,
          position: CGPoint(x: wordCenterX, y: waveY(at: wordCenterX)),
          zIndex: 10, visibleRange: wordStartFrame...wordEndFrame,
          tracks: [
            extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
            ExtraStyleTrack(
              property: .positionY,
              kind: .reaction(input: .band(index: bandIndex), base: 0, gain: 26 * distort),
              startFrame: wordStartFrame
            ),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .onset, base: 1, gain: 0.18 * distort),
              startFrame: wordStartFrame
            ),
          ]
        ))
        cursorX += widths[wordIndex] + spaceWidth
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - #27 Beat Reactor (music)

/// Text + graphic accents (rings, flashes) firing on the beat
/// grid. Pulses are .beatPhase reaction tracks (1 right after a
/// beat, decaying to 0 by the next), so text and rings breathe
/// with the grid; downbeats get a ring burst and a line transition.
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
  let tagline = "Every beat lands — text and light fire on the grid."
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
      extraStyleToggleParam(id: "flash", label: "Beat flash", default: true, affects: "motion"),
      extraStyleToggleParam(id: "rings", label: "Downbeat rings", default: true, affects: "motion"),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#FF5C8A", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "club", "label": "Club", "values": ["pulseStrength": 0.5, "flash": true]],
      ["id": "subtle", "label": "Subtle", "values": ["pulseStrength": 0.15, "flash": false]],
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

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.10, g: 0.03, b: 0.07, a: 1),
        ExtraStyleRGBA(r: 0.02, g: 0.01, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Full-frame beat flash: bright right after each beat, decayed
    // by the next. Disabled via enabledParamId — a disabled
    // reaction track contributes its base (0), so the flash
    // vanishes instead of freezing.
    builder.add(ExtraStyleNode(
      id: "flash", kind: .shape,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 2,
      blendMode: .screen,
      shape: ExtraStyleShapeContent(
        shape: extraStyleRectShape(width: canvas.width, height: canvas.height),
        fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
        stroke: nil, strokeWidth: 0
      ),
      tracks: [
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .beatPhase, base: 0, gain: 0.35),
          startFrame: 0,
          enabledParamId: "flash"
        ),
      ]
    ))

    // A persistent reactor ring around the lyric zone, pulsing
    // with the beat phase.
    let ringCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.44)
    builder.add(ExtraStyleNode(
      id: "reactor-ring", kind: .shape,
      position: ringCenter, anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 3,
      shape: ExtraStyleShapeContent(
        shape: extraStyleEllipseShape(width: canvas.width * 0.62, height: canvas.width * 0.62),
        fill: nil,
        stroke: accent.withAlpha(0.7),
        strokeWidth: 5
      ),
      tracks: [
        ExtraStyleTrack(
          property: .scale,
          kind: .reaction(input: .beatPhase, base: 1, gain: 0.9 * pulseStrength),
          startFrame: 0
        ),
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .beatPhase, base: 0.55, gain: 0.45),
          startFrame: 0
        ),
      ]
    ))

    // Downbeat ring bursts: one expanding, fading ring per
    // downbeat across the scene (capped so a long song cannot
    // flood the scene with nodes).
    if let automation = input.automation {
      let downbeats = automation.beats.filter { $0.isDownbeat }
      for (ringIndex, beat) in downbeats.prefix(48).enumerated() {
        let startFrame = Int((beat.timeSeconds * fps).rounded())
        let endFrame = min(input.durationFrames, startFrame + 30)
        guard endFrame > startFrame else { continue }
        builder.add(ExtraStyleNode(
          id: "downbeat-ring-\(ringIndex)", kind: .shape,
          position: ringCenter, anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 4,
          visibleRange: startFrame...endFrame,
          shape: ExtraStyleShapeContent(
            shape: extraStyleEllipseShape(width: canvas.width * 0.5, height: canvas.width * 0.5),
            fill: nil,
            stroke: accent,
            strokeWidth: 6
          ),
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: startFrame, value: 0.4, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: endFrame, value: 1.9, easing: .easeOutCubic),
              ]),
              startFrame: startFrame
            ),
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: startFrame, value: 0.9, easing: .linear),
                ExtraStyleKeyframe(frame: endFrame, value: 0, easing: .linear),
              ]),
              startFrame: startFrame,
              enabledParamId: "rings"
            ),
          ]
        ))
      }
    }

    func startsOnDownbeat(_ line: ExtraStyleInputLine) -> Bool {
      guard let automation = input.automation else { return false }
      return automation.beats.contains {
        $0.isDownbeat && abs($0.timeSeconds - line.startSeconds) < 0.25
      }
    }

    let sizePoints = canvas.width * 0.07
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centerY = canvas.height * 0.44

      // Downbeat transition: a starburst fires when a line starts
      // on a downbeat.
      if startsOnDownbeat(line) {
        let burstSize = canvas.width * 0.34
        builder.add(ExtraStyleNode(
          id: "downbeat-burst-\(lineIndex)", kind: .shape,
          position: CGPoint(x: canvas.width / 2, y: centerY - canvas.width * 0.3),
          anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 9,
          visibleRange: lineStartFrame...min(lineEndFrame, lineStartFrame + 24),
          shape: ExtraStyleShapeContent(
            shape: extraStyleStarShape(outerRadius: burstSize / 2, innerRadius: burstSize / 4, spikes: 8),
            fill: accent,
            fillColorParamId: "accent",
            stroke: nil, strokeWidth: 0
          ),
          tracks: [
            extraStyleSpringInTrack(start: lineStartFrame, from: 0.2, stiffness: 220, damping: 9),
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame, value: 1, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 24), value: 0, easing: .linear),
              ]),
              startFrame: lineStartFrame
            ),
          ]
        ))
      }

      if line.words.isEmpty {
        builder.add(extraStyleTextNode(
          id: "line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: musicWarmWhite,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
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
      // Per-word nodes: each word pulses on the beat grid.
      let wordNodes = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints, color: musicWarmWhite,
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { _, wordStartFrame, wordEndFrame in
        [
          extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .beatPhase, base: 1, gain: 0.9 * pulseStrength),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.12),
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

/// Frequency-band bars, spectral particles, and glow. One bar
/// shape node per band follows its band energy; particles rise
/// with the bass; a glow flashes with the treble.
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
  let tagline = "The spectrum, alive — bars, bass dust, and treble fire."
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
      extraStyleToggleParam(id: "glow", label: "Treble glow", default: true, affects: "appearance"),
      extraStyleToggleParam(id: "particles", label: "Spectral particles", default: true, affects: "motion"),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C9F36B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "club", "label": "Club", "values": ["sensitivity": 1.5]],
      ["id": "calm", "label": "Calm", "values": ["sensitivity": 0.6, "glow": false]],
    ]
  }

  var inputs: [String] { ["lines", "audio"] }

  /// The sensitivity is baked into the band gains at build time.
  var rebuildParamIds: [String] { ["sensitivity"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let sensitivity = extraStyleParamDouble(input.params, "sensitivity", 1)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    let bandCount = musicBandCount(input)
    let bandCenters = input.automation?.bandCentersHz ?? []
    let topBandIndex = max(0, bandCount - 1)
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.03, g: 0.04, b: 0.10, a: 1),
        ExtraStyleRGBA(r: 0.01, g: 0.01, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Treble glow: a radial wash in the upper frame, flashing
    // with the highest band. Disabled → base 0.05, near-invisible.
    builder.add(ExtraStyleNode(
      id: "treble-glow", kind: .gradient,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 1,
      gradient: ExtraStyleGradientContent(
        kind: .radial(
          center: CGPoint(x: canvas.width / 2, y: canvas.height * 0.25),
          radius: max(canvas.width, canvas.height) * 0.55
        ),
        colors: [accent.withAlpha(0.45), accent.withAlpha(0)],
        colorParamIds: ["accent", "accent"],
        locations: [0, 1],
        rect: CGRect(origin: .zero, size: canvas)
      ),
      tracks: [
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .band(index: topBandIndex), base: 0.05, gain: 0.85),
          startFrame: 0,
          enabledParamId: "glow"
        ),
      ]
    ))

    // Bass particles: rise from the bar baseline with the lowest
    // band. The emitter rate is fixed — the bass drives the
    // node's opacity, so the dust appears and vanishes with it.
    builder.add(ExtraStyleNode(
      id: "bass-particles", kind: .particles,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      zIndex: 4,
      emitter: ExtraStyleEmitterContent(
        rate: 45,
        lifetimeSeconds: 3.5,
        origin: CGPoint(x: 0.5, y: 0.82),
        velocity: CGVector(dx: 0, dy: -0.14),
        spread: CGVector(dx: 0.25, dy: 0.03),
        gravity: -0.01,
        size: 0.018,
        sizeSpread: 0.01,
        opacityFrom: 0.9,
        opacityTo: 0,
        color: accent,
        colorParamId: "accent",
        spriteKind: .softCircle
      ),
      tracks: [
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .band(index: 0), base: 0.05, gain: 0.95),
          startFrame: 0,
          enabledParamId: "particles"
        ),
      ]
    ))

    // Treble sparkles: fine dust drifting down from the top,
    // driven by the highest band.
    builder.add(ExtraStyleNode(
      id: "treble-particles", kind: .particles,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      zIndex: 4,
      emitter: ExtraStyleEmitterContent(
        rate: 30,
        lifetimeSeconds: 2.5,
        origin: CGPoint(x: 0.5, y: 0.25),
        velocity: CGVector(dx: 0, dy: 0.03),
        spread: CGVector(dx: 0.3, dy: 0.02),
        gravity: 0.005,
        size: 0.012,
        sizeSpread: 0.006,
        opacityFrom: 0.9,
        opacityTo: 0,
        color: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
        spriteKind: .softCircle
      ),
      tracks: [
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .band(index: topBandIndex), base: 0, gain: 1),
          startFrame: 0,
          enabledParamId: "particles"
        ),
      ]
    ))

    // The spectrum bars: one per band, base pinned to the
    // baseline, height following its band energy.
    let barAreaWidth = canvas.width * 0.86
    let barAreaLeft = (canvas.width - barAreaWidth) / 2
    let slotWidth = barAreaWidth / CGFloat(bandCount)
    let barWidth = slotWidth * 0.6
    let maxBarHeight = canvas.height * 0.30
    let baselineY = canvas.height * 0.80
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
      // Centre-frequency label under the bar, when known.
      if bandIndex < bandCenters.count {
        builder.add(extraStyleTextNode(
          id: "bar-label-\(bandIndex)",
          text: "\(Int(bandCenters[bandIndex]))",
          font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.022,
          color: musicWarmWhite.withAlpha(0.55),
          position: CGPoint(x: x, y: baselineY + 26),
          zIndex: 5
        ))
      }
    }
    // Baseline rule the bars stand on.
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

    // The lyric line above the spectrum, popping on onsets.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.black, sizePoints: canvas.width * 0.06,
        color: musicWarmWhite,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.42),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.12),
            startFrame: lineStartFrame
          ),
        ]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - #29 Rhythm Typography (music)

/// Per-word / per-syllable nodes: each syllable gets its own
/// rhythmic animation (bounce / stretch / pop), and phrase
/// transitions ride the beat phase.
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

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.09, g: 0.08, b: 0.03, a: 1),
        ExtraStyleRGBA(r: 0.03, g: 0.03, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    let sizePoints = canvas.width * 0.065
    let centerY = canvas.height * 0.48
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }

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
        builder.add(extraStyleTextNode(
          id: "line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: musicWarmWhite,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
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
          color: musicWarmWhite,
          position: CGPoint(x: cursorX + syllable.width / 2, y: centerY),
          zIndex: 10, visibleRange: syllable.startFrame...lineEndFrame,
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

/// Full-scene intensity driver: every node reads one energy
/// value — the loudness curve. Density, speed, glow, and scale
/// all follow it, so the whole composition is the visualizer.
///
/// The loudness reaction maps LUFS-like dB (~-60..0) to 0...1
/// inside the evaluator; every track here is a .loudness
/// reaction with its own base/gain. Emitter density cannot be
/// driven by a reaction directly (rate reads only rateParamId),
/// so three layered emitters (sparse / medium / dense) fade in
/// at different loudness levels instead.
final class AudioEnergyWorldExtraStyle: ExtraStyleDefinition {
  let id = "audio-energy-world"
  let version = 1
  let name = "Audio Energy World"
  let tagline = "The whole scene breathes with the song's energy."
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
      extraStyleSliderParam(
        id: "glow", label: "Glow", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "appearance"
      ),
      extraStyleToggleParam(id: "warp", label: "Energy warp", default: true, affects: "motion"),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C9F36B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "supernova", "label": "Supernova", "values": ["intensity": 1.6, "glow": 1]],
      ["id": "ember", "label": "Ember", "values": ["intensity": 0.6, "glow": 0.4]],
    ]
  }

  var inputs: [String] { ["lines", "audio"] }

  /// Intensity is baked into the loudness gains at build time;
  /// the warp node is structural (present or absent).
  var rebuildParamIds: [String] { ["intensity", "warp"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let intensity = extraStyleParamDouble(input.params, "intensity", 1)
    let warp = extraStyleParamBool(input.params, "warp", true)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.07, g: 0.08, b: 0.05, a: 1),
        ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Global glow wash: the loudness curve, scaled by the glow
    // param (paramScale is safe here — an opacity magnitude).
    builder.add(ExtraStyleNode(
      id: "glow", kind: .gradient,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 1,
      gradient: ExtraStyleGradientContent(
        kind: .radial(
          center: CGPoint(x: canvas.width / 2, y: canvas.height * 0.44),
          radius: max(canvas.width, canvas.height) * 0.6
        ),
        colors: [accent.withAlpha(0.5), accent.withAlpha(0)],
        colorParamIds: ["accent", "accent"],
        locations: [0, 1],
        rect: CGRect(origin: .zero, size: canvas)
      ),
      tracks: [
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .loudness, base: 0.08, gain: 0.85),
          startFrame: 0,
          paramScale: "glow"
        ),
      ]
    ))

    // The energy warp: the whole frame ripples with loudness.
    // Displacement scale here follows the Metal spike's range
    // (baseScale ~20); the loudness reaction re-times it.
    if warp {
      builder.add(ExtraStyleNode(
        id: "warp", kind: .displacement,
        displacement: ExtraStyleDisplacementContent(baseScale: 12, frequency: 3),
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .loudness, base: 8, gain: 20 * intensity),
            startFrame: 0
          ),
        ]
      ))
    }

    // Layered particle density: sparse is always faintly alive,
    // medium and dense fade in as loudness rises.
    let particleLayers: [(id: String, rate: Double, size: Double, base: Double, gain: Double, color: ExtraStyleRGBA, colorParamId: String?)] = [
      ("energy-particles-sparse", 8, 0.02, 0.5, 0.5, accent, "accent"),
      ("energy-particles-mid", 25, 0.016, 0.1, 0.9, musicWarmWhite, nil),
      ("energy-particles-dense", 60, 0.012, 0.0, 1.0, accent, "accent"),
    ]
    for layer in particleLayers {
      builder.add(ExtraStyleNode(
        id: layer.id, kind: .particles,
        position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
        zIndex: 2,
        emitter: ExtraStyleEmitterContent(
          rate: layer.rate,
          lifetimeSeconds: 4,
          origin: CGPoint(x: 0.5, y: 0.44),
          velocity: CGVector(dx: 0, dy: -0.06),
          spread: CGVector(dx: 0.3, dy: 0.08),
          gravity: -0.005,
          size: layer.size,
          sizeSpread: 0.008,
          opacityFrom: 0.85,
          opacityTo: 0,
          color: layer.color,
          colorParamId: layer.colorParamId,
          spriteKind: .softCircle
        ),
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .reaction(input: .loudness, base: layer.base, gain: layer.gain),
            startFrame: 0
          ),
        ]
      ))
    }

    // The energy core: a pulsing disc at the scene's heart.
    let coreCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.44)
    builder.add(ExtraStyleNode(
      id: "core", kind: .shape,
      position: coreCenter, anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 3,
      blendMode: .screen,
      shape: ExtraStyleShapeContent(
        shape: extraStyleEllipseShape(width: canvas.width * 0.24, height: canvas.width * 0.24),
        fill: accent,
        fillColorParamId: "accent",
        stroke: nil, strokeWidth: 0
      ),
      tracks: [
        ExtraStyleTrack(
          property: .scale,
          kind: .reaction(input: .loudness, base: 0.75, gain: 0.6 * intensity),
          startFrame: 0
        ),
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .loudness, base: 0.5, gain: 0.5),
          startFrame: 0
        ),
      ]
    ))

    // Two halo rings breathing at different loudness gains.
    let rings: [(id: String, diameter: CGFloat, base: Double, gain: Double)] = [
      ("halo-1", canvas.width * 0.42, 0.9, 0.5),
      ("halo-2", canvas.width * 0.58, 0.85, 0.65),
    ]
    for ring in rings {
      builder.add(ExtraStyleNode(
        id: ring.id, kind: .shape,
        position: coreCenter, anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 3,
        shape: ExtraStyleShapeContent(
          shape: extraStyleEllipseShape(width: ring.diameter, height: ring.diameter),
          fill: nil,
          stroke: accent.withAlpha(0.6),
          strokeWidth: 4
        ),
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .loudness, base: ring.base, gain: ring.gain * intensity),
            startFrame: 0
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .reaction(input: .loudness, base: 0.25, gain: 0.6),
            startFrame: 0
          ),
        ]
      ))
    }

    // The energy bar: a loudness meter pinned to the left edge.
    // Anchor (0, 0.5) pins its left end; uniform scale grows its
    // short height too, but only from ~1 pt to 10 pt.
    builder.add(ExtraStyleNode(
      id: "energy-bar", kind: .shape,
      position: CGPoint(x: canvas.width * 0.15, y: canvas.height * 0.86),
      anchor: CGPoint(x: 0, y: 0.5),
      zIndex: 4,
      shape: ExtraStyleShapeContent(
        shape: extraStyleRectShape(width: canvas.width * 0.7, height: 10),
        fill: accent,
        fillColorParamId: "accent",
        stroke: nil, strokeWidth: 0
      ),
      tracks: [
        ExtraStyleTrack(
          property: .scale,
          kind: .reaction(input: .loudness, base: 0.06, gain: 0.94 * intensity),
          startFrame: 0
        ),
      ]
    ))

    // Lyrics: every line scales and brightens with the same
    // loudness curve that drives the rest of the scene.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.black, sizePoints: canvas.width * 0.058,
        color: musicWarmWhite,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.66),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
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
