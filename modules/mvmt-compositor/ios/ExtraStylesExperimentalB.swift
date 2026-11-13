import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3, Experimental family, part B
//
// Styles 36–40 (docs/EXTRA-STYLES-2.0.md §17):
//   36 Blueprint World, 37 Kinetic Sculpture, 38 Mirror World,
//   39 Living Typography, 40 Reality Distortion.
//
// Engine limits verified from ExtraStylesCompositor.swift and
// honoured here (see the per-style notes):
// - ExtraStyleNode.scale is a UNIFORM CGFloat (resolveNode scales
//   x and y by the same factor), so there is no (1, −1) mirror
//   flip. Mirror World fakes its reflection with a smaller, faded
//   copy under a darkening wash — a true vertical flip needs a
//   non-uniform scale or a perspective-corner flip (Phase 4).
// - There is NO path-progress / draw-on track kind. Blueprint
//   World's draw-on is staged opacity per construction line plus
//   a draw-head dot travelling the frame on a .path track
//   (which works only on .positionX — it drives both axes).
// - Perspective groups DO exist (perspectiveCorners on a group,
//   rasterized then CIPerspectiveTransform). Kinetic Sculpture
//   uses one for its 2.5D tilt.
// - Displacement nodes DO exist (ExtraStyleDisplacementContent,
//   CIDisplacementDistortion over the composed frame). Reality
//   Distortion uses one; see its note on the Metal spike.
// - needsAudioAutomation / needsSubjectMasks match the TS static
//   map src/lib/extra-styles/catalog.ts (STYLE_CAPABILITY_MAP)
//   exactly: only Living Typography and Reality Distortion need
//   audio automation (both TRUE / FALSE); the other three are
//   FALSE / FALSE. prepareScene throws when a required input is
//   missing, so the TRUE styles drive their motion from the
//   automation directly (loudness / onset reaction tracks plus
//   build-time sampling), with only the beat-confidence gate as
//   a fallback — never a missing-automation case.

// MARK: - Style 36: Blueprint World (experimental)

