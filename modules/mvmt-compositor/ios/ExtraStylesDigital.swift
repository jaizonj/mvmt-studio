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
// LYRIC-ONLY RE-SCOPE (Phase 4, Jaizon 2026-11-13 ~10:28 MST:
// "no styles that take up the whole screen just lyrics with cool
// animations" — the video is the star): every style below is now
// lyrics with kinetic/digital animation ONLY. Full-screen
// backgrounds, noise fields, displacement waves, scanlines,
// terminal panels, floor grids, perspective planes, face-tracked
// HUDs and full-frame charts are gone; what remains is
// word-attached (RGB-split glitch slices on the line itself, a
// typing caret, tiny bars under the line, depth-drifted words).
// Virtual Reality's face tracking is retired with its HUD, so
// its needsSubjectMasks flag is now false. (Holographic
// Interface, the 5th digital style, lives in
// ExtraStylesDemos.swift — not this file.)
//
// Flags (STYLE_CAPABILITY_MAP, src/lib/extra-styles/catalog.ts,
// authoritative): Digital Corruption and Data Visualization
// REQUIRE audio automation (needsAudioAutomation = true —
// automation is supplied, so bars/glitch bursts read it
// directly); Cyber Terminal needs neither audio nor masks.

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

/// Append a keyframe only when its frame is strictly after the
/// previous key's frame — clamped schedules (short lines/words)
/// must never emit duplicate-frame keys.
private func digitalAppendKeyframe(
  _ keys: inout [ExtraStyleKeyframe], frame: Int, value: Double, easing: ExtraStyleEasing
) {
  guard keys.isEmpty || frame > keys[keys.count - 1].frame else { return }
  keys.append(ExtraStyleKeyframe(frame: frame, value: value, easing: easing))
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
      extraStyleColorParam(id: "accent", label: "Glitch colour", default: "#FF2E63", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "subtle", "label": "Subtle", "values": ["glitchIntensity": 0.35, "splitAmount": 3]],
      ["id": "meltdown", "label": "Meltdown", "values": ["glitchIntensity": 1, "splitAmount": 14]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }
  var rebuildParamIds: [String] { ["glitchIntensity", "splitAmount"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let intensity = extraStyleParamDouble(input.params, "glitchIntensity", 0.7)
    let split = extraStyleParamDouble(input.params, "splitAmount", 6)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FF2E63"))
    var builder = ExtraStyleSceneBuilder()

    // LYRIC-ONLY: no background, no full-frame noise field, no
    // full-frame displacement wave (it distorted the video
    // itself), no full-width scanlines. The corruption lives on
    // the lyric line: RGB-split copies, masked glitch slices of
    // the line itself, and an onset-driven pop.

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

      // Base copy: warm white, small jitter, dark outline so
      // it stays legible over any footage.
      builder.add(extraStyleTextNode(
        id: "base-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 0.9),
        position: center, zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        strokeColor: ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0.9),
        strokeWidthPoints: 2,
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

      // The line's stored emoji, glitched at the line's end
      // (was floating at the frame edge, detached from the lyric).
      if let emojiNode = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width * 0.94, center.x + textWidth / 2 + sizePoints),
          y: center.y
        ),
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
      extraStyleToggleParam(id: "cursorBlink", label: "Blinking cursor", default: true, affects: "motion"),
      extraStyleToggleParam(id: "systemLines", label: "System messages", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "matrix", "label": "Matrix", "values": ["accent": "#33FF66", "typingSpeed": 1.2]],
      ["id": "amber", "label": "Amber", "values": ["accent": "#FFB000", "typingSpeed": 0.8]],
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

    // LYRIC-ONLY: no background, no terminal panel (frame /
    // header / scanlines), no full-width scan sweep, no boot
    // line. What remains is the typing itself: per-char reveal,
    // a travelling block caret, a ">" prompt at the line's left
    // edge, small system-message lines above the lyric, and one
    // small corner tag as the only chrome.
    builder.add(extraStyleTextNode(
      id: "corner-tag",
      text: "MVMT://TERM", font: ExtraStyleFonts.mono,
      sizePoints: canvas.width * 0.024, color: accent.withAlpha(0.75),
      position: CGPoint(x: canvas.width * 0.09, y: canvas.height * 0.055),
      zIndex: 5, colorParamId: "accent"
    ))

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
      for char in chars {
        var stroked = char
        stroked.text?.strokeColor = ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0.9)
        stroked.text?.strokeWidthPoints = 2
        builder.add(stroked)
      }

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

      // Prompt marker at the typed line's left edge for the
      // active line (was pinned to a fixed frame position).
      builder.add(extraStyleTextNode(
        id: "prompt-\(lineIndex)",
        text: ">", font: ExtraStyleFonts.mono, sizePoints: sizePoints,
        color: accent,
        position: CGPoint(x: max(14, leftEdgeX - 18), y: lineY),
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
  let tagline = "Lyrics drift in depth — near, mid and far planes."
  let category = "digital"
  let needsAudioAutomation = false
  // RETIRED+REPLACED (Phase 4 lyric-only re-scope): the
  // face-tracked HUD and perspective planes are gone, so this
  // style no longer needs subject masks.
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "depthAmount", label: "Depth drift", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "layout"
      ),
      extraStyleColorParam(id: "panelColor", label: "Accent colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleSliderParam(
        id: "floatSpeed", label: "Float speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "deep", "label": "Deep", "values": ["depthAmount": 1, "floatSpeed": 0.6]],
      ["id": "near", "label": "Near", "values": ["depthAmount": 0.35, "floatSpeed": 1.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }
  var rebuildParamIds: [String] { ["depthAmount"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let depthAmount = extraStyleParamDouble(input.params, "depthAmount", 0.7)
    let panelColor = extraStyleColor(extraStyleParamString(input.params, "panelColor", "#7DF9FF"))
    var builder = ExtraStyleSceneBuilder()

    // LYRIC-ONLY REPLACEMENT (the old concept — near-full-frame
    // perspective planes, a floor grid, and a face-tracked HUD
    // reticle — cannot exist without taking over the frame, so it
    // is retired): depth is now a property of the words. Lines
    // cycle near / mid / far tiers — nearer lines render larger
    // and drift more, farther lines smaller and calmer — with a
    // gentle parallax float. No background, no grid, no planes,
    // no HUD, no face tracking, no masks.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let tier = lineIndex % 3
      // Near tier 0 renders largest, far tier 2 smallest; the
      // spread scales with depthAmount (0 = all tiers equal).
      let tierScale = 1 + CGFloat(1 - tier) * 0.12 * CGFloat(depthAmount)
      let drift = (12 - Double(tier) * 4) * depthAmount + 2
      let sizePoints = canvas.width * 0.055 * tierScale
      let centerY = canvas.height * 0.5
      let ink = ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0.9)
      let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)

      let wordNodes = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints,
        color: warmWhite,
        font: ExtraStyleFonts.bold, zIndex: 10, canvasWidth: canvas.width
      ) { _, wordStart, wordEnd in
        [
          extraStyleSpringInTrack(start: wordStart, from: 0.6, stiffness: 140, damping: 11),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 180, periodParamId: "floatSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 90, value: -drift, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 180, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: wordStart
          ),
          ExtraStyleTrack(
            property: .positionX,
            kind: .loop(periodFrames: 240, periodParamId: "floatSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 120, value: drift * 0.6, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: wordStart
          ),
          extraStyleEnterExitOpacityTrack(start: wordStart, end: wordEnd, enterFrames: 8, exitFrames: 8),
        ]
      }
      if wordNodes.isEmpty {
        builder.add(extraStyleTextNode(
          id: "vr-line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.bold, sizePoints: sizePoints,
          color: warmWhite,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: ink, strokeWidthPoints: 2,
          tracks: [
            extraStyleSpringInTrack(start: lineStartFrame, from: 0.6, stiffness: 140, damping: 11),
            ExtraStyleTrack(
              property: .positionY,
              kind: .loop(periodFrames: 180, periodParamId: "floatSpeed", keys: [
                ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 90, value: -drift, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 180, value: 0, easing: .easeInOutSine),
              ]),
              startFrame: lineStartFrame
            ),
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 10, exitFrames: 10),
          ]
        ))
        continue
      }
      for wordNode in wordNodes {
        var node = wordNode
        node.text?.strokeColor = ink
        node.text?.strokeWidthPoints = 2
        let wordIndex = node.id.split(separator: "-").last.flatMap { Int($0) } ?? -1
        if line.emphasisWordIndices.contains(wordIndex) {
          node.text?.color = panelColor
          node.text?.colorParamId = "panelColor"
          if let size = node.text?.sizePoints { node.text?.sizePoints = size * 1.15 }
        }
        builder.add(node)
      }

      // The line's stored emoji, small, at the line's end.
      let lineWidth: CGFloat = {
        let font = ExtraStyleFonts.bold
        if line.words.isEmpty {
          return extraStyleTextWidth(line.text, fontPostScriptName: font, sizePoints: sizePoints)
        }
        let space = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
        return line.words.map {
          extraStyleTextWidth($0.text, fontPostScriptName: font, sizePoints: sizePoints)
        }.reduce(0, +) + space * CGFloat(max(0, line.words.count - 1))
      }()
      if let emojiNode = extraStyleEmojiNode(
        id: "vr-emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width * 0.94, canvas.width / 2 + lineWidth / 2 + sizePoints * 0.8),
          y: centerY
        ),
        sizePoints: sizePoints * 0.9, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(emojiNode)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 15: Data Visualization (digital)

final class DataVisualizationExtraStyle: ExtraStyleDefinition {
  let id = "data-visualization"
  let version = 1
  let name = "Data Visualization"
  let tagline = "Tiny live bars under the line — the song, charted small."
  let category = "digital"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "accent", label: "Chart colour", default: "#C9F36B", affects: "appearance"),
      extraStyleSliderParam(
        id: "sensitivity", label: "Sensitivity", min: 0.5, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleToggleParam(id: "showCounters", label: "Counters", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "gentle", "label": "Gentle", "values": ["sensitivity": 0.6]],
      ["id": "intense", "label": "Intense", "values": ["sensitivity": 1.8]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }
  var rebuildParamIds: [String] { ["showCounters"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    let sensitivity = extraStyleParamDouble(input.params, "sensitivity", 1)
    let showCounters = extraStyleParamBool(input.params, "showCounters", true)
    let automation = input.automation
    let bandCount = automation.map { $0.bandEnergies(at: 0).count } ?? 0
    var builder = ExtraStyleSceneBuilder()

    // LYRIC-ONLY: no background, no faint full-frame chart grid,
    // no full-width bars, no 48-segment full-width waveform, no
    // animated BPM/word counters floating above the line. The
    // chart shrinks to the lyric: karaoke words that dim once
    // sung, 8 tiny bars under the line reading the song's band
    // energies, and one small data chip under the bars.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.05
      let centerY = canvas.height * 0.42
      let ink = ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0.9)
      let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
      let font = ExtraStyleFonts.bold

      // Word layout (measured, centred). Nodes are built
      // manually — not via extraStyleWordNodes — because karaoke
      // needs each word to stay visible for the whole line: a
      // sung word dims to 0.6 once the next word starts instead
      // of vanishing at its own end frame.
      let entryTexts: [String] = line.words.isEmpty ? [line.text] : line.words.map { $0.text }
      let entryStarts: [Double] = line.words.isEmpty ? [line.startSeconds] : line.words.map { $0.startSeconds }
      let entryEnds: [Double] = line.words.isEmpty ? [line.endSeconds] : line.words.map { $0.endSeconds }
      let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
      let widths = entryTexts.map { extraStyleTextWidth($0, fontPostScriptName: font, sizePoints: sizePoints) }
      let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, entryTexts.count - 1))
      var cursorX = (canvas.width - totalWidth) / 2
      for (index, wordText) in entryTexts.enumerated() {
        let wordWidth = widths[index]
        defer { cursorX += wordWidth + spaceWidth }
        let wordStartFrame = max(lineStartFrame, Int((entryStarts[index] * fps).rounded()))
        let wordEndFrame = min(lineEndFrame, Int((entryEnds[index] * fps).rounded()))
        let startFrame = wordEndFrame > wordStartFrame
          ? wordStartFrame : min(lineEndFrame - 1, lineStartFrame + index * 3)
        guard lineEndFrame > startFrame else { continue }
        let isEmphasis = line.emphasisWordIndices.contains(index)
        // Karaoke opacity: 0 until sung, 1 while current, 0.6
        // after the next word starts (this word's end when
        // timings are contiguous), out at the line end.
        var opacityKeys: [ExtraStyleKeyframe] = []
        digitalAppendKeyframe(&opacityKeys, frame: startFrame, value: 0, easing: .linear)
        digitalAppendKeyframe(&opacityKeys, frame: min(lineEndFrame, startFrame + 4), value: 1, easing: .easeOutCubic)
        let dimFrame = max(wordEndFrame, startFrame + 5)
        if dimFrame < lineEndFrame {
          digitalAppendKeyframe(&opacityKeys, frame: dimFrame, value: 1, easing: .linear)
          digitalAppendKeyframe(&opacityKeys, frame: min(lineEndFrame, dimFrame + 6), value: 0.6, easing: .easeInOutSine)
        }
        digitalAppendKeyframe(&opacityKeys, frame: lineEndFrame, value: 0, easing: .easeInCubic)
        builder.add(extraStyleTextNode(
          id: "viz-word-\(lineIndex)-\(index)",
          text: wordText, font: font,
          sizePoints: isEmphasis ? sizePoints * 1.12 : sizePoints,
          color: isEmphasis ? accent : warmWhite,
          position: CGPoint(x: cursorX + wordWidth / 2, y: centerY),
          zIndex: 10,
          visibleRange: startFrame...lineEndFrame,
          strokeColor: ink, strokeWidthPoints: 2,
          colorParamId: isEmphasis ? "accent" : nil,
          tracks: [
            extraStyleSpringInTrack(start: startFrame, from: isEmphasis ? 0.5 : 0.7, stiffness: 160, damping: 11),
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: opacityKeys),
              startFrame: startFrame
            ),
          ]
        ))
      }

      // Tiny bars under the lyric line: 8 small bars reading the
      // song's band energies across the line window — a chart the
      // size of the lyric, not a full-screen one. Without
      // automation (defensive only — automation is required for
      // this style) a seeded sine pattern stands in.
      let miniBarCount = 8
      let miniBarWidth = totalWidth / CGFloat(miniBarCount) * 0.62
      let miniBarHeight: CGFloat = 26
      let miniBaselineY = centerY + sizePoints * 1.25
      for bar in 0..<miniBarCount {
        let x = canvas.width / 2 - totalWidth / 2 + totalWidth * (CGFloat(bar) + 0.5) / CGFloat(miniBarCount)
        let bandIndex = bandCount > 0 ? bar * bandCount / miniBarCount : 0
        var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(0x4241_5200 + bar))
        let phase = random.nextDouble() * 2 * Double.pi
        var keys: [ExtraStyleKeyframe] = []
        var frame = lineStartFrame
        while frame <= lineEndFrame {
          let seconds = Double(frame) / fps
          let value: Double
          if let automation, bandCount > 0 {
            let energies = automation.bandEnergies(at: seconds)
            let energy = bandIndex < energies.count ? energies[bandIndex] : 0
            value = max(0.15, min(1, energy * sensitivity * 1.4))
          } else {
            value = 0.35 + 0.3 * sin(Double(frame) / 18 + phase)
          }
          keys.append(ExtraStyleKeyframe(frame: frame, value: value, easing: .linear))
          frame += 6
        }
        builder.add(ExtraStyleNode(
          id: "minibar-\(lineIndex)-\(bar)", kind: .shape,
          position: CGPoint(x: x, y: miniBaselineY),
          anchor: CGPoint(x: 0.5, y: 1),
          zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          shape: ExtraStyleShapeContent(
            shape: extraStyleRectShape(width: miniBarWidth, height: miniBarHeight),
            fill: accent.withAlpha(0.45 + 0.5 * Double(bar) / Double(max(1, miniBarCount))),
            fillColorParamId: "accent",
            stroke: nil, strokeWidth: 0
          ),
          tracks: [
            ExtraStyleTrack(property: .scale, kind: .keyframes(keys: keys), startFrame: lineStartFrame),
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 6, exitFrames: 6),
          ]
        ))
      }

      // One small data chip under the bars (was two animated
      // counters floating above the line).
      if showCounters {
        let tempo = automation?.tempoBpm ?? 0
        let tempoText = tempo > 0 ? String(format: "%.0f BPM", tempo) : "— BPM"
        let tone = (line.tone ?? "neutral").uppercased()
        builder.add(extraStyleTextNode(
          id: "chip-\(lineIndex)",
          text: "\(tone) · \(tempoText) · \(line.words.count) WORDS",
          font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.024,
          color: accent,
          position: CGPoint(x: canvas.width / 2, y: miniBaselineY + 34),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          colorParamId: "accent",
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 12, exitFrames: 12)]
        ))
      }

      // The line's stored emoji, small, at the line's end.
      if let emojiNode = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width * 0.94, canvas.width / 2 + totalWidth / 2 + sizePoints * 0.8),
          y: centerY
        ),
        sizePoints: sizePoints * 0.9, zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(emojiNode)
      }
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
