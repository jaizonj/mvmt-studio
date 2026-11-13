import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 4 re-scope, demos
//
// LYRIC-ONLY (Jaizon, 2026-11-13 ~10:28 MST): "no styles that take
// up the whole screen — just lyrics with cool animations and
// stuff." The video is the star. The five demos are now words on
// the footage: no full-screen background, particle field,
// light-trail, glow wash, panel, HUD, scanline field, or backdrop
// wash. Decor survives only as small accents attached to the
// words. Dream Sequence is registered here (its category is
// cinematic) and nowhere else — do not duplicate it in
// ExtraStylesCinematic.swift.
//
//   - Typography Physics — letters fall, bounce, and settle.
//   - Dream Sequence — soft-fading dreamy words, gentle drift.
//   - Comic Book — bold words that slam in, bursts on emphasis.
//   - Holographic Interface — scanline shimmer + a small chip.
//   - Emoji Storytelling — words + the line's emoji, attached.
//
// API verdict (audit open question #9): the Phase 2 builder API
// survived all five without a change — the only addition is the
// shared helpers in ExtraStyleBuilders.swift, which the demos
// themselves motivated. No engine change was needed. The re-scope
// adds three file-local helpers in ExtraStylesCinematic.swift
// (stroke stamping, word layout, untimed-line fallback) shared by
// both files.

// MARK: - Demo 1: Typography Physics (typography)
//
// LYRIC-ONLY, mostly already there: the letters were always the
// scene. The only change is quality: the char cascade is now
// spread across the line's sung duration (starting at the first
// word's start) instead of a fixed 2-frame stagger from the line
// start, emphasis-word letters pop harder on the beat, and every
// glyph gets a dark legibility outline. The floor line stays — a
// thin accent the letters land on, attached to the words.