final class BlueprintWorldExtraStyle: ExtraStyleDefinition {
  let id = "blueprint-world"
  let version = 1
  let name = "Blueprint World"
  let tagline = "Construction lines, measurements, and a plan that draws itself."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "lineColor", label: "Line colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleToggleParam(id: "grid", label: "Blueprint grid", default: true, affects: "layout"),
      extraStyleToggleParam(id: "showMeasurements", label: "Measurement labels", default: true, affects: "layout"),
      extraStyleSliderParam(
        id: "drawSpeed", label: "Draw speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "technical", "label": "Technical", "values": ["lineColor": "#7DF9FF", "grid": true, "showMeasurements": true]],
      ["id": "minimal", "label": "Minimal", "values": ["lineColor": "#F4F1E9", "grid": false, "showMeasurements": false]],
    ]
  }

  var inputs: [String] { ["lines", "words"] }

  var rebuildParamIds: [String] { ["grid", "showMeasurements", "drawSpeed"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let lineColor = extraStyleColor(extraStyleParamString(input.params, "lineColor", "#7DF9FF"))
    let showGrid = extraStyleParamBool(input.params, "grid", true)
    let showMeasurements = extraStyleParamBool(input.params, "showMeasurements", true)
    let drawSpeed = max(0.25, extraStyleParamDouble(input.params, "drawSpeed", 1))
    var builder = ExtraStyleSceneBuilder()

    // Blueprint grid: one vertical-lines path node + one
    // horizontal-lines path node, faint, across the whole frame.
    if showGrid {
      let verticalPath = CGMutablePath()
      var x: CGFloat = canvas.width / 9
      while x < canvas.width {
        verticalPath.move(to: CGPoint(x: x, y: 0))
        verticalPath.addLine(to: CGPoint(x: x, y: canvas.height))
        x += canvas.width / 9
      }
      builder.add(ExtraStyleNode(
        id: "grid-vertical", kind: .path,
        position: .zero, anchor: .zero, zIndex: 1,
        path: ExtraStylePathContent(
          path: verticalPath,
          strokeColor: lineColor.withAlpha(0.12),
          strokeWidth: 1, dash: nil
        )
      ))
      let horizontalPath = CGMutablePath()
      var y: CGFloat = canvas.height / 12
      while y < canvas.height {
        horizontalPath.move(to: CGPoint(x: 0, y: y))
        horizontalPath.addLine(to: CGPoint(x: canvas.width, y: y))
        y += canvas.height / 12
      }
      builder.add(ExtraStyleNode(
        id: "grid-horizontal", kind: .path,
        position: .zero, anchor: .zero, zIndex: 1,
        path: ExtraStylePathContent(
          path: horizontalPath,
          strokeColor: lineColor.withAlpha(0.12),
          strokeWidth: 1, dash: nil
        )
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.055
      let centerY = canvas.height * 0.5
      let frameWidth = canvas.width * 0.84
      let frameHeight = sizePoints * 3.4
      let frameX = (canvas.width - frameWidth) / 2
      let frameTop = centerY - frameHeight / 2
      let frameBottom = centerY + frameHeight / 2
      // Stagger step for the staged draw-on (frames between
      // construction lines appearing); drawSpeed is a rebuild
      // param, so this is baked at build time.
      let stagger = max(2, Int((6 / drawSpeed).rounded()))

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

      // The line itself, in the middle of the plan.
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.mono, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: canvas.width / 2, y: centerY),
        zIndex: 13, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: frameWidth * 0.92,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 37: Kinetic Sculpture (experimental)

final class KineticSculptureExtraStyle: ExtraStyleDefinition {
  let id = "kinetic-sculpture"
  let version = 1
  let name = "Kinetic Sculpture"
  let tagline = "Rotating geometry with the lyrics riding its orbit."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "shapeStyle", label: "Sculpture",
        options: [("rings", "Rings"), ("cubes", "Cubes"), ("orbit", "Orbit")],
        default: "rings", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "spinSpeed", label: "Spin speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C9F36B", affects: "appearance"),
      extraStyleToggleParam(id: "perspective", label: "2.5D tilt", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "slow-rings", "label": "Slow Rings", "values": ["shapeStyle": "rings", "spinSpeed": 0.5]],
      ["id": "fast-orbit", "label": "Fast Orbit", "values": ["shapeStyle": "orbit", "spinSpeed": 1.6]],
    ]
  }

  var inputs: [String] { ["lines", "words"] }

  var rebuildParamIds: [String] { ["shapeStyle", "perspective"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let shapeStyle = extraStyleParamString(input.params, "shapeStyle", "rings")
    let usePerspective = extraStyleParamBool(input.params, "perspective", true)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let center = CGPoint(x: canvas.width / 2, y: canvas.height * 0.4)
      let outerRadius = canvas.width * 0.3
      let groupId = "sculpture-\(lineIndex)"
      var members: [String] = []

      // Outer ring.
      let ringOuterId = "ring-outer-\(lineIndex)"
      builder.addChild(extraStyleShapeNode(
        id: ringOuterId,
        shape: extraStyleEllipseShape(width: outerRadius * 2, height: outerRadius * 2),
        fill: nil,
        stroke: accent.withAlpha(0.85), strokeWidth: 3,
        position: .zero, zIndex: 0,
        fillColorParamId: nil
      ))
      members.append(ringOuterId)
      // Inner ring.
      let ringInnerId = "ring-inner-\(lineIndex)"
      builder.addChild(extraStyleShapeNode(
        id: ringInnerId,
        shape: extraStyleEllipseShape(width: outerRadius * 1.2, height: outerRadius * 1.2),
        fill: nil,
        stroke: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 0.5), strokeWidth: 2,
        position: .zero, zIndex: 0
      ))
      members.append(ringInnerId)

      // Central diamond (a square path rotated by its own
      // counter-rotation track — the sculpture's second motion).
      let diamondRadius = canvas.width * 0.13
      let diamondPath = CGMutablePath()
      diamondPath.move(to: CGPoint(x: diamondRadius, y: 0))
      diamondPath.addLine(to: CGPoint(x: diamondRadius * 2, y: diamondRadius))
      diamondPath.addLine(to: CGPoint(x: diamondRadius, y: diamondRadius * 2))
      diamondPath.addLine(to: CGPoint(x: 0, y: diamondRadius))
      diamondPath.closeSubpath()
      let diamondId = "diamond-\(lineIndex)"
      builder.addChild(extraStyleShapeNode(
        id: diamondId,
        shape: ExtraStyleShapeKind.path(diamondPath),
        fill: accent.withAlpha(0.9),
        position: .zero, zIndex: 1,
        fillColorParamId: "accent",
        tracks: [
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .loop(periodFrames: 240, periodParamId: "spinSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: 240, value: -360, easing: .linear),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))
      members.append(diamondId)

      if shapeStyle == "cubes" {
        // Two small cube outlines (squares) at opposite offsets.
        for (cubeIndex, offset) in [CGPoint(x: -outerRadius * 0.55, y: -outerRadius * 0.4), CGPoint(x: outerRadius * 0.55, y: outerRadius * 0.4)].enumerated() {
          let cubeId = "cube-\(lineIndex)-\(cubeIndex)"
          let cubeSize = canvas.width * 0.14
          builder.addChild(extraStyleShapeNode(
            id: cubeId,
            shape: extraStyleRectShape(width: cubeSize, height: cubeSize),
            fill: nil,
            stroke: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 0.75), strokeWidth: 2,
            position: offset, zIndex: 1,
            tracks: [
              ExtraStyleTrack(
                property: .rotationDeg,
                kind: .loop(periodFrames: 180, periodParamId: "spinSpeed", keys: [
                  ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
                  ExtraStyleKeyframe(frame: 180, value: 360, easing: .linear),
                ]),
                startFrame: lineStartFrame
              ),
            ]
          ))
          members.append(cubeId)
        }
      }

      if shapeStyle == "orbit" {
        // Three dots travelling the ring on .path tracks (local
        // circle points — the group transform makes them orbit
        // the sculpture's centre).
        for dotIndex in 0..<3 {
          let dotId = "orbit-dot-\(lineIndex)-\(dotIndex)"
          var circle: [CGPoint] = []
          for step in 0..<24 {
            let angle = CGFloat(step) * .pi * 2 / 24 + CGFloat(dotIndex) * .pi * 2 / 3
            circle.append(CGPoint(x: cos(angle) * outerRadius, y: sin(angle) * outerRadius))
          }
          builder.addChild(extraStyleShapeNode(
            id: dotId,
            shape: extraStyleEllipseShape(width: 20, height: 20),
            fill: accent,
            position: .zero, zIndex: 2,
            fillColorParamId: "accent",
            tracks: [
              ExtraStyleTrack(
                property: .positionX,
                kind: .path(points: circle, durationFrames: 180, easing: .linear),
                startFrame: lineStartFrame + dotIndex * 10
              ),
            ]
          ))
          members.append(dotId)
        }
      }

      // The sculpture group: rotates as one on a loop (speed via
      // spinSpeed), and — when enabled — carries a perspective
      // warp (trapezoid corners: narrower top than bottom) for
      // the 2.5D tilt. The corners are static; the rotation is
      // the loop track, so tilt + spin compose.
      var corners: [CGPoint]? = nil
      if usePerspective {
        let halfW = outerRadius * 1.05
        let halfH = outerRadius * 1.05
        corners = [
          CGPoint(x: center.x - halfW * 0.72, y: center.y - halfH),
          CGPoint(x: center.x + halfW * 0.72, y: center.y - halfH),
          CGPoint(x: center.x + halfW, y: center.y + halfH),
          CGPoint(x: center.x - halfW, y: center.y + halfH),
        ]
      }
      builder.add(ExtraStyleNode(
        id: groupId, kind: .group,
        children: members,
        position: center, anchor: .zero,
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        perspectiveCorners: corners,
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

      // The line, as per-word nodes below the sculpture — each
      // word springs in at its sung start.
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: canvas.height * 0.68, sizePoints: canvas.width * 0.06,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStartFrame, wordEndFrame in
        [
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
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: Double(index % 2 == 0 ? -6 : 6), easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 12), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ),
        ]
      }
      for word in words { builder.add(word) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 38: Mirror World (experimental)

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

      // The main line, sliding down into place from above.
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.bold, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: canvas.width / 2, y: mainY),
        zIndex: 11, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
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

      // The vine the line grows on: a sine path under the text.
      let vinePath = CGMutablePath()
      var vx: CGFloat = 0
      var first = true
      while vx <= canvas.width {
        let vy = baselineY + sizePoints * 0.9 + sin(vx / canvas.width * .pi * 3) * sizePoints * 0.25
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

      // Branches: seeded curved paths sprouting from the baseline,
      // each ending in a leaf that springs open. Count is baked
      // from branchiness (a rebuild param).
      var branchRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 11))
      let branchCount = Int(branchiness * 5) + 1
      for branchIndex in 0..<branchCount {
        let branchX = canvas.width * CGFloat(0.15 + branchRandom.nextDouble() * 0.7)
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
      for char in chars { builder.add(char) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 40: Reality Distortion (experimental)
//
// needsAudioAutomation TRUE (catalog map): the automation WILL be
// supplied, so the distortion wave is driven from the onset
// envelope directly — a scale reaction track on the displacement
// node (onset 0...1 → scale waveScale...2×waveScale, × onsetBoost).
// METAL-SPIKE CANDIDATE (docs §6.5, §17 #40): the displacement
// here is the engine's Core Image path (CIDisplacementDistortion
// over a procedural sine map — a coarse warp, one map per scene,
// scale only). A true per-pixel, frequency-varying distortion
// shader is a Metal job; adopt it only if the §6.5 spike proves
// a ≥2× win. No Metal work is attempted here.

final class RealityDistortionExtraStyle: ExtraStyleDefinition {
  let id = "reality-distortion"
  let version = 1
  let name = "Reality Distortion"
  let tagline = "The frame bends and ripples with every accent."
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

  var inputs: [String] { ["lines", "words", "audio"] }

  var rebuildParamIds: [String] { ["waveScale", "waveFrequency"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let waveScale = extraStyleParamDouble(input.params, "waveScale", 40)
    let waveFrequency = extraStyleParamDouble(input.params, "waveFrequency", 3)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FF5C8A"))
    var builder = ExtraStyleSceneBuilder()

    // The distortion wave itself: a displacement node. Its scale
    // track is a reaction — base and gain are baked from
    // waveScale at build time (waveScale is a rebuild param, so
    // dragging it rebuilds the scene with a new baked base/gain),
    // and onsetBoost multiplies the evaluated value with no
    // rebuild (0 = no distortion, 2 = double). The evaluator
    // takes the node's displacementScale as the
    // CIDisplacementDistortion scale for the whole composed frame.
    builder.add(ExtraStyleNode(
      id: "distortion-wave", kind: .displacement,
      position: .zero, anchor: .zero, zIndex: 30,
      displacement: ExtraStyleDisplacementContent(baseScale: waveScale, frequency: waveFrequency),
      tracks: [
        ExtraStyleTrack(
          property: .scale,
          kind: .reaction(input: .onset, base: waveScale, gain: waveScale),
          startFrame: 0,
          paramScale: "onsetBoost"
        ),
      ]
    ))

    // Distortion-wave overlay: three sine paths across the frame,
    // drifting on loops, so the wave is visible even between
    // onsets (the displacement itself only bends the picture).
    for (waveIndex, waveY) in [0.3, 0.5, 0.7].enumerated() {
      let wavePath = CGMutablePath()
      var wx: CGFloat = 0
      var first = true
      while wx <= canvas.width {
        let wy = canvas.height * CGFloat(waveY) + sin(wx / canvas.width * .pi * 4 + CGFloat(waveIndex)) * 36
        if first { wavePath.move(to: CGPoint(x: wx, y: wy)); first = false } else { wavePath.addLine(to: CGPoint(x: wx, y: wy)) }
        wx += 24
      }
      builder.add(ExtraStyleNode(
        id: "wave-line-\(waveIndex)", kind: .path,
        position: .zero, anchor: .zero, zIndex: 5,
        path: ExtraStylePathContent(
          path: wavePath,
          strokeColor: accent.withAlpha(0.35),
          strokeWidth: 2, dash: nil
        ),
        tracks: [
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 180, periodParamId: nil, keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 90, value: -12, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 180, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: 0
          ),
          extraStyleFlickerTrack(start: 0, end: input.durationFrames, base: 0.8, amplitude: 0.2, seed: input.seed ^ UInt64(waveIndex + 21), stepFrames: 6),
        ]
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // Onset at the line's start, sampled at build time, sets
      // how hard this line's words are bent (louder accent =
      // bigger tilt/push). The live onset reaction on each word
      // keeps them pushing and pulling through the line.
      let onsetAtStart = input.automation?.onset(at: line.startSeconds) ?? 0.5
      let bend = 6 + onsetAtStart * 10

      // A bent frame around the line, swelling on onsets.
      let frameWidth = canvas.width * 0.88
      let frameHeight = canvas.width * 0.22
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
      // and pops in scale on onsets.
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: canvas.height * 0.5, sizePoints: canvas.width * 0.065,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStartFrame, wordEndFrame in
        let tilt = sin(Double(index) * 1.7 + Double(lineIndex)) * bend
        let push = cos(Double(index) * 1.3 + Double(lineIndex) * 0.7) * 16
        return [
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: tilt, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 12), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: push, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 12), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.25),
            startFrame: wordStartFrame
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
      for word in words { builder.add(word) }
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
