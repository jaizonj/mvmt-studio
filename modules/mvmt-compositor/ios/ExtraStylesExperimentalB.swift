import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 4 re-scope, Experimental family, part B
//
// Styles 36–40 (docs/EXTRA-STYLES-2.0.md §17):
//   36 Blueprint World, 37 Kinetic Sculpture, 38 Mirror World,
//   39 Living Typography, 40 Reality Distortion.
//
// LYRIC-ONLY (Jaizon, 2026-11-13 ~10:28 MST): "no styles that take
// up the whole screen just lyrics with cool animations and stuff."
// The video is the star, so every style here is now lyrics with
// cool animation — no full-screen blueprint grid, no large
// sculpture composition, no full-frame displacement. What
// survives, reinterpreted:
//   Blueprint World — the lyric drawn up like a plan: frame,
//     diagonals, corner crosses, dimension lines and measurement
//     labels, all sized to the lyric block (grid removed).
//   Kinetic Sculpture — the big sculpture is gone; the words
//     themselves orbit in and assemble on the line, with one
//     small ring accent sized to the lyric block.
//   Mirror World — already lyric-only in spirit: the main line
//     (now word-by-word) plus its faint same-direction echo
//     below the mirror line. NOTE: the echo is NOT reversed —
//     the engine has no non-uniform scale, so a true glyph flip
//     is impossible, and reversed text as a lyric line is banned
//     (Jaizon's 2026-11-13 mirrored-lyrics report); the echo is
//     a squashed, faded same-direction copy, clearly secondary.
//   Living Typography — characters growing with loudness (was
//     already lyric-led); the vine and branches now span the
//     lyric block only, not the full frame.
//   Reality Distortion — the full-frame displacement wave is
//     GONE (displacement distorts the whole composed frame,
//     video included — there is no text-only displacement); the
//     wave is faked with per-word tilt/push/settle plus a baked
//     sine wobble on the words only.
//
// Legibility: every lyric node gets a dark outline stroke (the
// engine has no blur/glow property). Emphasis words (stored
// lyric intelligence) pop in the style's accent colour.
//
// Flags match the authoritative TS static map
// (src/lib/extra-styles/catalog.ts STYLE_CAPABILITY_MAP): only
// Living Typography and Reality Distortion need audio automation
// (both TRUE / FALSE); the other three are FALSE / FALSE — no
// flag changes in this file.

// MARK: - Shared helpers (this file only)

/// Dark outline every lyric node gets, so words read over any footage.
private let experimentalBInkOutline = ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.07, a: 1)

/// Return a copy of a text node with an outline stroke applied.
/// `extraStyleWordNodes` / `extraStyleCharNodes` take no stroke
/// argument, so strokes on helper-built nodes go through here.
private func experimentalBStroked(
  _ node: ExtraStyleNode, color: ExtraStyleRGBA, width: CGFloat
) -> ExtraStyleNode {
  var copy = node
  copy.text?.strokeColor = color
  copy.text?.strokeWidthPoints = width
  return copy
}

// MARK: - Style 36: Blueprint World (experimental)

