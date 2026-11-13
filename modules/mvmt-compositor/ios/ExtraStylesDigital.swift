import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3 digital family
//
// The four Digital/Futuristic styles (docs/EXTRA-STYLES-2.0.md
// §17 rows 12–15):
//   - Digital Corruption — RGB-split text, glitch slices, noise
//     field, onset-driven glitch bursts.
//   - Cyber Terminal — terminal panel, per-char typewriter reveal,
//     cursor, system-message lines.
//   - Virtual Reality — floating 3D panels (true perspective
//     groups), depth-scaled text, face-tracked HUD.
//   - Data Visualization — number counters, band-driven bars,
//     loudness-driven waveform, diagram groups.
//
// Flags (STYLE_CAPABILITY_MAP, src/lib/extra-styles/catalog.ts,
// authoritative): Digital Corruption and Data Visualization
// REQUIRE audio automation (needsAudioAutomation = true —
// automation is supplied, so bars/waveform/glitch bursts read it
// directly); Virtual Reality REQUIRES subject masks
// (needsSubjectMasks = true); Cyber Terminal needs neither.

// MARK: - Shared private helpers (digital family only)

/// Seeded jitter offsets: a new random offset every 3 frames,
/// then a reconstruct ramp to 0 over the last `reconstructFrames`
/// frames (the §17 "reconstruct (offsets → 0)" behaviour).
private func digitalJitterKeys(
  start: Int, end: Int, seed: UInt64, amount: Double, reconstructFrames: Int = 12
) -> [ExtraStyleKeyframe] {
  guard end > start else { return [ExtraStyleKeyframe(frame: start, value: 0, easing: .linear)] }
  var random = ExtraStyleSeededRandom(seed: seed)
  // Very short lines just snap back — no room for a jitter run.
  if end - start <= reconstructFrames + 6 {
    return [
      ExtraStyleKeyframe(frame: start, value: random.nextRange(min: -amount, max: amount), easing: .linear),
      ExtraStyleKeyframe(frame: end, value: 0, easing: .easeOutCubic),
    ]
  }
  var keys: [ExtraStyleKeyframe] = []
  let settleStart = end - reconstructFrames
  var frame = start
  while frame < settleStart {
    keys.append(ExtraStyleKeyframe(frame: frame, value: random.nextRange(min: -amount, max: amount), easing: .linear))
    frame += 3
  }
  keys.append(ExtraStyleKeyframe(frame: settleStart, value: random.nextRange(min: -amount, max: amount), easing: .linear))
  keys.append(ExtraStyleKeyframe(frame: end - reconstructFrames / 2, value: random.nextRange(min: -amount / 2, max: amount / 2), easing: .easeOutCubic))
  keys.append(ExtraStyleKeyframe(frame: end, value: 0, easing: .easeOutCubic))
  return keys
}

/// Opacity bursts: mostly 0, spiking to 1 for 3 frames at seeded
/// intervals — a glitch slice that flashes in and out.
private func digitalBurstOpacityKeys(start: Int, end: Int, seed: UInt64) -> [ExtraStyleKeyframe] {
  var random = ExtraStyleSeededRandom(seed: seed)
  var keys: [ExtraStyleKeyframe] = [ExtraStyleKeyframe(frame: start, value: 0, easing: .linear)]
  var frame = start + Int(random.nextRange(min: 6, max: 18))
  while frame < end - 4 {
    keys.append(ExtraStyleKeyframe(frame: frame, value: 0, easing: .linear))
    keys.append(ExtraStyleKeyframe(frame: frame + 1, value: 1, easing: .linear))
    keys.append(ExtraStyleKeyframe(frame: frame + 3, value: 1, easing: .linear))
    keys.append(ExtraStyleKeyframe(frame: frame + 4, value: 0, easing: .linear))
    frame += Int(random.nextRange(min: 12, max: 30))
  }
  keys.append(ExtraStyleKeyframe(frame: end, value: 0, easing: .linear))
  return keys
}

/// Face-centre position tracks with a CENTRE FALLBACK: sampled
/// every 15 frames; a sample with no face box uses the canvas
/// centre (upper-middle) instead of holding a stale box, so the
/// HUD never strands off-frame. Base position must be (0, 0) —
/// these values are absolute canvas points, added as offsets.
private func vrFaceTracks(
  maskIndex: ExtraStyleSubjectMaskIndex?, fps: Double, canvas: CGSize,
  startFrame: Int, endFrame: Int
) -> [ExtraStyleTrack] {
  guard let maskIndex, !maskIndex.faces.isEmpty else { return [] }
  var xKeys: [ExtraStyleKeyframe] = []
  var yKeys: [ExtraStyleKeyframe] = []
  var frame = startFrame
  while frame <= endFrame {
    let seconds = Double(frame) / fps
    let boxes = maskIndex.faceBoxes(at: seconds)
    let cx: Double
    let cy: Double
    if let box = boxes.first {
      cx = Double(box.origin.x + box.size.width / 2) * Double(canvas.width)
      cy = Double(box.origin.y + box.size.height / 2) * Double(canvas.height)
    } else {
      cx = Double(canvas.width) / 2
      cy = Double(canvas.height) * 0.3
    }
    xKeys.append(ExtraStyleKeyframe(frame: frame, value: cx, easing: .linear))
    yKeys.append(ExtraStyleKeyframe(frame: frame, value: cy, easing: .linear))
    frame += 15
  }
  guard !xKeys.isEmpty else { return [] }
  return [
    ExtraStyleTrack(property: .positionX, kind: .keyframes(keys: xKeys), startFrame: startFrame),
    ExtraStyleTrack(property: .positionY, kind: .keyframes(keys: yKeys), startFrame: startFrame),
  ]
}

