import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3 demos
//
// The five demos (docs/EXTRA-STYLES-2.0.md §17, ★), built first in
// Phase 3 — they are the start of the run, not a gate. Each demo
// proves a different engine capability, and together they are the
// reference implementations the other 35 styles are built from:
//   - Typography Physics — deterministic physics, baked at build
//     time (§5.2) + per-character nodes + onset reactions.
//   - Dream Sequence — particle field, light-trail paths, ghost
//     text layers, loudness-driven glow.
//   - Comic Book — nested panel groups, bursts, impact words,
//     motion lines, onset reactions.
//   - Holographic Interface — HUD panels, scanlines, flicker,
//     floating labels.
//   - Emoji Storytelling — the stored emoji, unconditionally
//     (the v1 failure must not recur — see the helper).
//
// API verdict (audit open question #9): the Phase 2 builder API
// survived all five without a change — the only addition is the
// shared helpers in ExtraStyleBuilders.swift, which the demos
// themselves motivated. No engine change was needed.

// MARK: - Demo 1: Typography Physics (typography)

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
        charDelayFrames: 2,
        colorParamId: "accent"
      ) { index, charStartFrame, lineEnd in
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
            kind: .reaction(input: .onset, base: 1, gain: 0.12),
            startFrame: charStartFrame,
            enabledParamId: "onsetPop"
          ),
        ]
      }
      for char in chars { builder.add(char) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Demo 2: Dream Sequence (cinematic)

final class DreamSequenceExtraStyle: ExtraStyleDefinition {
  let id = "dream-sequence"
  let version = 1
  let name = "Dream Sequence"
  let tagline = "Lyrics drift and dissolve through light and dust."
  let category = "cinematic"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "density", label: "Particle density", min: 0, max: 100, step: 1,
        default: 35, affects: "density"
      ),
      extraStyleSliderParam(
        id: "driftSpeed", label: "Drift speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      // 0–1 range: it multiplies the glow track's value directly
      // (paramScale), so 0.6 means "60% glow".
      extraStyleSliderParam(
        id: "glow", label: "Glow", min: 0, max: 1, step: 0.05,
        default: 0.6, affects: "appearance"
      ),
      extraStyleColorParam(id: "hue", label: "Dream colour", default: "#8FA8FF", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "gentle", "label": "Gentle", "values": ["density": 20, "driftSpeed": 0.6, "glow": 0.4]],
      ["id": "intense", "label": "Intense", "values": ["density": 70, "driftSpeed": 1.4, "glow": 0.9]],
    ]
  }

  var inputs: [String] { ["lines", "intelligence", "audio"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let density = extraStyleParamDouble(input.params, "density", 35)
    var builder = ExtraStyleSceneBuilder()

    // Deep-indigo night gradient.
    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.05, g: 0.06, b: 0.14, a: 1),
        ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Particle field — always added, even at rate 0 (the evaluator
    // expands no particles then, so raising the slider later
    // regains the field with no rebuild).
    builder.add(ExtraStyleNode(
      id: "particles", kind: .particles,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      zIndex: 1,
      emitter: ExtraStyleEmitterContent(
        rate: max(0, min(60, density * 0.5)),
        rateParamId: "density",
        rateParamMultiplier: 0.5,
        lifetimeSeconds: 6,
        origin: CGPoint(x: 0.5, y: 0.55),
        velocity: CGVector(dx: 0, dy: -0.02),
        spread: CGVector(dx: 0.15, dy: 0.02),
        gravity: -0.002,
        size: 0.01,
        sizeSpread: 0.006,
        opacityFrom: 0.8,
        opacityTo: 0,
        color: extraStyleColor(extraStyleParamString(input.params, "hue", "#8FA8FF")),
        colorParamId: "hue",
        spriteKind: .softCircle
      )
    ))

    // Light-trail sine path across the frame.
    let trailY = canvas.height * 0.42
    let trailPath: CGPath = {
      let path = CGMutablePath()
      let step: CGFloat = 40
      var x: CGFloat = 0
      var first = true
      while x <= canvas.width {
        let y = trailY + sin(x / canvas.width * .pi * 4) * 40
        if first { path.move(to: CGPoint(x: x, y: y)); first = false } else { path.addLine(to: CGPoint(x: x, y: y)) }
        x += step
      }
      return path
    }()
    builder.add(ExtraStyleNode(
      id: "trail", kind: .path,
      position: .zero, anchor: .zero, zIndex: 2,
      path: ExtraStylePathContent(
        path: trailPath,
        strokeColor: extraStyleColor(extraStyleParamString(input.params, "hue", "#8FA8FF"), alpha: 0.45),
        strokeWidth: 3,
        dash: nil
      )
    ))

    // A glow dot travelling the trail: loop tracks (period re-timed
    // by driftSpeed) — X sweeps the frame, Y follows the sine.
    builder.add(ExtraStyleNode(
      id: "trail-dot", kind: .shape,
      position: CGPoint(x: 0, y: trailY), anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 3,
      shape: ExtraStyleShapeContent(
        shape: extraStyleEllipseShape(width: 26, height: 26),
        fill: extraStyleColor(extraStyleParamString(input.params, "hue", "#8FA8FF")),
        fillColorParamId: "hue",
        stroke: nil, strokeWidth: 0
      ),
      tracks: [
        ExtraStyleTrack(
          property: .positionX,
          kind: .loop(periodFrames: 240, periodParamId: "driftSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: 240, value: Double(canvas.width), easing: .linear),
          ]),
          startFrame: 0
        ),
        ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 240, periodParamId: "driftSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 60, value: -40, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 120, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 180, value: 40, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // Loudness-driven glow behind the text: a radial wash whose
    // opacity follows the loudness curve, scaled by the glow param.
    let glowNode = ExtraStyleNode(
      id: "glow", kind: .gradient,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 4,
      gradient: ExtraStyleGradientContent(
        kind: .radial(
          center: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
          radius: max(canvas.width, canvas.height) * 0.55
        ),
        colors: [
          extraStyleColor(extraStyleParamString(input.params, "hue", "#8FA8FF"), alpha: 0.35),
          extraStyleColor(extraStyleParamString(input.params, "hue", "#8FA8FF"), alpha: 0),
        ],
        colorParamIds: ["hue", "hue"],
        locations: [0, 1],
        rect: CGRect(origin: .zero, size: canvas)
      ),
      tracks: [
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .loudness, base: 0.2, gain: 0.6),
          startFrame: 0,
          paramScale: "glow"
        ),
      ]
    )
    builder.add(glowNode)

    // Ghost text layers + the main line: the main line dissolves
    // in and out; the ghosts drift on loops at lower opacity.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    let hue = extraStyleColor(extraStyleParamString(input.params, "hue", "#8FA8FF"))
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.07
      let centerY = canvas.height * 0.5
      // Ghost 1: hue, offset up-right, slow drift.
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
      // Ghost 2: hue, offset down-left, slightly larger.
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
      // The main line.
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.bold, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: canvas.width / 2, y: centerY),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 15, exitFrames: 15),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 240, periodParamId: "driftSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 120, value: -10, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Demo 3: Comic Book (playful)