final class TypographyPhysicsExtraStyle: ExtraStyleDefinition {
  let id = "typography-physics"
  let version = 1
  let name = "Typography Physics"
  let tagline = "Letters fall, bounce, and settle — gravity you can tune."
  let category = "typography"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "gravity", label: "Gravity",
        options: [("moon", "Moon"), ("earth", "Earth"), ("jupiter", "Jupiter")],
        default: "earth", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "bounce", label: "Bounce", min: 0.2, max: 0.9, step: 0.05,
        default: 0.55, affects: "layout"
      ),
      extraStyleColorParam(id: "accent", label: "Letter colour", default: "#C9F36B", affects: "appearance"),
      extraStyleToggleParam(id: "onsetPop", label: "Pop on the beat", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "gentle", "label": "Gentle", "values": ["gravity": "moon", "bounce": 0.8]],
      ["id": "heavy", "label": "Heavy", "values": ["gravity": "jupiter", "bounce": 0.3]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let gravityMultiplier: Double = {
      switch extraStyleParamString(input.params, "gravity", "earth") {
      case "moon": return 0.5
      case "jupiter": return 1.8
      default: return 1
      }
    }()
    let restitution = extraStyleParamDouble(input.params, "bounce", 0.55)
    // Points per frame²: a ~1500 pt fall settles in ~40 frames at
    // Earth gravity (1.85). The multiplier scales it.
    let gravity = 1.85 * gravityMultiplier
    let floorY = canvas.height * 0.72
    let sizePoints = canvas.width * 0.085
    var builder = ExtraStyleSceneBuilder()

    // A faint floor line the letters land on.
    builder.add(ExtraStyleNode(
      id: "floor",
      kind: .path,
      position: CGPoint(x: canvas.width / 2, y: floorY + sizePoints * 0.7),
      zIndex: 1,
      path: ExtraStylePathContent(
        path: {
          // Positive local space (0 → 0.84W): the anchor math
          // centres it on the node's position.
          let path = CGMutablePath()
          path.move(to: CGPoint(x: 0, y: 0))
          path.addLine(to: CGPoint(x: canvas.width * 0.84, y: 0))
          return path
        }(),
        strokeColor: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 0.25),
        strokeWidth: 2,
        dash: nil
      )
    ))

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // Which word each character belongs to (spaces attach to
      // the following word): emphasis words' letters pop harder.
      var charWordIndex: [Int] = []
      for (wordIndex, word) in line.words.enumerated() {
        if wordIndex > 0 { charWordIndex.append(wordIndex) }
        for _ in word.text { charWordIndex.append(wordIndex) }
      }
      let emphasis = Set(line.emphasisWordIndices)
      // The cascade is tied to the sung line: it starts at the
      // first word's start and spreads across the line's duration
      // instead of a fixed stagger from the line start.
      let firstWordStart = line.words.first.map { max(lineStartFrame, Int(($0.startSeconds * fps).rounded())) } ?? lineStartFrame
      let charDelay = max(1, (lineEndFrame - firstWordStart) / max(1, line.text.count))
      // Per-character fall: each char starts above the canvas at
      // its staggered start, falls under gravity, bounces on the
      // floor, and settles at its reading position. The simulation
      // is baked into keyframes here — the evaluator only
      // interpolates (docs §5.2).
      let chars = extraStyleCharNodes(
        text: line.text, lineIndex: lineIndex,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: floorY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width,
        firstCharStartFrame: firstWordStart, charDelayFrames: charDelay,
        colorParamId: "accent"
      ) { index, charStartFrame, lineEnd in
        let wordIndex = index < charWordIndex.count
          ? charWordIndex[index]
          : max(0, line.words.count - 1)
        let fallKeys = extraStyleFallKeyframes(
          startFrame: charStartFrame,
          startYOffset: -(floorY + sizePoints),
          gravity: gravity, restitution: restitution
        )
        return [
          ExtraStyleTrack(property: .positionY, kind: .keyframes(keys: fallKeys), startFrame: charStartFrame),
          ExtraStyleTrack(property: .opacity, kind: .keyframes(keys: [
            ExtraStyleKeyframe(frame: charStartFrame, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: min(lineEnd, charStartFrame + 4), value: 1, easing: .easeOutCubic),
            ExtraStyleKeyframe(frame: max(charStartFrame, lineEnd - 9), value: 1, easing: .linear),
            ExtraStyleKeyframe(frame: lineEnd, value: 0, easing: .easeInCubic),
          ]), startFrame: charStartFrame),
          ExtraStyleTrack(
            property: .scale,
            // Emphasis letters pop harder on the beat.
            kind: .reaction(input: .onset, base: 1, gain: emphasis.contains(wordIndex) ? 0.28 : 0.12),
            startFrame: charStartFrame,
            enabledParamId: "onsetPop"
          ),
        ]
      }
      for char in extraStyleStrokeTextNodes(chars, sizePoints: sizePoints) { builder.add(char) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Demo 2: Dream Sequence (cinematic)
//
// LYRIC-ONLY: the deep-indigo background, the particle field, the
// light-trail path and its travelling glow dot, and the
// loudness-driven glow wash are all gone — the whole old scene
// was frame furniture. What survives is the dreaminess, as
// typography: soft-fading word-by-word entrances with a gentle
// drift, two faint offset echoes of the line (same reading order,
// never reversed), and the line's emoji small at the end of the
// line. No audio is read any more (the glow was the only
// automation consumer), so needsAudioAutomation drops to false.

final class DreamSequenceExtraStyle: ExtraStyleDefinition {
  let id = "dream-sequence"
  let version = 1
  let name = "Dream Sequence"
  let tagline = "Soft words, drifting and dissolving like a dream."
  let category = "cinematic"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "driftSpeed", label: "Drift speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "hue", label: "Dream colour", default: "#8FA8FF", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "gentle", "label": "Gentle", "values": ["driftSpeed": 0.6]],
      ["id": "intense", "label": "Intense", "values": ["driftSpeed": 1.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    let hue = extraStyleColor(extraStyleParamString(input.params, "hue", "#8FA8FF"))
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = extraStyleFitSize(
        baseSize: canvas.width * 0.07, text: line.text,
        font: ExtraStyleFonts.bold, canvasWidth: canvas.width
      )
      let centerY = canvas.height * 0.5
      let emphasis = Set(line.emphasisWordIndices)
      // Faint offset echoes of the line — the old ghost layers,
      // kept as typography: same reading order, hue-tinted, low
      // alpha, drifting slowly. Never reversed, never a wash.
      builder.add(extraStyleTextNode(
        id: "ghost1-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.regular, sizePoints: sizePoints,
        color: hue.withAlpha(0.22),
        position: CGPoint(x: canvas.width / 2 + 14, y: centerY - 20),
        zIndex: 9, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        colorParamId: "hue",
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 15, exitFrames: 15),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 240, periodParamId: "driftSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 8, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 120, value: -12, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 240, value: 8, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))
      builder.add(extraStyleTextNode(
        id: "ghost2-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.regular, sizePoints: sizePoints * 1.04,
        color: hue.withAlpha(0.1),
        position: CGPoint(x: canvas.width / 2 - 16, y: centerY + 22),
        zIndex: 8, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        colorParamId: "hue",
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 15, exitFrames: 15),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 240, periodParamId: "driftSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: -8, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 120, value: 12, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 240, value: -8, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))
      // The main line, word by word, soft-fading in at each
      // word's sung start and drifting gently while it is up.
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: ExtraStyleFonts.bold, zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStart, wordEnd in
        var tracks: [ExtraStyleTrack] = [
          extraStyleEnterExitOpacityTrack(start: wordStart, end: wordEnd, enterFrames: 15, exitFrames: 15),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 240, periodParamId: "driftSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 120, value: -10, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: wordStart
          ),
        ]
        if emphasis.contains(index) {
          tracks.append(extraStyleSpringInTrack(start: wordStart, from: 0.85, stiffness: 160, damping: 12))
        }
        return tracks
      }
      if words.isEmpty {
        builder.add(extraStyleLyricFallbackNode(
          id: "line-\(lineIndex)", line: line,
          range: lineStartFrame...lineEndFrame,
          y: centerY, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          font: ExtraStyleFonts.bold, zIndex: 10, canvasWidth: canvas.width
        ))
      } else {
        for word in extraStyleStrokeTextNodes(words, sizePoints: sizePoints) { builder.add(word) }
      }
      // The line's emoji, small, at the end of the line (clamped
      // inside the frame — a full-width line leaves no room past
      // its last word).
      let layoutWidth = extraStyleWordLayout(
        words: line.words.map { $0.text }, font: ExtraStyleFonts.bold,
        sizePoints: sizePoints, canvasWidth: canvas.width
      ).totalWidth
      let dreamEmojiSize = sizePoints * 0.8
      if let emoji = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width - dreamEmojiSize * 0.6, canvas.width / 2 + layoutWidth / 2 + sizePoints * 0.9),
          y: centerY - sizePoints * 0.55
        ),
        sizePoints: dreamEmojiSize, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(emoji)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Demo 3: Comic Book (playful)
//
// LYRIC-ONLY, REPLACEMENT CONCEPT UNDER THE SAME ID: the panels
// are gone — the big filled panel behind the text (88% of the
// width, half the frame) was a scene, not lyrics. The replacement
// is the comic energy as typography: big bold words that slam in
// with a spring, emphasis words as impact words (harder slam +
// a small burst behind the word), and short motion rays fanning
// off the burst. The burst asset stays, but only ever behind an
// emphasis word — never a panel corner.

final class ComicBookExtraStyle: ExtraStyleDefinition {
  let id = "comic-book"
  let version = 1
  let name = "Comic Book"
  let tagline = "Big bold words that slam in — POW, right on the beat."
  let category = "playful"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "impactScale", label: "Impact scale", min: 0.5, max: 1.5, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#FFD93D", affects: "appearance"),
      extraStyleToggleParam(id: "motionLines", label: "Motion lines", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "bold-pop", "label": "Bold Pop", "values": ["impactScale": 1.3]],
      ["id": "quiet", "label": "Quiet", "values": ["impactScale": 0.8, "motionLines": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FFD93D"))
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centreY = canvas.height * (lineIndex % 2 == 0 ? 0.44 : 0.56)
      let font = ExtraStyleFonts.black
      let sizePoints = extraStyleFitSize(
        baseSize: canvas.width * 0.07, text: line.text, font: font, canvasWidth: canvas.width
      )
      let emphasis = Set(line.emphasisWordIndices)
      // Impact words: the line's emphasis words (or its first
      // word when none are marked).
      let impactIndices: [Int] = {
        if !emphasis.isEmpty { return emphasis.sorted() }
        return line.words.isEmpty ? [] : [0]
      }()
      let impactSet = Set(impactIndices)
      // Every word slams in with a spring; impact words slam
      // harder, scaled by the impact param.
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centreY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: font, zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStart, wordEnd in
        var tracks: [ExtraStyleTrack] = [
          extraStyleEnterExitOpacityTrack(start: wordStart, end: wordEnd, enterFrames: 6, exitFrames: 9),
        ]
        if impactSet.contains(index) {
          tracks.append(ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 220, damping: 9, initialVelocity: 0),
            startFrame: wordStart,
            paramScale: "impactScale"
          ))
        } else {
          tracks.append(extraStyleSpringInTrack(start: wordStart, from: 0.6, stiffness: 200, damping: 10))
        }
        return tracks
      }
      if words.isEmpty {
        builder.add(extraStyleLyricFallbackNode(
          id: "line-\(lineIndex)", line: line,
          range: lineStartFrame...lineEndFrame,
          y: centreY, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          font: font, zIndex: 10, canvasWidth: canvas.width
        ))
      } else {
        for word in extraStyleStrokeTextNodes(words, sizePoints: sizePoints) { builder.add(word) }
      }
      // Burst + motion rays behind each impact word — small,
      // word-attached, never a panel.
      let layout = extraStyleWordLayout(
        words: line.words.map { $0.text }, font: font,
        sizePoints: sizePoints, canvasWidth: canvas.width
      )
      for wordIndex in impactIndices where wordIndex >= 0 && wordIndex < line.words.count && wordIndex < layout.centres.count {
        let word = line.words[wordIndex]
        let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
        let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
        guard wordEndFrame > wordStartFrame else { continue }
        let burstCentre = CGPoint(x: layout.centres[wordIndex], y: centreY)
        let burstSize = canvas.width * 0.2
        builder.add(ExtraStyleNode(
          id: "burst-\(lineIndex)-\(wordIndex)", kind: .image,
          position: burstCentre,
          anchor: CGPoint(x: 0.5, y: 0.5),
          // The asset is 512×512: scale it to the word.
          scale: burstSize / 512,
          zIndex: 9,
          visibleRange: wordStartFrame...wordEndFrame,
          imageAssetId: "comic-burst",
          tracks: [
            extraStyleSpringInTrack(start: wordStartFrame + 2, from: 0.2, stiffness: 200, damping: 9),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .onset, base: 1, gain: 0.25),
              startFrame: wordStartFrame
            ),
          ]
        ))
        // Motion rays fanning up off the burst. The opacity
        // envelope ends at 0, so the motionLines toggle's end
        // value hides them when off.
        for ray in 0..<3 {
          let angle = -CGFloat.pi / 2 + CGFloat(ray - 1) * 0.5
          let to = CGPoint(
            x: burstCentre.x + cos(angle) * canvas.width * 0.1,
            y: burstCentre.y + sin(angle) * canvas.width * 0.1
          )
          let rayPath = CGMutablePath()
          rayPath.move(to: burstCentre)
          rayPath.addLine(to: to)
          builder.add(ExtraStyleNode(
            id: "ray-\(lineIndex)-\(wordIndex)-\(ray)", kind: .path,
            position: .zero, anchor: .zero,
            zIndex: 9,
            visibleRange: wordStartFrame...wordEndFrame,
            path: ExtraStylePathContent(
              path: rayPath,
              strokeColor: accent.withAlpha(0.9),
              strokeWidth: 4,
              dash: nil
            ),
            tracks: [
              ExtraStyleTrack(
                property: .opacity,
                kind: .keyframes(keys: [
                  ExtraStyleKeyframe(frame: wordStartFrame + ray * 2, value: 0, easing: .linear),
                  ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + ray * 2 + 5), value: 1, easing: .easeOutCubic),
                  ExtraStyleKeyframe(frame: wordEndFrame, value: 0, easing: .linear),
                ]),
                startFrame: wordStartFrame,
                enabledParamId: "motionLines"
              ),
            ]
          ))
        }
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Demo 4: Holographic Interface (digital)
//
// LYRIC-ONLY: the background gradient, the 14 full-width
// scanlines, the full-width travelling scan sweep, the four
// corner brackets and both floating HUD panels are gone — a
// full-screen HUD. What survives is the holo feel on the words:
// mono type with an accent stroke, sliding in word by word,
// floating gently, with a thin scanline shimmer under each word
// (gated by the flicker toggle) and ONE small corner chip
// ("HOLO //") — a label, not a HUD.