/// Camera-tracking illusion: the background grid counter-moves
/// against the face (offset = −0.3 × face displacement from
/// centre), sampled every 15 frames. Empty when no faces exist.
private func vrCounterMoveTracks(
  maskIndex: ExtraStyleSubjectMaskIndex?, fps: Double, canvas: CGSize,
  startFrame: Int, endFrame: Int
) -> [ExtraStyleTrack] {
  guard let maskIndex, !maskIndex.faces.isEmpty else { return [] }
  var xKeys: [ExtraStyleKeyframe] = []
  var yKeys: [ExtraStyleKeyframe] = []
  var frame = startFrame
  while frame <= endFrame {
    let seconds = Double(frame) / fps
    let boxes = maskIndex.faceBoxes(at: seconds)
    var dx = 0.0
    var dy = 0.0
    if let box = boxes.first {
      let cx = Double(box.origin.x + box.size.width / 2) * Double(canvas.width)
      let cy = Double(box.origin.y + box.size.height / 2) * Double(canvas.height)
      dx = -(cx - Double(canvas.width) / 2) * 0.3
      dy = -(cy - Double(canvas.height) * 0.5) * 0.3
    }
    xKeys.append(ExtraStyleKeyframe(frame: frame, value: dx, easing: .linear))
    yKeys.append(ExtraStyleKeyframe(frame: frame, value: dy, easing: .linear))
    frame += 15
  }
  guard !xKeys.isEmpty else { return [] }
  return [
    ExtraStyleTrack(property: .positionX, kind: .keyframes(keys: xKeys), startFrame: startFrame),
    ExtraStyleTrack(property: .positionY, kind: .keyframes(keys: yKeys), startFrame: startFrame),
  ]
}

// MARK: - Style 12: Digital Corruption (digital)