final class ComicBookExtraStyle: ExtraStyleDefinition {
  let id = "comic-book"
  let version = 1
  let name = "Comic Book"
  let tagline = "Panels, bursts, and impact words — a page that moves."
  let category = "playful"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "panelStyle", label: "Panel style",
        options: [("classic", "Classic"), ("bold", "Bold"), ("pop", "Pop")],
        default: "classic", affects: "layout"
      ),
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
      ["id": "bold-pop", "label": "Bold Pop", "values": ["panelStyle": "bold", "impactScale": 1.3]],
      ["id": "quiet", "label": "Quiet", "values": ["panelStyle": "classic", "impactScale": 0.8, "motionLines": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let panelStyle = extraStyleParamString(input.params, "panelStyle", "classic")
    let panelWidth = canvas.width * 0.88
    let panelHeight = canvas.height * 0.52
    var builder = ExtraStyleSceneBuilder()

    // Panel look by style: fill + stroke + rotation.
    let (panelFill, panelStroke, panelStrokeWidth): (ExtraStyleRGBA, ExtraStyleRGBA, CGFloat) = {
      switch panelStyle {
      case "bold":
        return (
          ExtraStyleRGBA(r: 1, g: 0.95, b: 0.84, a: 1),
          ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.06, a: 1),
          10
        )
      case "pop":
        return (
          extraStyleColor(extraStyleParamString(input.params, "accent", "#FFD93D")),
          ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
          4
        )
      default:
        return (
          ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.06, a: 1),
          6
        )
      }
    }()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 1))
      let rotation = CGFloat(random.nextRange(min: -1.5, max: 1.5))
      let panelY = canvas.height * (lineIndex % 2 == 0 ? 0.44 : 0.56)
      let panelId = "panel-\(lineIndex)"

      // Panel wipe: spring scale + quick opacity in at the line start.
      let panelTracks: [ExtraStyleTrack] = [
        ExtraStyleTrack(
          property: .scale,
          kind: .spring(from: 0.85, to: 1, stiffness: 160, damping: 12, initialVelocity: 0),
          startFrame: lineStartFrame
        ),
        ExtraStyleTrack(
          property: .opacity,
          kind: .keyframes(keys: [
            ExtraStyleKeyframe(frame: lineStartFrame, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 6), value: 1, easing: .easeOutCubic),
            ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 9), value: 1, easing: .linear),
            ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
          ]),
          startFrame: lineStartFrame
        ),
      ]

      // Members are group children (addChild, not add) — they move
      // with the panel and are evaluated exactly once.
      var members: [String] = []
      // Panel border.
      let borderId = "panel-border-\(lineIndex)"
      builder.addChild(extraStyleShapeNode(
        id: borderId,
        shape: extraStyleRectShape(width: panelWidth, height: panelHeight),
        fill: panelFill,
        stroke: panelStroke, strokeWidth: panelStrokeWidth,
        position: .zero, zIndex: 0
      ))
      members.append(borderId)
      // The line, inside the panel.
      let textId = "panel-text-\(lineIndex)"
      builder.addChild(extraStyleTextNode(
        id: textId,
        text: line.text, font: ExtraStyleFonts.black, sizePoints: canvas.width * 0.055,
        color: ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.06, a: 1),
        position: CGPoint(x: 0, y: -panelHeight * 0.08),
        zIndex: 1,
        visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: panelWidth * 0.86
      ))
      members.append(textId)
      // Burst in the panel corner.
      let burstId = "panel-burst-\(lineIndex)"
      let burstSize = canvas.width * 0.26
      builder.addChild(ExtraStyleNode(
        id: burstId, kind: .image,
        position: CGPoint(x: panelWidth * 0.32, y: -panelHeight * 0.32),
        anchor: CGPoint(x: 0.5, y: 0.5),
        // The asset is 512×512: scale it to the panel corner.
        scale: burstSize / 512,
        zIndex: 2,
        visibleRange: lineStartFrame...lineEndFrame,
        imageAssetId: "comic-burst",
        tracks: [
          extraStyleSpringInTrack(start: lineStartFrame + 2, from: 0.2, stiffness: 200, damping: 9),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.25),
            startFrame: lineStartFrame
          ),
        ]
      ))
      members.append(burstId)
      // Impact words: the line's emphasis words (or its first word)
      // as big rotated words near the panel top.
      let impactWords: [String] = {
        let indices = line.emphasisWordIndices
        if !indices.isEmpty {
          let words = line.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
          return indices.compactMap { $0 >= 0 && $0 < words.count ? words[$0] : nil }
        }
        let words = line.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.first.map { [$0] } ?? []
      }()
      for (impactIndex, impactWord) in impactWords.enumerated() {
        let impactId = "panel-impact-\(lineIndex)-\(impactIndex)"
        let impactRotation = CGFloat(random.nextRange(min: -8, max: 8))
        builder.addChild(ExtraStyleNode(
          id: impactId, kind: .text,
          position: CGPoint(
            x: CGFloat(random.nextRange(min: -0.22, max: 0.22)) * panelWidth,
            y: -panelHeight * 0.3
          ),
          anchor: CGPoint(x: 0.5, y: 0.5),
          rotationDeg: impactRotation,
          zIndex: 3,
          visibleRange: lineStartFrame...lineEndFrame,
          text: ExtraStyleTextContent(
            text: impactWord.uppercased(),
            fontPostScriptName: ExtraStyleFonts.black,
            sizePoints: canvas.width * 0.085,
            color: extraStyleColor(extraStyleParamString(input.params, "accent", "#FFD93D")),
            colorParamId: "accent",
            strokeColor: ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.06, a: 1),
            strokeWidthPoints: 3,
            alignment: .center,
            maxWidthPoints: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.2, to: 1, stiffness: 220, damping: 9, initialVelocity: 0),
              startFrame: lineStartFrame + 4 + impactIndex * 3,
              paramScale: "impactScale"
            ),
          ]
        ))
        members.append(impactId)
      }
      // Motion lines radiating from the burst.
      for ray in 0..<4 {
        let rayId = "panel-ray-\(lineIndex)-\(ray)"
        let angle = CGFloat(ray) * .pi / 2 + 0.4
        let from = CGPoint(x: panelWidth * 0.32, y: -panelHeight * 0.32)
        let to = CGPoint(
          x: from.x + cos(angle) * panelWidth * 0.16,
          y: from.y + sin(angle) * panelWidth * 0.16
        )
        let rayPath = CGMutablePath()
        rayPath.move(to: from)
        rayPath.addLine(to: to)
        builder.addChild(ExtraStyleNode(
          id: rayId, kind: .path,
          position: .zero, anchor: .zero,
          zIndex: 2,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: rayPath,
            strokeColor: ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.06, a: 0.8),
            strokeWidth: 4,
            dash: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame + ray * 2, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + ray * 2 + 5), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .linear),
              ]),
              startFrame: lineStartFrame,
              enabledParamId: "motionLines"
            ),
          ]
        ))
        members.append(rayId)
      }

      builder.add(ExtraStyleNode(
        id: panelId, kind: .group,
        children: members,
        position: CGPoint(x: canvas.width / 2, y: panelY),
        anchor: .zero,
        rotationDeg: rotation,
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: panelTracks
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Demo 4: Holographic Interface (digital)

final class HolographicInterfaceExtraStyle: ExtraStyleDefinition {
  let id = "holographic-interface"
  let version = 1
  let name = "Holographic Interface"
  let tagline = "HUD panels, scanlines, and floating data."
  let category = "digital"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "panelColor", label: "Interface colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleSliderParam(
        id: "scanlines", label: "Scanline intensity", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "appearance"
      ),
      extraStyleToggleParam(id: "flicker", label: "Flicker", default: true, affects: "motion"),
      extraStyleSliderParam(
        id: "floatSpeed", label: "Float speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "calm", "label": "Calm", "values": ["scanlines": 0.3, "flicker": false, "floatSpeed": 0.5]],
      ["id": "glitchy", "label": "Glitchy", "values": ["scanlines": 1, "flicker": true, "floatSpeed": 1.6]],
    ]
  }

  var inputs: [String] { ["lines", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "panelColor", "#7DF9FF"))
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.03, g: 0.05, b: 0.08, a: 1),
        ExtraStyleRGBA(r: 0.01, g: 0.02, b: 0.03, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Scanlines: thin full-width bars, intensity via paramScale
    // (a single-key opacity track multiplied by the 0–1 param).
    for row in 0..<14 {
      let y = canvas.height * CGFloat(row + 1) / 15
      builder.add(ExtraStyleNode(
        id: "scanline-\(row)", kind: .shape,
        position: CGPoint(x: canvas.width / 2, y: y),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 1,
        shape: ExtraStyleShapeContent(
          shape: extraStyleRectShape(width: canvas.width, height: 3),
          fill: accent.withAlpha(0.06),
          fillColorParamId: "panelColor",
          stroke: nil, strokeWidth: 0
        ),
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: 0, value: 1, easing: .linear)]),
            startFrame: 0,
            paramScale: "scanlines"
          ),
        ]
      ))
    }

    // Scan sweep: a bright bar travelling top → bottom on a loop.
    builder.add(ExtraStyleNode(
      id: "scan-sweep", kind: .shape,
      position: CGPoint(x: canvas.width / 2, y: 0),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 2,
      shape: ExtraStyleShapeContent(
        shape: extraStyleRectShape(width: canvas.width, height: 10),
        fill: accent.withAlpha(0.2),
        fillColorParamId: "panelColor",
        stroke: nil, strokeWidth: 0
      ),
      tracks: [
        ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 180, periodParamId: "floatSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: 180, value: Double(canvas.height), easing: .linear),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // Corner brackets (static HUD chrome).
    let bracketLength = canvas.width * 0.09
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
      (CGPoint(x: 24, y: 24), 1, 1),
      (CGPoint(x: canvas.width - 24, y: 24), -1, 1),
      (CGPoint(x: 24, y: canvas.height - 24), 1, -1),
      (CGPoint(x: canvas.width - 24, y: canvas.height - 24), -1, -1),
    ]
    for (cornerIndex, corner) in corners.enumerated() {
      let (origin, sx, sy) = corner
      let path = CGMutablePath()
      path.move(to: CGPoint(x: origin.x + sx * bracketLength, y: origin.y))
      path.addLine(to: CGPoint(x: origin.x, y: origin.y))
      path.addLine(to: CGPoint(x: origin.x, y: origin.y + sy * bracketLength))
      builder.add(ExtraStyleNode(
        id: "corner-\(cornerIndex)", kind: .path,
        position: .zero, anchor: .zero, zIndex: 3,
        path: ExtraStylePathContent(
          path: path,
          strokeColor: accent.withAlpha(0.7),
          strokeWidth: 3,
          dash: nil
        )
      ))
    }

    // HUD panels: top-left (status) and bottom-right (sync), each
    // floating on a loop and flickering with seeded noise. Members
    // are registered first (addChild), then the group (add).
    func addHudPanel(
      builder: inout ExtraStyleSceneBuilder,
      panelId: String, position: CGPoint, width: CGFloat, height: CGFloat,
      label: String, seed: UInt64
    ) {
      builder.addChild(extraStyleShapeNode(
        id: "\(panelId)-frame",
        shape: extraStyleRectShape(width: width, height: height),
        fill: accent.withAlpha(0.05),
        stroke: accent, strokeWidth: 2,
        position: .zero, zIndex: 0
      ))
      builder.addChild(extraStyleTextNode(
        id: "\(panelId)-label",
        text: label, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
        color: accent,
        position: CGPoint(x: 0, y: -height * 0.22),
        zIndex: 1,
        colorParamId: "panelColor"
      ))
      builder.addChild(extraStyleShapeNode(
        id: "\(panelId)-bar",
        shape: extraStyleRectShape(width: width * 0.6, height: 4),
        fill: accent.withAlpha(0.8),
        position: CGPoint(x: 0, y: height * 0.28),
        zIndex: 1
      ))
      builder.add(ExtraStyleNode(
        id: panelId, kind: .group,
        children: ["\(panelId)-frame", "\(panelId)-label", "\(panelId)-bar"],
        position: position, anchor: .zero,
        zIndex: 4,
        tracks: [
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 150, periodParamId: "floatSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 75, value: -8, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: 0
          ),
          extraStyleFlickerTrack(start: 0, end: input.durationFrames, base: 0.95, amplitude: 0.12, seed: seed),
        ]
      ))
    }
    addHudPanel(
      builder: &builder, panelId: "hud-top",
      position: CGPoint(x: canvas.width * 0.22, y: canvas.height * 0.1),
      width: canvas.width * 0.34, height: canvas.height * 0.07,
      label: "MVMT // LIVE", seed: input.seed ^ 0x4855_4400_0001
    )
    addHudPanel(
      builder: &builder, panelId: "hud-bottom",
      position: CGPoint(x: canvas.width * 0.78, y: canvas.height * 0.88),
      width: canvas.width * 0.3, height: canvas.height * 0.06,
      label: "SYNC 30FPS", seed: input.seed ^ 0x4855_4400_0002
    )

    // Per-line floating labels + the main line.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // Floating label: slides in from the left, floats, exits.
      builder.add(extraStyleTextNode(
        id: "label-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.042,
        color: accent,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.5),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        colorParamId: "panelColor",
        tracks: [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: -60, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 10), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 150, periodParamId: "floatSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 75, value: -6, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 8, exitFrames: 8),
        ]
      ))
      // Main line, mono, with an accent stroke.
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.058,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.62),
        zIndex: 11, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        strokeColor: accent, strokeWidthPoints: 1.5,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))
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
      extraStyleSegmentedParam(
        id: "backdrop", label: "Backdrop",
        options: [("soft", "Soft"), ("none", "None"), ("vivid", "Vivid")],
        default: "soft", affects: "layout"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "big-feelings", "label": "Big feelings", "values": ["emojiSize": 1.6, "reactionScale": 1]],
      ["id": "quiet", "label": "Quiet", "values": ["emojiSize": 0.9, "reactionScale": 0.4, "backdrop": "none"]],
    ]
  }

  var inputs: [String] { ["lines", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let emojiSize = extraStyleParamDouble(input.params, "emojiSize", 1.2)
    let backdrop = extraStyleParamString(input.params, "backdrop", "soft")
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let toneColor = extraStyleToneColor(line.tone)
      let emojiCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.36)
      let heroSize = canvas.width * 0.16 * CGFloat(emojiSize)

      // Tone-tinted backdrop wash behind the hero emoji.
      if backdrop != "none" {
        let alpha: CGFloat = backdrop == "vivid" ? 0.55 : 0.3
        builder.add(ExtraStyleNode(
          id: "backdrop-\(lineIndex)", kind: .gradient,
          position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
          anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 5,
          visibleRange: lineStartFrame...lineEndFrame,
          gradient: ExtraStyleGradientContent(
            kind: .radial(center: emojiCenter, radius: max(canvas.width, canvas.height) * 0.5),
            colors: [toneColor.withAlpha(alpha), toneColor.withAlpha(0)],
            locations: [0, 1],
            rect: CGRect(origin: .zero, size: canvas)
          )
        ))
      }

      // THE HERO EMOJI — unconditional when the payload line has
      // one (extraStyleEmojiNode returns nil ONLY when there is no
      // stored emoji). Float loop added on top of the pop.
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
        let radius = canvas.width * 0.22
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
            sizePoints: canvas.width * 0.07,
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

      // The line itself, below the hero.
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.bold, sizePoints: canvas.width * 0.055,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.58),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))
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