/// The lyric, drawn up like a plan: a diagram frame around the
/// lyric line, construction diagonals, corner crosses, dimension
/// lines with measurement labels, and a draw-head dot travelling
/// the frame perimeter. The full-frame blueprint grid is gone —
/// every remaining line is sized to the lyric block. The lyric
/// itself is now per-word nodes (mono, springing in at their sung
/// start), so emphasis words can print in the line colour; the
/// size shrinks to fit long lines inside the frame.
final class BlueprintWorldExtraStyle: ExtraStyleDefinition {
  let id = "blueprint-world"
  let version = 1
  let name = "Blueprint World"
  let tagline = "The lyric, drawn up like a plan — construction lines and measurements included."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "lineColor", label: "Line colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleToggleParam(id: "showMeasurements", label: "Measurement labels", default: true, affects: "layout"),
      extraStyleSliderParam(
        id: "drawSpeed", label: "Draw speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "technical", "label": "Technical", "values": ["lineColor": "#7DF9FF", "showMeasurements": true]],
      ["id": "minimal", "label": "Minimal", "values": ["lineColor": "#F4F1E9", "showMeasurements": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["showMeasurements", "drawSpeed"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let lineColor = extraStyleColor(extraStyleParamString(input.params, "lineColor", "#7DF9FF"))
    let showMeasurements = extraStyleParamBool(input.params, "showMeasurements", true)
    let drawSpeed = max(0.25, extraStyleParamDouble(input.params, "drawSpeed", 1))
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let baseSizePoints = canvas.width * 0.055
      let centerY = canvas.height * 0.5
      let frameWidth = canvas.width * 0.84
      // Shrink the type to fit long lines inside the frame.
      let sizePoints: CGFloat = {
        guard !line.words.isEmpty else { return baseSizePoints }
        let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.mono, sizePoints: baseSizePoints)
        let widths = line.words.map { extraStyleTextWidth($0.text, fontPostScriptName: ExtraStyleFonts.mono, sizePoints: baseSizePoints) }
        let total = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, line.words.count - 1))
        guard total > frameWidth * 0.92, total > 0 else { return baseSizePoints }
        return baseSizePoints * frameWidth * 0.92 / total
      }()
      let frameHeight = sizePoints * 3.4
      let frameX = (canvas.width - frameWidth) / 2
      let frameTop = centerY - frameHeight / 2
      let frameBottom = centerY + frameHeight / 2
      // Stagger step for the staged draw-on (frames between
      // construction lines appearing); drawSpeed is a rebuild
      // param, so this is baked at build time.
      let stagger = max(2, Int((6 / drawSpeed).rounded()))
      let emphasis = Set(line.emphasisWordIndices)

      // The diagram frame (rect outline, no fill).
      builder.add(extraStyleShapeNode(
        id: "frame-\(lineIndex)",
        shape: extraStyleRectShape(width: frameWidth, height: frameHeight),
        fill: nil,
        stroke: lineColor.withAlpha(0.85), strokeWidth: 2,
        position: CGPoint(x: canvas.width / 2, y: centerY), zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))

      // Construction lines: the two diagonals of the frame, each
      // fading in at its own staggered start — the staged-opacity
      // stand-in for path progress (no path-progress track kind
      // exists in the engine).
      let diagonalPath = CGMutablePath()
      diagonalPath.move(to: CGPoint(x: frameX, y: frameTop))
      diagonalPath.addLine(to: CGPoint(x: frameX + frameWidth, y: frameBottom))
      diagonalPath.move(to: CGPoint(x: frameX + frameWidth, y: frameTop))
      diagonalPath.addLine(to: CGPoint(x: frameX, y: frameBottom))
      builder.add(ExtraStyleNode(
        id: "diagonals-\(lineIndex)", kind: .path,
        position: .zero, anchor: .zero, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame,
        path: ExtraStylePathContent(
          path: diagonalPath,
          strokeColor: lineColor.withAlpha(0.45),
          strokeWidth: 1.5, dash: [8, 6]
        ),
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame + stagger, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + stagger * 2), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 9), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))

      // Corner crosses at the four frame corners.
      let crossPath = CGMutablePath()
      let crossArm: CGFloat = 14
      for corner in [
        CGPoint(x: frameX, y: frameTop),
        CGPoint(x: frameX + frameWidth, y: frameTop),
        CGPoint(x: frameX, y: frameBottom),
        CGPoint(x: frameX + frameWidth, y: frameBottom),
      ] {
        crossPath.move(to: CGPoint(x: corner.x - crossArm, y: corner.y))
        crossPath.addLine(to: CGPoint(x: corner.x + crossArm, y: corner.y))
        crossPath.move(to: CGPoint(x: corner.x, y: corner.y - crossArm))
        crossPath.addLine(to: CGPoint(x: corner.x, y: corner.y + crossArm))
      }
      builder.add(ExtraStyleNode(
        id: "corners-\(lineIndex)", kind: .path,
        position: .zero, anchor: .zero, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame,
        path: ExtraStylePathContent(
          path: crossPath,
          strokeColor: lineColor.withAlpha(0.9),
          strokeWidth: 2, dash: nil
        ),
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame + stagger * 2, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + stagger * 3), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .linear),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))

      // Dimension arrows + measurement labels.
      if showMeasurements {
        let dimPath = CGMutablePath()
        // Top dimension line with end ticks.
        dimPath.move(to: CGPoint(x: frameX, y: frameTop - 28))
        dimPath.addLine(to: CGPoint(x: frameX + frameWidth, y: frameTop - 28))
        dimPath.move(to: CGPoint(x: frameX, y: frameTop - 36))
        dimPath.addLine(to: CGPoint(x: frameX, y: frameTop - 20))
        dimPath.move(to: CGPoint(x: frameX + frameWidth, y: frameTop - 36))
        dimPath.addLine(to: CGPoint(x: frameX + frameWidth, y: frameTop - 20))
        // Right dimension line with end ticks.
        dimPath.move(to: CGPoint(x: frameX + frameWidth + 28, y: frameTop))
        dimPath.addLine(to: CGPoint(x: frameX + frameWidth + 28, y: frameBottom))
        dimPath.move(to: CGPoint(x: frameX + frameWidth + 20, y: frameTop))
        dimPath.addLine(to: CGPoint(x: frameX + frameWidth + 36, y: frameTop))
        dimPath.move(to: CGPoint(x: frameX + frameWidth + 20, y: frameBottom))
        dimPath.addLine(to: CGPoint(x: frameX + frameWidth + 36, y: frameBottom))
        builder.add(ExtraStyleNode(
          id: "dimensions-\(lineIndex)", kind: .path,
          position: .zero, anchor: .zero, zIndex: 11,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: dimPath,
            strokeColor: lineColor.withAlpha(0.7),
            strokeWidth: 1.5, dash: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame + stagger * 3, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + stagger * 4), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .linear),
              ]),
              startFrame: lineStartFrame
            ),
          ]
        ))
        let widthLabel = String(format: "W %.0f pt", Double(frameWidth))
        builder.add(extraStyleTextNode(
          id: "measure-w-\(lineIndex)",
          text: widthLabel, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
          color: lineColor,
          position: CGPoint(x: canvas.width / 2, y: frameTop - 48),
          zIndex: 12, visibleRange: lineStartFrame...lineEndFrame,
          colorParamId: "lineColor",
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame + stagger * 3, end: lineEndFrame)]
        ))
        let heightLabel = String(format: "H %.0f pt", Double(frameHeight))
        builder.add(extraStyleTextNode(
          id: "measure-h-\(lineIndex)",
          text: heightLabel, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
          color: lineColor,
          position: CGPoint(x: frameX + frameWidth + 52, y: centerY),
          zIndex: 12, visibleRange: lineStartFrame...lineEndFrame,
          colorParamId: "lineColor",
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame + stagger * 3, end: lineEndFrame)]
        ))
        let durationLabel = String(format: "%.1fs", line.endSeconds - line.startSeconds)
        builder.add(extraStyleTextNode(
          id: "measure-t-\(lineIndex)",
          text: durationLabel, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
          color: lineColor,
          position: CGPoint(x: canvas.width / 2, y: frameBottom + 30),
          zIndex: 12, visibleRange: lineStartFrame...lineEndFrame,
          colorParamId: "lineColor",
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame + stagger * 3, end: lineEndFrame)]
        ))
      }

      // Draw-head dot: travels the frame perimeter on a .path
      // track (positionX only — it drives both axes), so the
      // frame reads as being drawn rather than appearing whole.
      var perimeter: [CGPoint] = []
      var px = frameX
      while px <= frameX + frameWidth {
        perimeter.append(CGPoint(x: px, y: frameTop))
        px += 90
      }
      var py = frameTop
      while py <= frameBottom {
        perimeter.append(CGPoint(x: frameX + frameWidth, y: py))
        py += 90
      }
      px = frameX + frameWidth
      while px >= frameX {
        perimeter.append(CGPoint(x: px, y: frameBottom))
        px -= 90
      }
      py = frameBottom
      while py >= frameTop {
        perimeter.append(CGPoint(x: frameX, y: py))
        py -= 90
      }
      builder.add(extraStyleShapeNode(
        id: "drawhead-\(lineIndex)",
        shape: extraStyleEllipseShape(width: 16, height: 16),
        fill: lineColor,
        position: .zero, zIndex: 14,
        visibleRange: lineStartFrame...lineEndFrame,
        fillColorParamId: "lineColor",
        tracks: [
          ExtraStyleTrack(
            property: .positionX,
            kind: .path(points: perimeter, durationFrames: max(15, lineEndFrame - lineStartFrame), easing: .linear),
            startFrame: lineStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 4, exitFrames: 4),
        ]
      ))

      // The line itself, in the middle of the plan — per-word
      // nodes springing in at their sung start; emphasis words
      // print in the line colour.
      if line.words.isEmpty {
        builder.add(extraStyleTextNode(
          id: "line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 13, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: frameWidth * 0.92,
          strokeColor: experimentalBInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
        ))
      } else {
        let wordNodes = extraStyleWordNodes(
          line: line, lineIndex: lineIndex, fps: fps,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: centerY, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          font: ExtraStyleFonts.mono, zIndex: 13, canvasWidth: canvas.width
        ) { _, wordStartFrame, wordEndFrame in
          [
            extraStyleSpringInTrack(start: wordStartFrame, from: 0.4, stiffness: 180, damping: 11),
            extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
          ]
        }
        for (wordIndex, wordNode) in wordNodes.enumerated() {
          var node = experimentalBStroked(wordNode, color: experimentalBInkOutline, width: max(2, sizePoints * 0.05))
          if emphasis.contains(wordIndex) {
            node.text?.color = lineColor
          }
          builder.add(node)
        }
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 37: Kinetic Sculpture (experimental)

/// The words themselves are the sculpture now: each word orbits
/// in from a seeded offset and assembles onto the lyric line
/// (rings = gentle settle, orbit = wide arc, cubes = tumble),
/// with one small thin ring accent sized to the lyric block,
/// rotating slowly behind the words. The old sculpture — large
/// rings, diamond, cubes, orbit dots, 2.5D perspective tilt —
/// is gone; it was a full-scene composition, not lyrics.
final class KineticSculptureExtraStyle: ExtraStyleDefinition {
  let id = "kinetic-sculpture"
  let version = 1
  let name = "Kinetic Sculpture"
  let tagline = "The words orbit in and assemble on the line."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "shapeStyle", label: "Entrance",
        options: [("rings", "Assemble"), ("cubes", "Tumble"), ("orbit", "Orbit")],
        default: "rings", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "spinSpeed", label: "Spin speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C9F36B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "slow-rings", "label": "Slow Rings", "values": ["shapeStyle": "rings", "spinSpeed": 0.5]],
      ["id": "fast-orbit", "label": "Fast Orbit", "values": ["shapeStyle": "orbit", "spinSpeed": 1.6]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["shapeStyle"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let shapeStyle = extraStyleParamString(input.params, "shapeStyle", "rings")
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centerY = canvas.height * 0.55
      let sizePoints = canvas.width * 0.06
      let emphasis = Set(line.emphasisWordIndices)

      // Lyric block width, measured from the words — the small
      // ring accent is sized to exactly this.
      let blockWidth: CGFloat = {
        if line.words.isEmpty {
          return extraStyleTextWidth(line.text, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints) + 64
        }
        let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
        let widths = line.words.map { extraStyleTextWidth($0.text, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints) }
        return widths.reduce(0, +) + spaceWidth * CGFloat(max(0, line.words.count - 1)) + 64
      }()
      builder.add(extraStyleShapeNode(
        id: "orbit-ring-\(lineIndex)",
        shape: extraStyleEllipseShape(width: blockWidth, height: sizePoints * 2.6),
        fill: nil,
        stroke: accent.withAlpha(0.6), strokeWidth: 2,
        position: CGPoint(x: canvas.width / 2, y: centerY),
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        fillColorParamId: nil,
        tracks: [
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .loop(periodFrames: 240, periodParamId: "spinSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: 240, value: 360, easing: .linear),
            ]),
            startFrame: lineStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
        ]
      ))

      guard !line.words.isEmpty else {
        builder.add(extraStyleTextNode(
          id: "line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: experimentalBInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
        ))
        continue
      }

      // Words orbit in and assemble: per-word entrance keyframes
      // from a seeded orbital offset, settling onto the line.
      let wordNodes = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStartFrame, wordEndFrame in
        var wordRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 1000 + index * 17 + 7))
        let settleFrame = min(wordEndFrame, wordStartFrame + 14)
        var tracks: [ExtraStyleTrack] = [
          extraStyleSpringInTrack(start: wordStartFrame, from: 0.4, stiffness: 180, damping: 11),
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
        switch shapeStyle {
        case "orbit":
          let angle = wordRandom.nextDouble() * 2 * Double.pi
          let dx = cos(angle) * 120
          let dy = sin(angle) * 80
          tracks.append(ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: dx, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ))
          tracks.append(ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: dy, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ))
        case "cubes":
          let tumble = Double(index % 2 == 0 ? -90 : 90)
          tracks.append(ExtraStyleTrack(
            property: .rotationDeg,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: tumble, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ))
          tracks.append(ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: -sizePoints * 1.2, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ))
        default: // "rings" — gentle assemble from above.
          tracks.append(ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: -sizePoints * 1.1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ))
          tracks.append(ExtraStyleTrack(
            property: .rotationDeg,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: Double(index % 2 == 0 ? -6 : 6), easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ))
        }
        return tracks
      }
      for (wordIndex, wordNode) in wordNodes.enumerated() {
        var node = experimentalBStroked(wordNode, color: experimentalBInkOutline, width: max(2, sizePoints * 0.05))
        if emphasis.contains(wordIndex) {
          node.text?.color = accent
        }
        builder.add(node)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 38: Mirror World (experimental)

/// Every line splits into its own reflection — now word by
/// word on the main line, with the faint echo below the mirror
/// line kept as a whole-line copy. The echo is a squashed
/// (uniform 0.62×), faded SAME-DIRECTION copy: a true vertical
/// flip needs non-uniform scale, which the engine does not have,
/// and reversed/mirrored text must never be the lyric line
/// (Jaizon's 2026-11-13 mirrored-lyrics report). The mirror
/// rule, the darkening wash over the echo band, and the symmetry
/// ornaments are all sized to the lyric block.
final class MirrorWorldExtraStyle: ExtraStyleDefinition {
  let id = "mirror-world"
  let version = 1
  let name = "Mirror World"
  let tagline = "Every line splits into its own reflection."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "reflectionOpacity", label: "Reflection strength", min: 0, max: 0.6, step: 0.05,
        default: 0.3, affects: "appearance"
      ),
      extraStyleSliderParam(
        id: "mirrorPosition", label: "Mirror line", min: 0.5, max: 0.7, step: 0.01,
        default: 0.58, affects: "layout"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleToggleParam(id: "symmetry", label: "Symmetry ornaments", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "still-water", "label": "Still Water", "values": ["reflectionOpacity": 0.15, "mirrorPosition": 0.58]],
      ["id": "deep-mirror", "label": "Deep Mirror", "values": ["reflectionOpacity": 0.5, "mirrorPosition": 0.62]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["mirrorPosition", "symmetry"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#7DF9FF"))
    let mirrorPosition = extraStyleParamDouble(input.params, "mirrorPosition", 0.58)
    let showSymmetry = extraStyleParamBool(input.params, "symmetry", true)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.06
      let mirrorY = canvas.height * CGFloat(mirrorPosition)
      let mainY = mirrorY - canvas.height * 0.07
      let reflectionY = mirrorY + canvas.height * 0.07
      let emphasis = Set(line.emphasisWordIndices)

      // The mirror line itself.
      let rulePath = CGMutablePath()
      rulePath.move(to: CGPoint(x: canvas.width * 0.08, y: mirrorY))
      rulePath.addLine(to: CGPoint(x: canvas.width * 0.92, y: mirrorY))
      builder.add(ExtraStyleNode(
        id: "mirror-rule-\(lineIndex)", kind: .path,
        position: .zero, anchor: .zero, zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        path: ExtraStylePathContent(
          path: rulePath,
          strokeColor: accent.withAlpha(0.7),
          strokeWidth: 2, dash: nil
        ),
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))

      // The main line, word by word, sliding down into place
      // from above; emphasis words take the accent colour.
      if line.words.isEmpty {
        builder.add(extraStyleTextNode(
          id: "line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.bold, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          position: CGPoint(x: canvas.width / 2, y: mainY),
          zIndex: 11, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: experimentalBInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [
            ExtraStyleTrack(
              property: .positionY,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame, value: -36, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 12), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: lineStartFrame
            ),
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          ]
        ))
      } else {
        let wordNodes = extraStyleWordNodes(
          line: line, lineIndex: lineIndex, fps: fps,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: mainY, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          font: ExtraStyleFonts.bold, zIndex: 11, canvasWidth: canvas.width
        ) { _, wordStartFrame, wordEndFrame in
          [
            ExtraStyleTrack(
              property: .positionY,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: wordStartFrame, value: -36, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 12), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: wordStartFrame
            ),
            extraStyleSpringInTrack(start: wordStartFrame, from: 0.5, stiffness: 160, damping: 11),
            extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 4, exitFrames: 4),
          ]
        }
        for (wordIndex, wordNode) in wordNodes.enumerated() {
          var node = experimentalBStroked(wordNode, color: experimentalBInkOutline, width: max(2, sizePoints * 0.05))
          if emphasis.contains(wordIndex) {
            node.text?.color = accent
          }
          builder.add(node)
        }
      }

      // THE REFLECTION — a smaller, faded copy below the mirror
      // line. NOTE: ExtraStyleNode.scale is a uniform CGFloat, so
      // a (1, −1) vertical flip is not expressible — there is no
      // non-uniform scale field to set. This is a squashed
      // (uniform 0.62×) faded copy that splits away from the main
      // line on entry (positionY +36 → 0) and whose opacity is
      // the reflectionOpacity param (0–0.6) via paramScale. A true
      // mirrored copy needs either a non-uniform scale field or
      // a perspective-corner vertical flip — Phase 4.
      builder.add(extraStyleTextNode(
        id: "reflection-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.bold, sizePoints: sizePoints,
        color: accent.withAlpha(0.9),
        position: CGPoint(x: canvas.width / 2, y: reflectionY),
        zIndex: 9, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        colorParamId: "accent",
        tracks: [
          extraStyleSpringInTrack(start: lineStartFrame, from: 0.5, stiffness: 140, damping: 12),
          ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 36, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 12), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 10), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 9), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
            ]),
            startFrame: lineStartFrame,
            paramScale: "reflectionOpacity"
          ),
        ]
      ))
      // Apply the squash: the reflection node is built by the
      // helper at scale 1, so set its base scale after the fact.
      // (extraStyleTextNode has no scale argument.)
      if var reflection = builder.nodes["reflection-\(lineIndex)"] {
        reflection.scale = 0.62
        builder.nodes["reflection-\(lineIndex)"] = reflection
      }

      // Fade wash over the reflection band: transparent at the
      // mirror line, darkening toward the bottom, so the copy
      // dissolves downward instead of ending in a hard edge.
      // (A true alpha fade would need a gradient mask on the
      // text node; the engine's masks clip, they do not fade —
      // this wash is the available approximation.)
      let washHeight = canvas.height * 0.16
      builder.add(ExtraStyleNode(
        id: "reflection-wash-\(lineIndex)", kind: .gradient,
        position: CGPoint(x: canvas.width / 2, y: mirrorY + washHeight / 2),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 12,
        visibleRange: lineStartFrame...lineEndFrame,
        gradient: ExtraStyleGradientContent(
          kind: .linear(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: washHeight)),
          colors: [
            ExtraStyleRGBA(r: 0.06, g: 0.06, b: 0.07, a: 0),
            ExtraStyleRGBA(r: 0.06, g: 0.06, b: 0.07, a: 0.55),
          ],
          locations: [0, 1],
          rect: CGRect(x: 0, y: 0, width: canvas.width * 0.9, height: washHeight)
        )
      ))

      // Symmetry ornaments: matching stars left and right of the
      // main line, with fainter twins below the mirror line.
      if showSymmetry {
        let starRadius = canvas.width * 0.045
        for (ornamentIndex, ornament) in [
          (CGPoint(x: canvas.width * 0.1, y: mainY), 0.9),
          (CGPoint(x: canvas.width * 0.9, y: mainY), 0.9),
          (CGPoint(x: canvas.width * 0.1, y: reflectionY), 0.35),
          (CGPoint(x: canvas.width * 0.9, y: reflectionY), 0.35),
        ].enumerated() {
          builder.add(extraStyleShapeNode(
            id: "ornament-\(lineIndex)-\(ornamentIndex)",
            shape: extraStyleStarShape(outerRadius: starRadius, innerRadius: starRadius * 0.45, spikes: 4),
            fill: accent.withAlpha(CGFloat(ornament.1)),
            position: ornament.0, zIndex: 10,
            visibleRange: lineStartFrame...lineEndFrame,
            fillColorParamId: "accent",
            tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
          ))
        }
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 39: Living Typography (experimental)
//
// needsAudioAutomation TRUE (catalog map): the automation WILL be
// supplied, so growth is driven from the loudness curve directly
// — a loudness reaction track on every character's scale, plus
// build-time loudness sampling that sets each line's character
// stagger (louder lines grow faster). The only fallback is the
// beat-confidence gate if beatPhase is ever used (it is not
// used here); a missing-automation case is never expected.
//
// Re-scope: the vine and branches now span the LYRIC BLOCK only
// (measured from the line's text), not the full frame width.
// Characters now also get the dark outline stroke.
final class LivingTypographyExtraStyle: ExtraStyleDefinition {
  let id = "living-typography"
  let version = 1
  let name = "Living Typography"
  let tagline = "Letters grow like plants — louder lines grow faster."
  let category = "experimental"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "growth", label: "Growth rate", min: 0.5, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "branchiness", label: "Branches", min: 0, max: 1, step: 0.05,
        default: 0.6, affects: "layout"
      ),
      extraStyleColorParam(id: "leafColor", label: "Leaf colour", default: "#C9F36B", affects: "appearance"),
      extraStyleToggleParam(id: "pulse", label: "Pulse with the music", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "sapling", "label": "Sapling", "values": ["growth": 0.6, "branchiness": 0.3]],
      ["id": "overgrown", "label": "Overgrown", "values": ["growth": 1.6, "branchiness": 1]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  var rebuildParamIds: [String] { ["branchiness"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let growth = max(0.5, extraStyleParamDouble(input.params, "growth", 1))
    let branchiness = max(0, min(1, extraStyleParamDouble(input.params, "branchiness", 0.6)))
    let leafColor = extraStyleColor(extraStyleParamString(input.params, "leafColor", "#C9F36B"))
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // Loudness at the line's start (LUFS-like dB, ~-60..0) →
      // 0...1. Louder lines grow faster: smaller char stagger.
      let loudnessDb = input.automation?.loudness(at: line.startSeconds) ?? -30
      let loudnessNorm = max(0.15, min(1, (loudnessDb + 60) / 60))
      let charDelayFrames = max(1, Int((3 * (1.25 - loudnessNorm) / growth).rounded()))
      let baselineY = canvas.height * 0.55
      let sizePoints = canvas.width * 0.075
      let toneColor = extraStyleToneColor(line.tone)

      // Lyric block span, measured from the line's text — the
      // vine and branches live inside it, never the full frame.
      let blockWidth = extraStyleTextWidth(line.text, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
      let blockLeft = max(canvas.width * 0.06, (canvas.width - blockWidth) / 2)
      let blockRight = min(canvas.width * 0.94, (canvas.width + blockWidth) / 2)

      // The vine the line grows on: a sine path under the text,
      // spanning the lyric block only.
      let vinePath = CGMutablePath()
      var vx = blockLeft
      var first = true
      while vx <= blockRight {
        let vy = baselineY + sizePoints * 0.9 + sin((vx - blockLeft) / max(1, blockRight - blockLeft) * .pi * 3) * sizePoints * 0.25
        if first { vinePath.move(to: CGPoint(x: vx, y: vy)); first = false } else { vinePath.addLine(to: CGPoint(x: vx, y: vy)) }
        vx += 24
      }
      builder.add(ExtraStyleNode(
        id: "vine-\(lineIndex)", kind: .path,
        position: .zero, anchor: .zero, zIndex: 8,
        visibleRange: lineStartFrame...lineEndFrame,
        path: ExtraStylePathContent(
          path: vinePath,
          strokeColor: leafColor.withAlpha(0.5),
          strokeWidth: 3, dash: nil
        ),
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 12, exitFrames: 12)]
      ))

      // Branches: seeded curved paths sprouting from the baseline
      // inside the lyric block, each ending in a leaf that
      // springs open. Count is baked from branchiness (a rebuild
      // param).
      var branchRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 11))
      let branchCount = Int(branchiness * 5) + 1
      for branchIndex in 0..<branchCount {
        let branchX = blockLeft + CGFloat(branchRandom.nextDouble()) * max(1, blockRight - blockLeft)
        let branchTop = baselineY - sizePoints * CGFloat(0.8 + branchRandom.nextDouble() * 0.9)
        let controlX = branchX + CGFloat(branchRandom.nextRange(min: -60, max: 60))
        let branchPath = CGMutablePath()
        branchPath.move(to: CGPoint(x: branchX, y: baselineY + sizePoints * 0.6))
        branchPath.addQuadCurve(to: CGPoint(x: branchX + CGFloat(branchRandom.nextRange(min: -40, max: 40)), y: branchTop), control: CGPoint(x: controlX, y: (baselineY + branchTop) / 2))
        builder.add(ExtraStyleNode(
          id: "branch-\(lineIndex)-\(branchIndex)", kind: .path,
          position: .zero, anchor: .zero, zIndex: 8,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: branchPath,
            strokeColor: leafColor.withAlpha(0.7),
            strokeWidth: 2.5, dash: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame + branchIndex * 4, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + branchIndex * 4 + 10), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .linear),
              ]),
              startFrame: lineStartFrame
            ),
          ]
        ))
        // Leaf at the branch tip.
        let leafId = "leaf-\(lineIndex)-\(branchIndex)"
        builder.add(extraStyleShapeNode(
          id: leafId,
          shape: extraStyleEllipseShape(width: 26, height: 15),
          fill: leafColor,
          position: CGPoint(x: branchX, y: branchTop), zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          fillColorParamId: "leafColor",
          tracks: [
            extraStyleSpringInTrack(start: lineStartFrame + branchIndex * 4 + 6, from: 0.2, stiffness: 160, damping: 10),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .loudness, base: 1, gain: 0.3),
              startFrame: lineStartFrame,
              enabledParamId: "pulse"
            ),
          ]
        ))
      }

      // The line's stored emoji, when it has one, as a bloom
      // above the growing text.
      if let emoji = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.32),
        sizePoints: canvas.width * 0.11, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(emoji)
      }

      // Per-character growth: each character springs in at its
      // staggered start (stagger set by the line's loudness), then
      // keeps pulsing with the loudness curve — the reaction
      // track multiplies the spring's scale, and the pulse toggle
      // makes it inert (end value = base 1) when off.
      let chars = extraStyleCharNodes(
        text: line.text, lineIndex: lineIndex,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: baselineY, sizePoints: sizePoints,
        color: toneColor,
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width,
        charDelayFrames: charDelayFrames
      ) { _, charStartFrame, lineEnd in
        [
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 140 + loudnessNorm * 80, damping: 11, initialVelocity: 0),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .loudness, base: 1, gain: 0.35),
            startFrame: charStartFrame,
            enabledParamId: "pulse"
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: charStartFrame, value: -12, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEnd, charStartFrame + 10), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: charStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEnd, charStartFrame + 5), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(charStartFrame, lineEnd - 9), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: lineEnd, value: 0, easing: .easeInCubic),
            ]),
            startFrame: charStartFrame
          ),
        ]
      }
      for char in chars {
        builder.add(experimentalBStroked(char, color: experimentalBInkOutline, width: max(2, sizePoints * 0.04)))
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 40: Reality Distortion (experimental)
//
// needsAudioAutomation TRUE (catalog map): the automation WILL be
// supplied, so the distortion is driven from the onset envelope
// directly — a scale reaction track on each word (onset 0...1 →
// pop, × onsetBoost) plus build-time onset sampling that sets how
// hard each line's words are bent.
//
// LYRIC-ONLY RE-SCOPE: the old full-frame displacement wave is
// GONE. A displacement node distorts the WHOLE composed frame
// (video included) — there is no per-node / text-only
// displacement, and the displacement scale is uncalibrated
// CI-only, so no small/subtle displacement node can be kept
// honestly. The wave is faked on the words only: each word tilts
// and pushes/pulls by a deterministic per-word amount, pops in
// scale on onsets, and rides a baked sine wobble (one positionY
// keyframe track per word — the wobble is baked into the same
// track as the push/settle, so each axis keeps one track).
// `waveScale` is now the bend strength, `waveFrequency` the
// wobble speed (both still rebuild params). The three full-width
// sine overlay paths are gone; the bent frame around the line
// stays (lyric-sized, swelling on onsets).
final class RealityDistortionExtraStyle: ExtraStyleDefinition {
  let id = "reality-distortion"
  let version = 1
  let name = "Reality Distortion"
  let tagline = "The words bend and ripple with every accent."
  let category = "experimental"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "waveScale", label: "Wave strength", min: 0, max: 100, step: 1,
        default: 40, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "waveFrequency", label: "Wave frequency", min: 1, max: 8, step: 0.5,
        default: 3, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "onsetBoost", label: "Onset boost", min: 0, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#FF5C8A", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "ripple", "label": "Ripple", "values": ["waveScale": 25, "waveFrequency": 2, "onsetBoost": 0.8]],
      ["id": "meltdown", "label": "Meltdown", "values": ["waveScale": 80, "waveFrequency": 6, "onsetBoost": 1.6]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  var rebuildParamIds: [String] { ["waveScale", "waveFrequency"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let waveScale = extraStyleParamDouble(input.params, "waveScale", 40)
    let waveFrequency = extraStyleParamDouble(input.params, "waveFrequency", 3)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FF5C8A"))
    var builder = ExtraStyleSceneBuilder()

    // Bend strength in points (waveScale 0–100 → 0–24 pt) and the
    // wobble period in frames (faster frequency = shorter period).
    let bendMax = waveScale * 0.24
    let wobblePeriod = max(24, Int((180 / max(1, waveFrequency)).rounded()))
    let wobbleAmp = bendMax * 0.45

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // Onset at the line's start, sampled at build time, sets
      // how hard this line's words are bent (louder accent =
      // bigger tilt/push). The live onset reaction on each word
      // keeps them pushing and pulling through the line.
      let onsetAtStart = input.automation?.onset(at: line.startSeconds) ?? 0.5
      let bend = 6 + onsetAtStart * 10
      let emphasis = Set(line.emphasisWordIndices)

      // A bent frame around the line, swelling on onsets.
      let frameWidth = canvas.width * 0.88
      let frameHeight = canvas.width * 0.2
      builder.add(extraStyleShapeNode(
        id: "bent-frame-\(lineIndex)",
        shape: extraStyleRectShape(width: frameWidth, height: frameHeight),
        fill: nil,
        stroke: accent.withAlpha(0.6), strokeWidth: 2,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.5), zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.12),
            startFrame: lineStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
        ]
      ))

      // Bent words: each word tilts and pushes/pulls vertically
      // by a deterministic per-word amount (seeded by index, not
      // RNG — the tilt is a pure function of word + line index),
      // rides a baked sine wobble, and pops in scale on onsets.
      // The push/settle and the wobble share ONE positionY
      // keyframe track per word.
      let sizePoints = canvas.width * 0.065
      let words: [ExtraStyleNode]
      if line.words.isEmpty {
        builder.add(extraStyleTextNode(
          id: "line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.5),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: experimentalBInkOutline, strokeWidthPoints: max(2, sizePoints * 0.05),
          tracks: [
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .onset, base: 1, gain: 0.25),
              startFrame: lineStartFrame,
              paramScale: "onsetBoost"
            ),
          ]
        ))
        continue
      } else {
        words = extraStyleWordNodes(
          line: line, lineIndex: lineIndex, fps: fps,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: canvas.height * 0.5, sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
        ) { index, wordStartFrame, wordEndFrame in
          let isEmphasis = emphasis.contains(index)
          let tilt = sin(Double(index) * 1.7 + Double(lineIndex)) * bend * (isEmphasis ? 1.5 : 1)
          let push = cos(Double(index) * 1.3 + Double(lineIndex) * 0.7) * min(16, bendMax)
          // One positionY track: push at the word start, settle
          // by +12 frames, then a sine wobble to the word end.
          var yKeys: [ExtraStyleKeyframe] = [
            ExtraStyleKeyframe(frame: wordStartFrame, value: push, easing: .easeOutCubic),
            ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 12), value: 0, easing: .easeOutCubic),
          ]
          var wobbleFrame = min(wordEndFrame, wordStartFrame + 12) + wobblePeriod / 4
          var wobbleIndex = 1
          while wobbleFrame < wordEndFrame {
            let value = sin(Double(wobbleIndex) * .pi / 2) * wobbleAmp
            yKeys.append(ExtraStyleKeyframe(frame: wobbleFrame, value: value, easing: .easeInOutSine))
            wobbleFrame += wobblePeriod / 4
            wobbleIndex += 1
          }
          yKeys.append(ExtraStyleKeyframe(frame: wordEndFrame, value: 0, easing: .easeOutCubic))
          return [
            ExtraStyleTrack(
              property: .rotationDeg,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: wordStartFrame, value: tilt, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 12), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: wordStartFrame
            ),
            ExtraStyleTrack(property: .positionY, kind: .keyframes(keys: yKeys), startFrame: wordStartFrame),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .onset, base: 1, gain: isEmphasis ? 0.35 : 0.25),
              startFrame: wordStartFrame,
              paramScale: "onsetBoost"
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
      }
      for (wordIndex, wordNode) in words.enumerated() {
        var node = experimentalBStroked(wordNode, color: experimentalBInkOutline, width: max(2, sizePoints * 0.05))
        if emphasis.contains(wordIndex) {
          node.text?.color = accent
        }
        builder.add(node)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (Experimental B)

extension ExtraStylesPhase3 {
  static func registerExperimentalB(into registry: ExtraStyleRegistry) {
    registry.register(BlueprintWorldExtraStyle())
    registry.register(KineticSculptureExtraStyle())
    registry.register(MirrorWorldExtraStyle())
    registry.register(LivingTypographyExtraStyle())
    registry.register(RealityDistortionExtraStyle())
  }
}