final class DigitalCorruptionExtraStyle: ExtraStyleDefinition {
  let id = "digital-corruption"
  let version = 1
  let name = "Digital Corruption"
  let tagline = "The signal breaks apart — RGB split, slices, noise."
  let category = "digital"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "glitchIntensity", label: "Glitch intensity", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "splitAmount", label: "RGB split", min: 0, max: 16, step: 0.5,
        default: 6, affects: "appearance"
      ),
      extraStyleSliderParam(
        id: "noiseDensity", label: "Noise density", min: 0, max: 100, step: 1,
        default: 40, affects: "density"
      ),
      extraStyleToggleParam(id: "displacement", label: "Signal distortion", default: true, affects: "motion"),
      extraStyleColorParam(id: "accent", label: "Glitch colour", default: "#FF2E63", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "subtle", "label": "Subtle", "values": ["glitchIntensity": 0.35, "splitAmount": 3, "noiseDensity": 20]],
      ["id": "meltdown", "label": "Meltdown", "values": ["glitchIntensity": 1, "splitAmount": 14, "noiseDensity": 80]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }
  var rebuildParamIds: [String] { ["glitchIntensity", "splitAmount", "displacement"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let intensity = extraStyleParamDouble(input.params, "glitchIntensity", 0.7)
    let split = extraStyleParamDouble(input.params, "splitAmount", 6)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FF2E63"))
    var builder = ExtraStyleSceneBuilder()

    // Near-black blue-tinted background.
    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.04, g: 0.04, b: 0.08, a: 1),
        ExtraStyleRGBA(r: 0.01, g: 0.01, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Noise field: square sprites scattered over the frame. The
    // rate follows the noiseDensity param with no rebuild.
    builder.add(ExtraStyleNode(
      id: "noise", kind: .particles,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      zIndex: 1,
      emitter: ExtraStyleEmitterContent(
        rate: max(0, min(60, extraStyleParamDouble(input.params, "noiseDensity", 40) * 0.4)),
        rateParamId: "noiseDensity",
        rateParamMultiplier: 0.4,
        lifetimeSeconds: 1.5,
        origin: CGPoint(x: 0.5, y: 0.5),
        velocity: CGVector(dx: 0, dy: 0),
        spread: CGVector(dx: 0.5, dy: 0.5),
        gravity: 0,
        size: 0.004,
        sizeSpread: 0.003,
        opacityFrom: 0.5,
        opacityTo: 0,
        color: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
        spriteKind: .square
      )
    ))

    // Signal distortion: a full-frame displacement wave whose
    // scale follows the onset envelope — glitch bursts land on
    // accents. (Base scale 10 matches the Metal-spike precedent
    // of 20 for a full-strength wave; the reaction lifts it to
    // ~30 on onsets.)
    if extraStyleParamBool(input.params, "displacement", true) {
      builder.add(ExtraStyleNode(
        id: "glitch-wave", kind: .displacement,
        position: .zero, anchor: .zero,
        displacement: ExtraStyleDisplacementContent(baseScale: 10, frequency: 6),
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 6, gain: 24),
            startFrame: 0
          ),
        ]
      ))
    }

    // Scanlines: thin full-width bars with seeded flicker.
    for row in 0..<8 {
      let y = canvas.height * CGFloat(row + 1) / 9
      builder.add(extraStyleShapeNode(
        id: "scanline-\(row)",
        shape: extraStyleRectShape(width: canvas.width, height: 2),
        fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.05),
        position: CGPoint(x: canvas.width / 2, y: y),
        zIndex: 2,
        tracks: [
          extraStyleFlickerTrack(
            start: 0, end: input.durationFrames, base: 0.6, amplitude: 0.4,
            seed: input.seed ^ UInt64(0xD161_0000 + row), stepFrames: 4
          ),
        ]
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.062
      let center = CGPoint(x: canvas.width / 2, y: canvas.height * 0.5)
      let textWidth = min(
        extraStyleTextWidth(line.text, fontPostScriptName: ExtraStyleFonts.mono, sizePoints: sizePoints),
        canvas.width * 0.88
      )
      let textHeight = sizePoints * 1.25
      let jitterAmount = max(0, split * intensity)

      // Base copy: warm white, small jitter.
      builder.add(extraStyleTextNode(
        id: "base-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 0.9),
        position: center, zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 6, exitFrames: 6),
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: digitalJitterKeys(
              start: lineStartFrame, end: lineEndFrame,
              seed: input.seed ^ UInt64(lineIndex + 1), amount: jitterAmount * 0.3
            )),
            startFrame: lineStartFrame
          ),
        ]
      ))

      // RGB split: three tinted copies, screen-blended, offset in
      // opposite directions with independent seeded jitter. The
      // engine exposes real blend modes on the node, so the split
      // is a genuine screen composite, not just tinted copies.
      let channels: [(String, ExtraStyleRGBA, CGFloat, CGFloat)] = [
        ("r", ExtraStyleRGBA(r: 1, g: 0.15, b: 0.25, a: 1), -split, -split * 0.4),
        ("g", ExtraStyleRGBA(r: 0.2, g: 1, b: 0.4, a: 1), split, split * 0.4),
        ("b", ExtraStyleRGBA(r: 0.3, g: 0.5, b: 1, a: 1), -split * 0.6, split * 0.6),
      ]
      for (channelIndex, channel) in channels.enumerated() {
        let (suffix, color, dx, dy) = channel
        var node = extraStyleTextNode(
          id: "split-\(suffix)-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
          color: color,
          position: CGPoint(x: center.x + dx, y: center.y + dy),
          zIndex: 11 + channelIndex,
          visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 6, exitFrames: 6),
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: digitalJitterKeys(
                start: lineStartFrame, end: lineEndFrame,
                seed: input.seed ^ UInt64(0x5256_4200 + lineIndex * 3 + channelIndex),
                amount: jitterAmount
              )),
              startFrame: lineStartFrame
            ),
            ExtraStyleTrack(
              property: .positionY,
              kind: .keyframes(keys: digitalJitterKeys(
                start: lineStartFrame, end: lineEndFrame,
                seed: input.seed ^ UInt64(0x5256_4300 + lineIndex * 3 + channelIndex),
                amount: jitterAmount * 0.6
              )),
              startFrame: lineStartFrame
            ),
            // Onset pop: the split breathes on accents.
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .onset, base: 1, gain: 0.06),
              startFrame: lineStartFrame
            ),
          ]
        )
        node.blendMode = .screen
        builder.add(node)
      }

      // Glitch slices: masked bands of the line that flash in
      // displaced. The mask is a local-space rect band across the
      // text block (local (0, 0) is the block's top-left).
      for slice in 0..<2 {
        var sliceRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(0x534C_4943 + lineIndex * 2 + slice))
        let bandHeight = CGFloat(sliceRandom.nextRange(min: 0.14, max: 0.3)) * textHeight
        let bandY = CGFloat(sliceRandom.nextRange(min: 0, max: 0.7)) * textHeight
        let bandPath = CGPath(rect: CGRect(x: 0, y: bandY, width: textWidth, height: bandHeight), transform: nil)
        var sliceNode = extraStyleTextNode(
          id: "slice-\(lineIndex)-\(slice)",
          text: line.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
          color: slice == 0 ? accent : ExtraStyleRGBA(r: 0.5, g: 0.95, b: 1, a: 1),
          position: center, zIndex: 14,
          visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          colorParamId: slice == 0 ? "accent" : nil,
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: digitalBurstOpacityKeys(
                start: lineStartFrame, end: lineEndFrame,
                seed: input.seed ^ UInt64(0x4255_5253 + lineIndex * 2 + slice)
              )),
              startFrame: lineStartFrame
            ),
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: digitalJitterKeys(
                start: lineStartFrame, end: lineEndFrame,
                seed: input.seed ^ UInt64(0x4A55_4D50 + lineIndex * 2 + slice),
                amount: 34
              )),
              startFrame: lineStartFrame
            ),
          ]
        )
        sliceNode.mask = .shape(path: bandPath)
        sliceNode.blendMode = .screen
        builder.add(sliceNode)
      }

      // The line's stored emoji, glitched at the frame edge.
      if let emojiNode = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(x: canvas.width * 0.84, y: canvas.height * 0.28),
        sizePoints: canvas.width * 0.07, zIndex: 15,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        var glitched = emojiNode
        glitched.tracks.append(ExtraStyleTrack(
          property: .positionX,
          kind: .keyframes(keys: digitalJitterKeys(
            start: lineStartFrame, end: lineEndFrame,
            seed: input.seed ^ UInt64(0x454D_4F4A + lineIndex), amount: jitterAmount
          )),
          startFrame: lineStartFrame
        ))
        builder.add(glitched)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 13: Cyber Terminal (digital)