final class HolographicInterfaceExtraStyle: ExtraStyleDefinition {
  let id = "holographic-interface"
  let version = 1
  let name = "Holographic Interface"
  let tagline = "Words with a scanline shimmer and a holo chip — nothing else."
  let category = "digital"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "panelColor", label: "Interface colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleToggleParam(id: "flicker", label: "Flicker", default: true, affects: "motion"),
      extraStyleSliderParam(
        id: "floatSpeed", label: "Float speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "calm", "label": "Calm", "values": ["flicker": false, "floatSpeed": 0.5]],
      ["id": "glitchy", "label": "Glitchy", "values": ["flicker": true, "floatSpeed": 1.6]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "panelColor", "#7DF9FF"))
    var builder = ExtraStyleSceneBuilder()

    // One small corner chip — a label, not a HUD.
    builder.add(extraStyleTextNode(
      id: "chip-label",
      text: "HOLO //", font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
      color: accent,
      position: CGPoint(x: canvas.width - canvas.width * 0.09, y: canvas.height * 0.035),
      zIndex: 5,
      colorParamId: "panelColor"
    ))
    builder.add(extraStyleShapeNode(
      id: "chip-underline",
      shape: extraStyleRectShape(width: canvas.width * 0.11, height: 3),
      fill: accent.withAlpha(0.7),
      position: CGPoint(x: canvas.width - canvas.width * 0.09, y: canvas.height * 0.035 + canvas.width * 0.028),
      zIndex: 5,
      fillColorParamId: "panelColor"
    ))

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centreY = canvas.height * 0.56
      let font = ExtraStyleFonts.mono
      let sizePoints = extraStyleFitSize(
        baseSize: canvas.width * 0.058, text: line.text, font: font, canvasWidth: canvas.width
      )
      let emphasis = Set(line.emphasisWordIndices)
      // Mono words sliding in from the left, floating gently,
      // accent-stroked so they read as holo type on any footage.
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centreY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: font, zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStart, wordEnd in
        var tracks: [ExtraStyleTrack] = [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStart, value: -60, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(wordEnd, wordStart + 10), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStart
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 150, periodParamId: "floatSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 75, value: -6, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: wordStart
          ),
          extraStyleEnterExitOpacityTrack(start: wordStart, end: wordEnd, enterFrames: 8, exitFrames: 8),
        ]
        if emphasis.contains(index) {
          tracks.append(extraStyleSpringInTrack(start: wordStart, from: 0.8, stiffness: 180, damping: 11))
        }
        return tracks
      }
      if words.isEmpty {
        builder.add(extraStyleLyricFallbackNode(
          id: "line-\(lineIndex)", line: line,
          range: lineStartFrame...lineEndFrame,
          y: centreY, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          font: font, zIndex: 10, canvasWidth: canvas.width
        ))
      } else {
        // Accent stroke (not the default dark one) — holo type.
        for word in extraStyleStrokeTextNodes(words, sizePoints: sizePoints, stroke: accent.withAlpha(0.8)) { builder.add(word) }
      }
      // Scanline shimmer: a thin accent line under each word,
      // visible only while the word is sung. The opacity envelope
      // ends at 0, so the flicker toggle's end value hides the
      // shimmer when off.
      let layout = extraStyleWordLayout(
        words: line.words.map { $0.text }, font: font,
        sizePoints: sizePoints, canvasWidth: canvas.width
      )
      for (wordIndex, word) in line.words.enumerated() where wordIndex < layout.centres.count {
        let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
        let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
        guard wordEndFrame > wordStartFrame else { continue }
        let wordWidth = extraStyleTextWidth(word.text, fontPostScriptName: font, sizePoints: sizePoints)
        builder.add(extraStyleShapeNode(
          id: "shimmer-\(lineIndex)-\(wordIndex)",
          shape: extraStyleRectShape(width: wordWidth, height: 3),
          fill: accent.withAlpha(0.55),
          position: CGPoint(x: layout.centres[wordIndex], y: centreY + sizePoints * 0.78),
          zIndex: 9,
          visibleRange: wordStartFrame...wordEndFrame,
          fillColorParamId: "panelColor",
          tracks: [ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 5), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(wordStartFrame, wordEndFrame - 6), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: wordEndFrame, value: 0, easing: .linear),
            ]),
            startFrame: wordStartFrame,
            enabledParamId: "flicker"
          )]
        ))
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Demo 5: Emoji Storytelling (playful)
//
// THE ACCEPTANCE STYLE (Jaizon, 2026-11-13 ~01:26 MST): in the v1
// Emoji Story template he NEVER saw a single emoji. The 2.0
// rebuild renders the line's stored emoji UNCONDITIONALLY via
// extraStyleEmojiNode — no gate, no template check. When a line
// genuinely has no stored emoji (detection found no keyword),
// the hero falls back to the tone's first reaction emoji so the
// style is never empty — that fallback is NOT the v1 bug: the
// stored emoji, when present, is always the hero.
//
// LYRIC-ONLY re-scope: the tone-tinted backdrop wash (a
// full-canvas radial gradient per line) is gone, and the hero
// emoji is no longer a huge centrepiece floating above the line —
// it is small and attached to the words, at the end of the line,
// with the line itself sung word by word underneath the reactions.