final class CyberTerminalExtraStyle: ExtraStyleDefinition {
  let id = "cyber-terminal"
  let version = 1
  let name = "Cyber Terminal"
  let tagline = "Lyrics typed live on a green-phosphor terminal."
  let category = "digital"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "accent", label: "Terminal colour", default: "#33FF66", affects: "appearance"),
      extraStyleSliderParam(
        id: "typingSpeed", label: "Typing speed", min: 0.5, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "scanlineIntensity", label: "Scanline intensity", min: 0, max: 1, step: 0.05,
        default: 0.6, affects: "appearance"
      ),
      extraStyleToggleParam(id: "cursorBlink", label: "Blinking cursor", default: true, affects: "motion"),
      extraStyleToggleParam(id: "systemLines", label: "System messages", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "matrix", "label": "Matrix", "values": ["accent": "#33FF66", "typingSpeed": 1.2]],
      ["id": "amber", "label": "Amber", "values": ["accent": "#FFB000", "typingSpeed": 0.8, "scanlineIntensity": 0.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }
  var rebuildParamIds: [String] { ["typingSpeed", "systemLines"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#33FF66"))
    let typingSpeed = extraStyleParamDouble(input.params, "typingSpeed", 1)
    let charDelayFrames = max(1, Int((2.0 / max(0.5, typingSpeed)).rounded()))
    let showSystemLines = extraStyleParamBool(input.params, "systemLines", true)
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.01, g: 0.05, b: 0.02, a: 1),
        ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Terminal panel: one group for the whole scene — frame,
    // header bar, header label, and scanlines move together.
    let panelWidth = canvas.width * 0.9
    let panelHeight = canvas.height * 0.62
    let panelCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.46)
    var panelMembers: [String] = []
    builder.addChild(extraStyleShapeNode(
      id: "panel-frame",
      shape: extraStyleRectShape(width: panelWidth, height: panelHeight),
      fill: accent.withAlpha(0.04),
      stroke: accent, strokeWidth: 2,
      position: .zero, zIndex: 0,
      fillColorParamId: nil
    ))
    panelMembers.append("panel-frame")
    builder.addChild(extraStyleShapeNode(
      id: "panel-header",
      shape: extraStyleRectShape(width: panelWidth, height: 36),
      fill: accent.withAlpha(0.18),
      position: CGPoint(x: 0, y: -panelHeight / 2 + 18),
      zIndex: 1
    ))
    panelMembers.append("panel-header")
    builder.addChild(extraStyleTextNode(
      id: "panel-title",
      text: "MVMT://TERMINAL — SESSION 001", font: ExtraStyleFonts.mono,
      sizePoints: canvas.width * 0.026, color: accent,
      position: CGPoint(x: 0, y: -panelHeight / 2 + 18),
      zIndex: 2,
      colorParamId: "accent"
    ))
    panelMembers.append("panel-title")
    // Scanlines inside the panel: intensity via paramScale.
    for row in 0..<10 {
      let rowId = "panel-scanline-\(row)"
      let y = -panelHeight / 2 + 48 + CGFloat(row) * (panelHeight - 60) / 10
      builder.addChild(ExtraStyleNode(
        id: rowId, kind: .shape,
        position: CGPoint(x: 0, y: y), anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 1,
        shape: ExtraStyleShapeContent(
          shape: extraStyleRectShape(width: panelWidth, height: 2),
          fill: accent.withAlpha(0.07),
          fillColorParamId: "accent",
          stroke: nil, strokeWidth: 0
        ),
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: 0, value: 1, easing: .linear)]),
            startFrame: 0,
            paramScale: "scanlineIntensity"
          ),
        ]
      ))
      panelMembers.append(rowId)
    }
    builder.add(ExtraStyleNode(
      id: "panel", kind: .group,
      children: panelMembers,
      position: panelCenter, anchor: .zero,
      zIndex: 3
    ))

    // Scan sweep: a bright bar travelling top → bottom on a loop.
    builder.add(ExtraStyleNode(
      id: "scan-sweep", kind: .shape,
      position: CGPoint(x: canvas.width / 2, y: 0),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 4,
      shape: ExtraStyleShapeContent(
        shape: extraStyleRectShape(width: canvas.width, height: 8),
        fill: accent.withAlpha(0.15),
        fillColorParamId: "accent",
        stroke: nil, strokeWidth: 0
      ),
      tracks: [
        ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 240, periodParamId: "typingSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: 240, value: Double(canvas.height), easing: .linear),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // Boot line: the terminal announces itself, then yields.
    let bootEnd = min(input.durationFrames, 90)
    if bootEnd > 12 {
      builder.add(extraStyleTextNode(
        id: "boot",
        text: "MVMT OS v2.0 — boot sequence OK", font: ExtraStyleFonts.mono,
        sizePoints: canvas.width * 0.028, color: accent,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.2),
        zIndex: 5, visibleRange: 0...bootEnd,
        colorParamId: "accent",
        tracks: [extraStyleEnterExitOpacityTrack(start: 0, end: bootEnd, enterFrames: 6, exitFrames: 12)]
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.045
      let lineY = canvas.height * 0.46

      // Typewriter: per-char discrete reveal — opacity snaps
      // 0 → 1 in a single frame at each char's reveal frame
      // (linear easing over a 1-frame span is a step), then the
      // char holds until the line exits.
      let chars = extraStyleCharNodes(
        text: line.text, lineIndex: lineIndex,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: lineY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: ExtraStyleFonts.mono, zIndex: 10, canvasWidth: canvas.width,
        charDelayFrames: charDelayFrames
      ) { _, charStartFrame, lineEnd in
        [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: charStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEnd, charStartFrame + 1), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: max(charStartFrame, lineEnd - 6), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: lineEnd, value: 0, easing: .linear),
            ]),
            startFrame: charStartFrame
          ),
        ]
      }
      for char in chars { builder.add(char) }

      // Cursor: a block that travels left → right as the chars
      // reveal, then blinks in place. Total typed width is
      // measured, so the cursor lands exactly at the line's end.
      let charWidths = Array(line.text).map {
        $0 == " "
          ? extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.mono, sizePoints: sizePoints)
          : extraStyleTextWidth(String($0), fontPostScriptName: ExtraStyleFonts.mono, sizePoints: sizePoints)
      }
      let totalWidth = charWidths.reduce(0, +)
      let typingFrames = max(1, Array(line.text).count * charDelayFrames)
      let typingEnd = min(lineEndFrame, lineStartFrame + typingFrames)
      let leftEdgeX = (canvas.width - totalWidth) / 2
      var blinkKeys: [ExtraStyleKeyframe] = []
      var blinkFrame = lineStartFrame
      var blinkValue = 1.0
      while blinkFrame <= lineEndFrame {
        blinkKeys.append(ExtraStyleKeyframe(frame: blinkFrame, value: blinkValue, easing: .linear))
        blinkValue = blinkValue == 1 ? 0 : 1
        blinkFrame += 9
      }
      if blinkKeys.last?.frame != lineEndFrame {
        blinkKeys.append(ExtraStyleKeyframe(frame: lineEndFrame, value: 1, easing: .linear))
      }
      builder.add(ExtraStyleNode(
        id: "cursor-\(lineIndex)", kind: .shape,
        position: CGPoint(x: leftEdgeX, y: lineY),
        anchor: CGPoint(x: 0, y: 0.5),
        zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame,
        shape: ExtraStyleShapeContent(
          shape: extraStyleRectShape(width: 14, height: sizePoints * 1.1),
          fill: accent,
          fillColorParamId: "accent",
          stroke: nil, strokeWidth: 0
        ),
        tracks: [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: typingEnd, value: Double(totalWidth), easing: .linear),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: blinkKeys),
            startFrame: lineStartFrame,
            enabledParamId: "cursorBlink"
          ),
        ]
      ))

      // System-message line above the typed line: the stored
      // tone + word count, as a terminal log entry.
      if showSystemLines {
        let tone = line.tone ?? "neutral"
        builder.add(extraStyleTextNode(
          id: "sys-\(lineIndex)",
          text: "> sys: line \(lineIndex + 1) · tone \(tone) · \(line.words.count) words",
          font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.026,
          color: accent.withAlpha(0.85),
          position: CGPoint(x: canvas.width / 2, y: lineY - sizePoints * 1.7),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          colorParamId: "accent",
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 6), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 6), value: 1, easing: .linear),
                ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .linear),
              ]),
              startFrame: lineStartFrame
            ),
          ]
        ))
      }

      // Prompt marker at the panel's left edge for the active line.
      builder.add(extraStyleTextNode(
        id: "prompt-\(lineIndex)",
        text: ">", font: ExtraStyleFonts.mono, sizePoints: sizePoints,
        color: accent,
        position: CGPoint(x: canvas.width * 0.08, y: lineY),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        colorParamId: "accent",
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 4, exitFrames: 6)]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 14: Virtual Reality (digital)

final class VirtualRealityExtraStyle: ExtraStyleDefinition {
  let id = "virtual-reality"
  let version = 1
  let name = "Virtual Reality"
  let tagline = "Floating panels in depth, tracking you."
  let category = "digital"
  let needsAudioAutomation = false
  let needsSubjectMasks = true
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "depthAmount", label: "Depth", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "layout"
      ),
      extraStyleColorParam(id: "panelColor", label: "Panel colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleSliderParam(
        id: "floatSpeed", label: "Float speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleToggleParam(id: "faceTracking", label: "Track my face", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "deep", "label": "Deep", "values": ["depthAmount": 1, "floatSpeed": 0.6]],
      ["id": "near", "label": "Near", "values": ["depthAmount": 0.35, "floatSpeed": 1.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "subject"] }
  var rebuildParamIds: [String] { ["depthAmount", "faceTracking"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let depthAmount = extraStyleParamDouble(input.params, "depthAmount", 0.7)
    let panelColor = extraStyleColor(extraStyleParamString(input.params, "panelColor", "#7DF9FF"))
    let faceTracking = extraStyleParamBool(input.params, "faceTracking", true)
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.02, g: 0.04, b: 0.09, a: 1),
        ExtraStyleRGBA(r: 0.005, g: 0.005, b: 0.01, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Perspective floor grid: horizontal + converging vertical
    // paths in one group that counter-moves against the face —
    // the camera-tracking illusion. Paths are absolute canvas
    // coords; the group sits at (0, 0) so its offset tracks
    // shift the whole grid.
    var gridMembers: [String] = []
    for row in 0..<5 {
      let t = Double(row) / 4
      let y = canvas.height * CGFloat(0.62 + 0.33 * t * t)
      let path = CGMutablePath()
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: canvas.width, y: y))
      let rowId = "grid-h-\(row)"
      builder.addChild(ExtraStyleNode(
        id: rowId, kind: .path,
        position: .zero, anchor: .zero, zIndex: 0,
        path: ExtraStylePathContent(
          path: path,
          strokeColor: panelColor.withAlpha(0.16),
          strokeWidth: 1.5,
          dash: nil
        )
      ))
      gridMembers.append(rowId)
    }
    for col in 0..<5 {
      let t = Double(col) / 4
      let topX = canvas.width * CGFloat(0.5 + (t - 0.5) * 0.3)
      let bottomX = canvas.width * CGFloat(0.5 + (t - 0.5) * 1.7)
      let path = CGMutablePath()
      path.move(to: CGPoint(x: topX, y: canvas.height * 0.6))
      path.addLine(to: CGPoint(x: bottomX, y: canvas.height))
      let colId = "grid-v-\(col)"
      builder.addChild(ExtraStyleNode(
        id: colId, kind: .path,
        position: .zero, anchor: .zero, zIndex: 0,
        path: ExtraStylePathContent(
          path: path,
          strokeColor: panelColor.withAlpha(0.12),
          strokeWidth: 1.5,
          dash: nil
        )
      ))
      gridMembers.append(colId)
    }
    builder.add(ExtraStyleNode(
      id: "grid", kind: .group,
      children: gridMembers,
      position: .zero, anchor: .zero,
      zIndex: 1,
      tracks: faceTracking
        ? vrCounterMoveTracks(maskIndex: input.maskIndex, fps: fps, canvas: canvas, startFrame: 0, endFrame: input.durationFrames)
        : []
    ))

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // Depth tier per line: near / mid / far cycle, so
      // consecutive lines sit on different depth planes.
      let tier = lineIndex % 3
      let depth = 0.6 + Double(tier) * 0.5 + depthAmount * 0.4
      let panelWidth = canvas.width * 0.8
      let panelHeight = canvas.height * 0.42
      let panelCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.5)
      // Perspective corners are absolute canvas points in
      // [topLeft, topRight, bottomRight, bottomLeft] order. The
      // engine warps the group's full-canvas raster into this
      // quad, so the plane is near-full-frame: a trapezoid whose
      // top edge narrows with depth — the 2.5D tilt.
      let squeeze = CGFloat(depthAmount * 60 + Double(tier) * 24)
      let corners: [CGPoint] = [
        CGPoint(x: canvas.width * 0.10 + squeeze, y: canvas.height * 0.24),
        CGPoint(x: canvas.width * 0.90 - squeeze, y: canvas.height * 0.24),
        CGPoint(x: canvas.width * 0.97, y: canvas.height * 0.78),
        CGPoint(x: canvas.width * 0.03, y: canvas.height * 0.78),
      ]

      var members: [String] = []
      builder.addChild(extraStyleShapeNode(
        id: "plane-frame-\(lineIndex)",
        shape: extraStyleRectShape(width: panelWidth, height: panelHeight),
        fill: panelColor.withAlpha(0.06),
        stroke: panelColor, strokeWidth: 2,
        position: .zero, zIndex: 0
      ))
      members.append("plane-frame-\(lineIndex)")
      // Depth-scaled text: farther tiers render smaller.
      let textScale = 1.0 - CGFloat(tier) * 0.12
      let textNode = extraStyleTextNode(
        id: "plane-text-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.bold,
        sizePoints: canvas.width * 0.055 * textScale,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: 0, y: -panelHeight * 0.06),
        zIndex: 1,
        visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: panelWidth * 0.88,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 10, exitFrames: 10)]
      )
      builder.addChild(textNode)
      members.append("plane-text-\(lineIndex)")
      builder.addChild(extraStyleTextNode(
        id: "plane-depth-\(lineIndex)",
        text: String(format: "DEPTH %.1fm · PLANE %d", depth, tier + 1),
        font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.026,
        color: panelColor,
        position: CGPoint(x: 0, y: -panelHeight / 2 + 34),
        zIndex: 1,
        colorParamId: "panelColor"
      ))
      members.append("plane-depth-\(lineIndex)")
      if let emojiNode = extraStyleEmojiNode(
        id: "plane-emoji-\(lineIndex)", line: line,
        position: CGPoint(x: 0, y: panelHeight * 0.3),
        sizePoints: canvas.width * 0.08, zIndex: 2,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.addChild(emojiNode)
        members.append("plane-emoji-\(lineIndex)")
      }
      // Depth movement: the plane breathes (scale) and floats
      // (positionY loop) — nearer planes move more.
      let breathe = 1.0 + 0.06 * depthAmount + Double(tier) * 0.02
      builder.add(ExtraStyleNode(
        id: "plane-\(lineIndex)", kind: .group,
        children: members,
        position: panelCenter, anchor: .zero,
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        perspectiveCorners: corners,
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 1, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: (lineStartFrame + lineEndFrame) / 2, value: breathe, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: lineEndFrame, value: 1, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 180, periodParamId: "floatSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 90, value: -10 - Double(tier) * 4, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 180, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))

      // Face-tracked HUD: a reticle + lock label that follows
      // the face box. Base position (0, 0) when tracking (the
      // face tracks carry absolute canvas points); canvas
      // centre when tracking is off or no faces exist.
      let hasFaces = (input.maskIndex?.faces.isEmpty == false)
      let hudBase: CGPoint
      let hudTracks: [ExtraStyleTrack]
      if faceTracking, hasFaces {
        hudBase = .zero
        hudTracks = vrFaceTracks(
          maskIndex: input.maskIndex, fps: fps, canvas: canvas,
          startFrame: lineStartFrame, endFrame: lineEndFrame
        ) + [
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 150, periodParamId: "floatSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 75, value: -6, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      } else {
        hudBase = CGPoint(x: canvas.width / 2, y: canvas.height * 0.3)
        hudTracks = []
      }
      var hudMembers: [String] = []
      // Reticle corners around the origin (±44 pt).
      let reticleCorners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (-44, -44, 1, 1), (44, -44, -1, 1), (-44, 44, 1, -1), (44, 44, -1, -1),
      ]
      for (cornerIndex, corner) in reticleCorners.enumerated() {
        let (ox, oy, sx, sy) = corner
        let path = CGMutablePath()
        path.move(to: CGPoint(x: ox + sx * 22, y: oy))
        path.addLine(to: CGPoint(x: ox, y: oy))
        path.addLine(to: CGPoint(x: ox, y: oy + sy * 22))
        let cornerId = "hud-corner-\(lineIndex)-\(cornerIndex)"
        builder.addChild(ExtraStyleNode(
          id: cornerId, kind: .path,
          position: .zero, anchor: .zero, zIndex: 0,
          path: ExtraStylePathContent(
            path: path,
            strokeColor: panelColor.withAlpha(0.9),
            strokeWidth: 3,
            dash: nil
          )
        ))
        hudMembers.append(cornerId)
      }
      builder.addChild(extraStyleTextNode(
        id: "hud-label-\(lineIndex)",
        text: "SUBJECT LOCK", font: ExtraStyleFonts.mono,
        sizePoints: canvas.width * 0.024, color: panelColor,
        position: CGPoint(x: 0, y: -68),
        zIndex: 1,
        colorParamId: "panelColor"
      ))
      hudMembers.append("hud-label-\(lineIndex)")
      builder.add(ExtraStyleNode(
        id: "hud-\(lineIndex)", kind: .group,
        children: hudMembers,
        position: hudBase, anchor: .zero,
        zIndex: 20,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: hudTracks
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 15: Data Visualization (digital)

final class DataVisualizationExtraStyle: ExtraStyleDefinition {
  let id = "data-visualization"
  let version = 1
  let name = "Data Visualization"
  let tagline = "The song, charted live — bars, waves, counters."
  let category = "digital"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "chartStyle", label: "Chart",
        options: [("bars", "Bars"), ("wave", "Waveform"), ("both", "Both")],
        default: "both", affects: "layout"
      ),
      extraStyleColorParam(id: "accent", label: "Chart colour", default: "#C9F36B", affects: "appearance"),
      extraStyleSliderParam(
        id: "sensitivity", label: "Sensitivity", min: 0.5, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleNumberParam(
        id: "barCount", label: "Bar count", min: 4, max: 12, step: 1,
        default: 8, affects: "layout"
      ),
      extraStyleToggleParam(id: "showCounters", label: "Counters", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "bars-only", "label": "Bars only", "values": ["chartStyle": "bars"]],
      ["id": "wave-only", "label": "Wave only", "values": ["chartStyle": "wave"]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }
  var rebuildParamIds: [String] { ["barCount", "chartStyle", "showCounters"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    let sensitivity = extraStyleParamDouble(input.params, "sensitivity", 1)
    let barCount = max(4, min(12, Int(extraStyleParamDouble(input.params, "barCount", 8).rounded())))
    let chartStyle = extraStyleParamString(input.params, "chartStyle", "both")
    let showCounters = extraStyleParamBool(input.params, "showCounters", true)
    let showBars = chartStyle == "bars" || chartStyle == "both"
    let showWave = chartStyle == "wave" || chartStyle == "both"
    let automation = input.automation
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.04, g: 0.06, b: 0.06, a: 1),
        ExtraStyleRGBA(r: 0.01, g: 0.02, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Faint chart grid.
    for row in 0..<5 {
      let y = canvas.height * CGFloat(0.2 + Double(row) * 0.15)
      builder.add(extraStyleShapeNode(
        id: "grid-\(row)",
        shape: extraStyleRectShape(width: canvas.width, height: 1),
        fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.06),
        position: CGPoint(x: canvas.width / 2, y: y),
        zIndex: 1
      ))
    }

    // Bars: one shape node per bar, anchored at its bottom edge
    // so the scale track grows it upward from the baseline.
    // Each bar reads its own band's energy, sampled every 6
    // frames across the scene. Without automation (defensive
    // only — automation is required for this style) a seeded
    // sine pattern stands in.
    if showBars {
      let bandCount = automation.map { $0.bandEnergies(at: 0).count } ?? 0
      let barWidth = canvas.width * 0.9 / CGFloat(barCount) * 0.62
      let barHeight: CGFloat = 220
      let baselineY = canvas.height * 0.8
      for bar in 0..<barCount {
        let x = canvas.width * 0.05 + canvas.width * 0.9 * (CGFloat(bar) + 0.5) / CGFloat(barCount)
        let bandIndex = bandCount > 0 ? bar * bandCount / barCount : 0
        var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(0x4241_5200 + bar))
        let phase = random.nextDouble() * 2 * Double.pi
        var keys: [ExtraStyleKeyframe] = []
        var frame = 0
        while frame <= input.durationFrames {
          let seconds = Double(frame) / fps
          let value: Double
          if let automation, bandCount > 0 {
            let energies = automation.bandEnergies(at: seconds)
            let energy = bandIndex < energies.count ? energies[bandIndex] : 0
            value = max(0.12, min(1, energy * sensitivity * 1.4))
          } else {
            value = 0.35 + 0.3 * sin(Double(frame) / 18 + phase)
          }
          keys.append(ExtraStyleKeyframe(frame: frame, value: value, easing: .linear))
          frame += 6
        }
        builder.add(ExtraStyleNode(
          id: "bar-\(bar)", kind: .shape,
          position: CGPoint(x: x, y: baselineY),
          anchor: CGPoint(x: 0.5, y: 1),
          zIndex: 5,
          shape: ExtraStyleShapeContent(
            shape: extraStyleRectShape(width: barWidth, height: barHeight),
            fill: accent.withAlpha(0.55 + 0.45 * Double(bar) / Double(max(1, barCount))),
            fillColorParamId: "accent",
            stroke: nil, strokeWidth: 0
          ),
          tracks: [
            ExtraStyleTrack(property: .scale, kind: .keyframes(keys: keys), startFrame: 0),
          ]
        ))
      }
      // Baseline rule under the bars.
      builder.add(extraStyleShapeNode(
        id: "bar-baseline",
        shape: extraStyleRectShape(width: canvas.width * 0.9, height: 2),
        fill: accent.withAlpha(0.5),
        position: CGPoint(x: canvas.width / 2, y: baselineY),
        zIndex: 5,
        fillColorParamId: "accent"
      ))
    }

    // Waveform: 48 segments spanning the frame, each drawn from
    // the loudness curve at its time. The engine has no path
    // trim/progress, so draw progress is faked with per-segment
    // visible ranges — segments appear left to right across the
    // scene — and the whole waveform's opacity follows loudness.
    if showWave {
      let segmentCount = 48
      let waveY = canvas.height * 0.6
      let waveLeft = canvas.width * 0.05
      let waveWidth = canvas.width * 0.9
      var waveMembers: [String] = []
      for segment in 0..<segmentCount {
        let t0 = Double(segment) / Double(segmentCount)
        let t1 = Double(segment + 1) / Double(segmentCount)
        let seconds0 = t0 * Double(input.durationFrames) / fps
        let seconds1 = t1 * Double(input.durationFrames) / fps
        func wavePoint(t: Double, seconds: Double) -> CGPoint {
          let loudness = automation?.loudness(at: seconds) ?? -30
          let normalized = max(0, min(1, (loudness + 60) / 60))
          let amp = CGFloat(normalized * sensitivity) * canvas.height * 0.06
          // Alternate above/below the centre line for a wave look.
          let sign: CGFloat = segment % 2 == 0 ? -1 : 1
          return CGPoint(
            x: waveLeft + CGFloat(t) * waveWidth,
            y: waveY + sign * amp
          )
        }
        let path = CGMutablePath()
        path.move(to: wavePoint(t: t0, seconds: seconds0))
        path.addLine(to: wavePoint(t: t1, seconds: seconds1))
        let revealFrame = Int(Double(segment) / Double(segmentCount) * Double(input.durationFrames))
        let segmentId = "wave-seg-\(segment)"
        builder.addChild(ExtraStyleNode(
          id: segmentId, kind: .path,
          position: .zero, anchor: .zero, zIndex: 0,
          visibleRange: revealFrame...input.durationFrames,
          path: ExtraStylePathContent(
            path: path,
            strokeColor: accent,
            strokeWidth: 3,
            dash: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: revealFrame, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(input.durationFrames, revealFrame + 4), value: 1, easing: .linear),
              ]),
              startFrame: revealFrame
            ),
          ]
        ))
        waveMembers.append(segmentId)
      }
      // Centre line for the waveform.
      let centrePath = CGMutablePath()
      centrePath.move(to: CGPoint(x: waveLeft, y: waveY))
      centrePath.addLine(to: CGPoint(x: waveLeft + waveWidth, y: waveY))
      builder.addChild(ExtraStyleNode(
        id: "wave-centre", kind: .path,
        position: .zero, anchor: .zero, zIndex: 0,
        path: ExtraStylePathContent(
          path: centrePath,
          strokeColor: accent.withAlpha(0.3),
          strokeWidth: 1,
          dash: [6, 6]
        )
      ))
      waveMembers.append("wave-centre")
      builder.add(ExtraStyleNode(
        id: "waveform", kind: .group,
        children: waveMembers,
        position: .zero, anchor: .zero,
        zIndex: 6,
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .reaction(input: .loudness, base: 0.55, gain: 0.45),
            startFrame: 0
          ),
        ]
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centerY = canvas.height * 0.42

      // Counters: tempo (from the automation) and the line's
      // word count — the style's primary content is data.
      if showCounters {
        let tempo = automation?.tempoBpm ?? 0
        let tempoTarget = tempo > 0 ? tempo : 120
        for node in extraStyleCounterNodes(
          idPrefix: "bpm-\(lineIndex)", from: 0, to: tempoTarget, steps: 12,
          startFrame: lineStartFrame, endFrame: lineEndFrame,
          position: CGPoint(x: canvas.width * 0.32, y: canvas.height * 0.3),
          sizePoints: canvas.width * 0.055, color: accent,
          font: ExtraStyleFonts.mono, zIndex: 10,
          format: { String(format: "%.0f BPM", $0) }
        ) { builder.add(node) }
        let wordCount = max(1, line.words.count)
        for node in extraStyleCounterNodes(
          idPrefix: "words-\(lineIndex)", from: 0, to: Double(wordCount), steps: wordCount,
          startFrame: lineStartFrame, endFrame: lineEndFrame,
          position: CGPoint(x: canvas.width * 0.68, y: canvas.height * 0.3),
          sizePoints: canvas.width * 0.055, color: accent,
          font: ExtraStyleFonts.mono, zIndex: 10,
          format: { String(format: "%.0f WORDS", $0) }
        ) { builder.add(node) }
      }

      // The line itself, with a data chip underneath.
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.bold, sizePoints: canvas.width * 0.05,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: canvas.width / 2, y: centerY),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))
      let tone = (line.tone ?? "neutral").uppercased()
      builder.add(extraStyleTextNode(
        id: "chip-\(lineIndex)",
        text: "\(tone) · \(line.words.count) WORDS",
        font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.024,
        color: accent,
        position: CGPoint(x: canvas.width / 2, y: centerY + canvas.width * 0.055),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        colorParamId: "accent",
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 12, exitFrames: 12)]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (digital family)

extension ExtraStylesPhase3 {
  static func registerDigitalRest(into registry: ExtraStyleRegistry) {
    registry.register(DigitalCorruptionExtraStyle())
    registry.register(CyberTerminalExtraStyle())
    registry.register(VirtualRealityExtraStyle())
    registry.register(DataVisualizationExtraStyle())
  }
}