final class EmojiStorytellingExtraStyle: ExtraStyleDefinition {
  let id = "emoji-storytelling"
  let version = 1
  let name = "Emoji Storytelling"
  let tagline = "The feeling of every line, told in emoji."
  let category = "playful"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "emojiSize", label: "Emoji size", min: 0.6, max: 2, step: 0.05,
        default: 1.2, affects: "layout"
      ),
      extraStyleSliderParam(
        id: "reactionScale", label: "Reactions", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "motion"
      ),
      extraStyleToggleParam(id: "float", label: "Float", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "big-feelings", "label": "Big feelings", "values": ["emojiSize": 1.6, "reactionScale": 1]],
      ["id": "quiet", "label": "Quiet", "values": ["emojiSize": 0.9, "reactionScale": 0.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let emojiSize = extraStyleParamDouble(input.params, "emojiSize", 1.2)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centreY = canvas.height * 0.58
      let font = ExtraStyleFonts.bold
      let sizePoints = extraStyleFitSize(
        baseSize: canvas.width * 0.055, text: line.text, font: font, canvasWidth: canvas.width
      )
      let emphasis = Set(line.emphasisWordIndices)
      // The line itself, word by word — the karaoke line the
      // emoji attaches to.
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centreY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: font, zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStart, wordEnd in
        var tracks: [ExtraStyleTrack] = [
          extraStyleEnterExitOpacityTrack(start: wordStart, end: wordEnd),
        ]
        if emphasis.contains(index) {
          tracks.append(extraStyleSpringInTrack(start: wordStart, from: 0.8, stiffness: 180, damping: 11))
        }
        return tracks
      }
      if words.isEmpty {
        builder.add(extraStyleLyricFallbackNode(
          id: "line-\(lineIndex)", line: line,
          range: lineStartFrame...lineEndFrame,
          y: centreY, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          font: font, zIndex: 10, canvasWidth: canvas.width
        ))
      } else {
        for word in extraStyleStrokeTextNodes(words, sizePoints: sizePoints) { builder.add(word) }
      }

      // THE HERO EMOJI — small, attached at the end of the line.
      // Unconditional when the payload line has one
      // (extraStyleEmojiNode returns nil ONLY when there is no
      // stored emoji). Float loop added on top of the pop.
      let layoutWidth = extraStyleWordLayout(
        words: line.words.map { $0.text }, font: font,
        sizePoints: sizePoints, canvasWidth: canvas.width
      ).totalWidth
      let heroSize = canvas.width * 0.09 * CGFloat(emojiSize)
      // Clamped inside the frame — a full-width line leaves no
      // room past its last word.
      let emojiCenter = CGPoint(
        x: min(canvas.width - heroSize * 0.6, canvas.width / 2 + layoutWidth / 2 + heroSize * 0.75),
        y: centreY
      )
      if var hero = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: emojiCenter, sizePoints: heroSize, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        hero.tracks.append(ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 150, periodParamId: nil, keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 75, value: -12, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 150, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: lineStartFrame,
          enabledParamId: "float"
        ))
        builder.add(hero)
      } else {
        // No stored emoji on this line: the tone's first reaction
        // emoji stands in, so the style is never empty. (A line
        // WITH a stored emoji never reaches this branch.)
        let fallback = extraStyleReactionEmojis(for: line.tone)[0]
        builder.add(ExtraStyleNode(
          id: "emoji-\(lineIndex)", kind: .emoji,
          position: emojiCenter, anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 11,
          visibleRange: lineStartFrame...lineEndFrame,
          text: ExtraStyleTextContent(
            text: fallback,
            fontPostScriptName: ExtraStyleFonts.emoji,
            sizePoints: heroSize,
            color: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
            strokeColor: nil,
            strokeWidthPoints: 0,
            alignment: .center,
            maxWidthPoints: nil
          ),
          tracks: [extraStyleSpringInTrack(start: lineStartFrame, from: 0.2)]
        ))
      }

      // Reaction bursts: the tone's emoji set, staggered springs
      // around the hero, scaled by the reaction param.
      let reactions = extraStyleReactionEmojis(for: line.tone)
      var reactionRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 7))
      for (reactionIndex, reaction) in reactions.enumerated() {
        let angle = Double(reactionIndex) * (2 * Double.pi / Double(max(1, reactions.count))) + reactionRandom.nextDouble() * 0.5
        let radius = canvas.width * 0.16
        let reactionPosition = CGPoint(
          x: emojiCenter.x + CGFloat(cos(angle)) * radius,
          y: emojiCenter.y + CGFloat(sin(angle)) * radius * 0.8
        )
        builder.add(ExtraStyleNode(
          id: "reaction-\(lineIndex)-\(reactionIndex)", kind: .emoji,
          position: reactionPosition, anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 12,
          visibleRange: lineStartFrame...lineEndFrame,
          text: ExtraStyleTextContent(
            text: reaction,
            fontPostScriptName: ExtraStyleFonts.emoji,
            sizePoints: canvas.width * 0.06,
            color: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
            strokeColor: nil,
            strokeWidthPoints: 0,
            alignment: .center,
            maxWidthPoints: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.2, to: 1, stiffness: 180, damping: 10, initialVelocity: 0),
              startFrame: lineStartFrame + 6 + reactionIndex * 5,
              paramScale: "reactionScale"
            ),
            ExtraStyleTrack(
              property: .positionY,
              kind: .loop(periodFrames: 150, periodParamId: nil, keys: [
                ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 75, value: -8, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 150, value: 0, easing: .easeInOutSine),
              ]),
              startFrame: lineStartFrame,
              enabledParamId: "float"
            ),
          ]
        ))
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration

/// Registers the five demos. The remaining 35 register from
/// their category files (added as their agents land):
///   registerCinematicExtraStyles, registerTypographyExtraStyles,
///   registerDigitalExtraStyles, registerDesignExtraStyles,
///   registerPlayfulExtraStyles, registerMusicExtraStyles,
///   registerExperimentalAExtraStyles, registerExperimentalBExtraStyles.
enum ExtraStylesPhase3 {
  static func registerAll(into registry: ExtraStyleRegistry) {
    registry.register(TypographyPhysicsExtraStyle())
    registry.register(DreamSequenceExtraStyle())
    registry.register(ComicBookExtraStyle())
    registry.register(HolographicInterfaceExtraStyle())
    registry.register(EmojiStorytellingExtraStyle())
    registerCinematicRest(into: registry)
    registerTypographyRest(into: registry)
    registerDigitalRest(into: registry)
    registerDesignRest(into: registry)
    registerPlayfulRest(into: registry)
    registerMusicRest(into: registry)
    registerExperimentalA(into: registry)
    registerExperimentalB(into: registry)
  }
}
