import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3, Graphic Design family
//
// Five styles (docs/EXTRA-STYLES-2.0.md §17 rows 16–20):
//   - Editorial Magazine — layout-led typography + rules.
//   - Brutalist Typography — massive type, hard cuts, onset cuts.
//   - Collage Explosion — cutout letters, paper, procedural stickers.
//   - Ink and Paint — brush strokes, blots, splash particles.
//   - Neon Sign World — neon text, glow layers, reflection.
//
// Engine limits encountered while building (see the Phase 3 report):
//   - No path-progress track: Ink strokes reveal with an opacity
//     envelope, not a true stroke draw-on.
//   - No node blur/glow property: Neon glow is layered text copies
//     (larger, low-opacity, .screen) + a radial halo gradient.
//   - Node scale is a uniform CGFloat: the Neon reflection cannot
//     be a true vertical flip (1, -1); it is a smaller, faded copy
//     under a gradient fade band.
//   - No layout keyframes: Editorial "dynamic wrap" swaps between
//     two precomputed layouts (single-column ↔ two-column) with an
//     opacity crossfade at the line midpoint.
//   - No step/hold easing: Brutalist hard cuts are adjacent
//     keyframes 1 frame apart (linear).

// MARK: - Shared design helpers (file-private, design-prefixed)

/// Hard-cut opacity: 0 → 1 in one frame at `start`, 1 → 0 in one
/// frame at `end`. No step easing exists, so adjacent keyframes
/// one frame apart are the hard cut.
private func designHardCutOpacityTrack(start: Int, end: Int) -> ExtraStyleTrack {
  guard end - start >= 3 else {
    return ExtraStyleTrack(
      property: .opacity,
      kind: .keyframes(keys: [
        ExtraStyleKeyframe(frame: start, value: 0, easing: .linear),
        ExtraStyleKeyframe(frame: end, value: 0, easing: .linear),
      ]),
      startFrame: start
    )
  }
  return ExtraStyleTrack(
    property: .opacity,
    kind: .keyframes(keys: [
      ExtraStyleKeyframe(frame: start, value: 0, easing: .linear),
      ExtraStyleKeyframe(frame: start + 1, value: 1, easing: .linear),
      ExtraStyleKeyframe(frame: end - 1, value: 1, easing: .linear),
      ExtraStyleKeyframe(frame: end, value: 0, easing: .linear),
    ]),
    startFrame: start
  )
}

/// Horizontal rule path spanning `width` points, in positive local
/// space starting at (0, 0) so the anchor math centres it.
private func designRulePath(width: CGFloat) -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: 0, y: 0))
  path.addLine(to: CGPoint(x: width, y: 0))
  return path
}

/// Split a line's text into words (whitespace-separated, no empties).
private func designWords(of line: ExtraStyleInputLine) -> [String] {
  line.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
}

// MARK: - Style 16: Editorial Magazine (design)

final class EditorialMagazineExtraStyle: ExtraStyleDefinition {
  let id = "editorial-magazine"
  let version = 1
  let name = "Editorial Magazine"
  let tagline = "Headlines, rule lines, and columns — lyrics in print."
  let category = "design"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false
  let rebuildParamIds = ["columns"]

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "columns", label: "Column layout",
        options: [("dynamic", "Dynamic"), ("single", "Single column"), ("two", "Two columns")],
        default: "dynamic", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "headlineSize", label: "Headline size", min: 0.5, max: 1.5, step: 0.05,
        default: 1, affects: "layout"
      ),
      extraStyleColorParam(id: "ink", label: "Ink colour", default: "#1A1A1A", affects: "appearance"),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C0392B", affects: "appearance"),
      extraStyleToggleParam(id: "masthead", label: "Masthead", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "broadsheet", "label": "Broadsheet", "values": ["columns": "two", "headlineSize": 1.2]],
      ["id": "tabloid", "label": "Tabloid", "values": ["columns": "single", "headlineSize": 1.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let columns = extraStyleParamString(input.params, "columns", "dynamic")
    let headlineScale = extraStyleParamDouble(input.params, "headlineSize", 1)
    let showMasthead = extraStyleParamBool(input.params, "masthead", true)
    let ink = extraStyleColor(extraStyleParamString(input.params, "ink", "#1A1A1A"))
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C0392B"))
    let paper = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    var builder = ExtraStyleSceneBuilder()

    // Paper background.
    builder.add(extraStyleBackgroundGradientNode(
      id: "ed-background", canvas: canvas,
      colors: [paper, ExtraStyleRGBA(r: 0.93, g: 0.91, b: 0.87, a: 1)],
      locations: [0, 1], zIndex: 0
    ))

    // Masthead: nameplate + rule, static across the scene.
    if showMasthead {
      builder.add(extraStyleTextNode(
        id: "ed-masthead",
        text: "MVMT", font: ExtraStyleFonts.didot, sizePoints: canvas.width * 0.055,
        color: ink,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.055),
        zIndex: 1, colorParamId: "ink"
      ))
      builder.add(ExtraStyleNode(
        id: "ed-masthead-rule", kind: .path,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.095),
        anchor: CGPoint(x: 0.5, y: 0.5), zIndex: 1,
        path: ExtraStylePathContent(
          path: designRulePath(width: canvas.width * 0.86),
          strokeColor: ink, strokeWidth: 2, dash: nil
        )
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let midFrame = (lineStartFrame + lineEndFrame) / 2
      let headlineSize = canvas.width * 0.072 * CGFloat(headlineScale)
      let headlineY = canvas.height * 0.28
      let bodyY = canvas.height * 0.55
      let bodySize = canvas.width * 0.036

      // Headline: wipe in from the left (positionX offset) + fade.
      builder.add(extraStyleTextNode(
        id: "ed-headline-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.serif, sizePoints: headlineSize,
        color: ink,
        position: CGPoint(x: canvas.width / 2, y: headlineY),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.86,
        colorParamId: "ink",
        tracks: [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: -90, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 12), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: lineStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 10, exitFrames: 9),
        ]
      ))

      // Rule lines above and below the headline, staggered in.
      for (ruleIndex, ruleY) in [headlineY - headlineSize * 0.95, headlineY + headlineSize * 0.95].enumerated() {
        builder.add(ExtraStyleNode(
          id: "ed-rule-\(lineIndex)-\(ruleIndex)", kind: .path,
          position: CGPoint(x: canvas.width / 2, y: ruleY),
          anchor: CGPoint(x: 0.5, y: 0.5), zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: designRulePath(width: canvas.width * 0.86),
            strokeColor: ruleIndex == 0 ? ink : accent, strokeWidth: ruleIndex == 0 ? 2 : 4, dash: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame + ruleIndex * 4, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + ruleIndex * 4 + 8), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 9), value: 1, easing: .linear),
                ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
              ]),
              startFrame: lineStartFrame
            ),
          ]
        ))
      }

      // Pull-quote overlap: the emphasis words (or first words),
      // large, accent, slightly rotated, overlapping the gap
      // between headline and body.
      let words = designWords(of: line)
      let quoteWords: [String] = {
        let indices = line.emphasisWordIndices
        if !indices.isEmpty {
          return indices.compactMap { $0 >= 0 && $0 < words.count ? words[$0] : nil }
        }
        return Array(words.prefix(3))
      }()
      if !quoteWords.isEmpty {
        var quoteRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 101))
        let quoteX = canvas.width / 2 + CGFloat(quoteRandom.nextRange(min: -0.1, max: 0.1)) * canvas.width
        builder.add(ExtraStyleNode(
          id: "ed-quote-\(lineIndex)", kind: .text,
          position: CGPoint(x: quoteX, y: canvas.height * 0.41),
          anchor: CGPoint(x: 0.5, y: 0.5),
          rotationDeg: CGFloat(quoteRandom.nextRange(min: -2, max: 2)),
          zIndex: 11,
          visibleRange: lineStartFrame...lineEndFrame,
          text: ExtraStyleTextContent(
            text: "“\(quoteWords.joined(separator: " "))”",
            fontPostScriptName: ExtraStyleFonts.serif,
            sizePoints: canvas.width * 0.048,
            color: accent,
            colorParamId: "accent",
            strokeColor: nil,
            strokeWidthPoints: 0,
            alignment: .center,
            maxWidthPoints: canvas.width * 0.8
          ),
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame + 4, end: lineEndFrame, enterFrames: 10, exitFrames: 9)]
        ))
      }

      // Body layouts. "Dynamic" (default) shows the single-column
      // layout for the first half of the line and the two-column
      // layout for the second half, crossfaded at the midpoint —
      // the engine has no layout keyframes, so the wrap change is
      // two precomputed layouts + an opacity swap (see header).
      let showSingle = columns == "single" || columns == "dynamic"
      let showTwo = columns == "two" || columns == "dynamic"
      if showSingle {
        let singleRange: ClosedRange<Int> = columns == "dynamic"
          ? lineStartFrame...midFrame : lineStartFrame...lineEndFrame
        builder.add(extraStyleTextNode(
          id: "ed-body-single-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.serifRegular, sizePoints: bodySize,
          color: ink,
          position: CGPoint(x: canvas.width / 2, y: bodyY),
          zIndex: 10, visibleRange: singleRange,
          maxWidthPoints: canvas.width * 0.86,
          alignment: .left,
          colorParamId: "ink",
          tracks: [
            columns == "dynamic"
              ? ExtraStyleTrack(
                property: .opacity,
                kind: .keyframes(keys: [
                  ExtraStyleKeyframe(frame: lineStartFrame, value: 0, easing: .linear),
                  ExtraStyleKeyframe(frame: min(midFrame, lineStartFrame + 10), value: 1, easing: .easeOutCubic),
                  ExtraStyleKeyframe(frame: max(lineStartFrame, midFrame - 6), value: 1, easing: .linear),
                  ExtraStyleKeyframe(frame: midFrame, value: 0, easing: .linear),
                ]),
                startFrame: lineStartFrame
              )
              : extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 10, exitFrames: 9),
          ]
        ))
      }
      if showTwo {
        let twoRange: ClosedRange<Int> = columns == "dynamic"
          ? midFrame...lineEndFrame : lineStartFrame...lineEndFrame
        // Split the words across two columns.
        let half = max(1, words.count / 2)
        let leftText = words.prefix(half).joined(separator: " ")
        let rightText = words.dropFirst(half).joined(separator: " ")
        let columnWidth = canvas.width * 0.40
        for (columnIndex, columnText) in [leftText, rightText].enumerated() {
          guard !columnText.isEmpty else { continue }
          let columnX = columnIndex == 0 ? canvas.width * 0.27 : canvas.width * 0.73
          builder.add(extraStyleTextNode(
            id: "ed-body-two-\(lineIndex)-\(columnIndex)",
            text: columnText, font: ExtraStyleFonts.serifRegular, sizePoints: bodySize,
            color: ink,
            position: CGPoint(x: columnX, y: bodyY),
            zIndex: 10, visibleRange: twoRange,
            maxWidthPoints: columnWidth,
            alignment: .left,
            colorParamId: "ink",
            tracks: [
              columns == "dynamic"
                ? ExtraStyleTrack(
                  property: .opacity,
                  kind: .keyframes(keys: [
                    ExtraStyleKeyframe(frame: midFrame, value: 0, easing: .linear),
                    ExtraStyleKeyframe(frame: min(lineEndFrame, midFrame + 6), value: 1, easing: .easeOutCubic),
                    ExtraStyleKeyframe(frame: max(midFrame, lineEndFrame - 9), value: 1, easing: .linear),
                    ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
                  ]),
                  startFrame: midFrame
                )
                : extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 10, exitFrames: 9),
            ]
          ))
        }
        // Vertical rule between the columns.
        let dividerPath = CGMutablePath()
        dividerPath.move(to: CGPoint(x: 0, y: 0))
        dividerPath.addLine(to: CGPoint(x: 0, y: canvas.height * 0.24))
        builder.add(ExtraStyleNode(
          id: "ed-divider-\(lineIndex)", kind: .path,
          position: CGPoint(x: canvas.width / 2, y: bodyY - canvas.height * 0.12),
          anchor: CGPoint(x: 0.5, y: 0.5), zIndex: 9,
          visibleRange: twoRange,
          path: ExtraStylePathContent(
            path: dividerPath,
            strokeColor: ink.withAlpha(0.5), strokeWidth: 1, dash: nil
          )
        ))
      }

      // Folio: page number at the foot.
      builder.add(extraStyleTextNode(
        id: "ed-folio-\(lineIndex)",
        text: "— \(lineIndex + 1) —", font: ExtraStyleFonts.monoRegular, sizePoints: canvas.width * 0.03,
        color: ink.withAlpha(0.7),
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.93),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 10, exitFrames: 9)]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 17: Brutalist Typography (design)

final class BrutalistTypographyExtraStyle: ExtraStyleDefinition {
  let id = "brutalist-typography"
  let version = 1
  let name = "Brutalist Typography"
  let tagline = "Massive type, hard cuts, blocks and bars — no softness."
  let category = "design"
  // Automation IS supplied (catalog map): onset cuts and the
  // beat-phase pulse read it directly. No missing-automation
  // fallback is needed; a low beat confidence only zeroes the
  // beat-phase reaction (the engine gates it), leaving the
  // onset-driven cuts untouched.
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false
  let rebuildParamIds = ["slideDistance"]

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "ink", label: "Ink colour", default: "#111111", affects: "appearance"),
      extraStyleColorParam(id: "paper", label: "Paper colour", default: "#F4F1E9", affects: "appearance"),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#FF3B00", affects: "appearance"),
      extraStyleSliderParam(
        id: "slideDistance", label: "Slide distance", min: 0, max: 300, step: 10,
        default: 140, affects: "motion", unit: "pt"
      ),
      extraStyleToggleParam(id: "cutOnAccent", label: "Flash bars on accents", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "poster", "label": "Poster", "values": ["slideDistance": 220, "cutOnAccent": true]],
      ["id": "stark", "label": "Stark", "values": ["slideDistance": 60, "cutOnAccent": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let ink = extraStyleColor(extraStyleParamString(input.params, "ink", "#111111"))
    let paper = extraStyleColor(extraStyleParamString(input.params, "paper", "#F4F1E9"))
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FF3B00"))
    let slideDistance = extraStyleParamDouble(input.params, "slideDistance", 140)
    var builder = ExtraStyleSceneBuilder()

    // Flat paper background (two identical stops = a solid).
    builder.add(extraStyleBackgroundGradientNode(
      id: "br-background", canvas: canvas,
      colors: [paper, paper],
      locations: [0, 1],
      colorParamIds: ["paper", "paper"], zIndex: 0
    ))

    // Onset flash bar: a full-width accent bar whose opacity IS
    // the onset envelope (base 0 + gain × onset). It only flashes
    // while the "Flash bars on accents" toggle is on.
    builder.add(extraStyleShapeNode(
      id: "br-flash-bar",
      shape: extraStyleRectShape(width: canvas.width, height: 26),
      fill: accent,
      position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.13),
      zIndex: 2,
      fillColorParamId: "accent",
      tracks: [
        ExtraStyleTrack(
          property: .opacity,
          kind: .reaction(input: .onset, base: 0, gain: 1),
          startFrame: 0,
          enabledParamId: "cutOnAccent"
        ),
      ]
    ))

    // Beat-phase pulse bar: scale follows the beat grid; when
    // beat confidence is low the engine reports no beat and the
    // reaction reads 0, so the bar rests at its base scale.
    builder.add(extraStyleShapeNode(
      id: "br-beat-bar",
      shape: extraStyleRectShape(width: canvas.width * 0.5, height: 14),
      fill: ink,
      position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.16),
      zIndex: 2,
      tracks: [
        ExtraStyleTrack(
          property: .scale,
          kind: .reaction(input: .beatPhase, base: 0.6, gain: 0.4),
          startFrame: 0
        ),
      ]
    ))

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 201))
      // Unexpected placement: per-line anchor — alternating band,
      // seeded horizontal offset and tilt.
      let bandY = canvas.height * [0.36, 0.52, 0.66][lineIndex % 3]
      let centerX = canvas.width / 2 + CGFloat(random.nextRange(min: -0.08, max: 0.08)) * canvas.width
      let tilt = CGFloat(random.nextRange(min: -3, max: 3))
      let slideFrom = random.nextDouble() < 0.5 ? -slideDistance : slideDistance
      let sizePoints = canvas.width * 0.105
      let center = CGPoint(x: centerX, y: bandY)

      // Accent block behind the text, offset like a misprint.
      let textWidth = extraStyleTextWidth(line.text, fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
      let blockWidth = min(canvas.width * 0.94, textWidth + 48)
      builder.add(extraStyleShapeNode(
        id: "br-block-\(lineIndex)",
        shape: extraStyleRectShape(width: blockWidth, height: sizePoints * 1.35),
        fill: accent,
        position: CGPoint(x: centerX + 16, y: bandY - 14),
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        fillColorParamId: "accent",
        tracks: [designHardCutOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))

      // The massive line itself: hard cut in, aggressive slide,
      // onset pop on the scale.
      builder.add(ExtraStyleNode(
        id: "br-line-\(lineIndex)", kind: .text,
        position: center,
        anchor: CGPoint(x: 0.5, y: 0.5),
        rotationDeg: tilt,
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        text: ExtraStyleTextContent(
          text: line.text.uppercased(),
          fontPostScriptName: ExtraStyleFonts.black,
          sizePoints: sizePoints,
          color: ink,
          colorParamId: "ink",
          strokeColor: nil,
          strokeWidthPoints: 0,
          alignment: .center,
          maxWidthPoints: canvas.width * 0.94
        ),
        tracks: [
          designHardCutOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: slideFrom, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 4), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.1),
            startFrame: lineStartFrame
          ),
        ]
      ))

      // Geometric bars: one ink bar, one accent bar, seeded
      // lengths, hard-cut with the line.
      for barIndex in 0..<2 {
        let barWidth = CGFloat(random.nextRange(min: 0.2, max: 0.55)) * canvas.width
        let barY = bandY + sizePoints * (barIndex == 0 ? 0.95 : -0.95)
        builder.add(extraStyleShapeNode(
          id: "br-bar-\(lineIndex)-\(barIndex)",
          shape: extraStyleRectShape(width: barWidth, height: barIndex == 0 ? 18 : 10),
          fill: barIndex == 0 ? ink : accent,
          position: CGPoint(x: centerX + CGFloat(random.nextRange(min: -0.1, max: 0.1)) * canvas.width, y: barY),
          zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          fillColorParamId: barIndex == 0 ? "ink" : "accent",
          tracks: [designHardCutOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
        ))
      }

      // Index strip: the line's words in small mono caps along
      // the foot, each word hard-cutting in at its sung start.
      let wordNodes = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: canvas.height * 0.84, sizePoints: canvas.width * 0.032,
        color: ink, font: ExtraStyleFonts.mono, zIndex: 10,
        canvasWidth: canvas.width,
        colorParamId: "ink"
      ) { _, wordStartFrame, wordEndFrame in
        [designHardCutOpacityTrack(start: wordStartFrame, end: wordEndFrame)]
      }
      for wordNode in wordNodes { builder.add(wordNode) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 18: Collage Explosion (design)

final class CollageExplosionExtraStyle: ExtraStyleDefinition {
  let id = "collage-explosion"
  let version = 1
  let name = "Collage Explosion"
  let tagline = "Cut-out letters, torn paper, and stickers everywhere."
  let category = "design"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false
  let rebuildParamIds = ["tilt"]

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "tilt", label: "Max tilt", min: 0, max: 30, step: 1,
        default: 14, affects: "layout", unit: "°"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#E94F37", affects: "appearance"),
      extraStyleColorParam(id: "paperTint", label: "Paper tint", default: "#FFF8E7", affects: "appearance"),
      extraStyleToggleParam(id: "stickers", label: "Stickers", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "scrapbook", "label": "Scrapbook", "values": ["tilt": 20, "stickers": true]],
      ["id": "tidy", "label": "Tidy", "values": ["tilt": 5, "stickers": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let maxTilt = extraStyleParamDouble(input.params, "tilt", 14)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#E94F37"))
    let paperTint = extraStyleColor(extraStyleParamString(input.params, "paperTint", "#FFF8E7"))
    let ink = ExtraStyleRGBA(r: 0.08, g: 0.08, b: 0.09, a: 1)
    var builder = ExtraStyleSceneBuilder()

    // Paper-texture background (procedural asset, tiled by scale)
    // + halftone-dots texture overlay at low opacity.
    let textureScale = canvas.height / 256
    builder.add(ExtraStyleNode(
      id: "co-paper", kind: .image,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      scale: textureScale,
      zIndex: 0,
      imageAssetId: "paper-texture"
    ))
    builder.add(ExtraStyleNode(
      id: "co-halftone", kind: .image,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      scale: textureScale,
      opacity: 0.16,
      zIndex: 1,
      blendMode: .multiply,
      imageAssetId: "halftone-dots"
    ))

    // Cutout-letter palette: each letter picks one, via
    // red/green/blue channel tracks (single key = held value).
    let palette: [ExtraStyleRGBA] = [
      ink,
      accent,
      ExtraStyleRGBA(r: 0.1, g: 0.35, b: 0.85, a: 1),
      ExtraStyleRGBA(r: 0.95, g: 0.75, b: 0.1, a: 1),
    ]

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 301))
      let sizePoints = canvas.width * 0.088
      let lineY = canvas.height * 0.46

      // Torn-paper scraps behind each word: rotated rects with a
      // bold outline, laid out with the same measurement the word
      // nodes use so each scrap sits under its word.
      let words = line.words.isEmpty
        ? designWords(of: line).map { (text: $0, startSeconds: line.startSeconds, endSeconds: line.endSeconds) }
        : line.words.map { (text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
      if !words.isEmpty {
        let font = ExtraStyleFonts.black
        let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
        let widths = words.map { extraStyleTextWidth($0.text, fontPostScriptName: font, sizePoints: sizePoints) }
        let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, words.count - 1))
        var cursorX = (canvas.width - totalWidth) / 2
        for (wordIndex, word) in words.enumerated() {
          let wordWidth = widths[wordIndex]
          let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
          let scrapRotation = CGFloat(random.nextRange(min: -maxTilt, max: maxTilt))
          builder.add(extraStyleShapeNode(
            id: "co-scrap-\(lineIndex)-\(wordIndex)",
            shape: extraStyleRectShape(width: wordWidth + 28, height: sizePoints * 1.5),
            fill: paperTint,
            stroke: ink, strokeWidth: 3,
            position: CGPoint(x: cursorX + wordWidth / 2, y: lineY),
            zIndex: 9,
            visibleRange: lineStartFrame...lineEndFrame,
            fillColorParamId: "paperTint",
            tracks: [
              ExtraStyleTrack(
                property: .scale,
                kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 10, initialVelocity: 0),
                startFrame: wordStartFrame
              ),
            ]
          ))
          // Rotate the scrap via a rotation track (single key =
          // held tilt): shape nodes carry no rotation param in
          // the helper, so the track does it.
          if var scrap = builder.nodes["co-scrap-\(lineIndex)-\(wordIndex)"] {
            scrap.tracks.append(ExtraStyleTrack(
              property: .rotationDeg,
              kind: .keyframes(keys: [ExtraStyleKeyframe(frame: wordStartFrame, value: Double(scrapRotation), easing: .linear)]),
              startFrame: wordStartFrame
            ))
            builder.nodes["co-scrap-\(lineIndex)-\(wordIndex)"] = scrap
          }
          cursorX += wordWidth + spaceWidth
        }
      }

      // Cutout letters: per-character nodes, each popping in with
      // a spring, a seeded tilt, and a palette colour.
      let chars = extraStyleCharNodes(
        text: line.text, lineIndex: lineIndex,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: lineY, sizePoints: sizePoints,
        color: ink, font: ExtraStyleFonts.black, zIndex: 11,
        canvasWidth: canvas.width,
        charDelayFrames: 2
      ) { index, charStartFrame, lineEnd in
        let colour = palette[index % palette.count]
        let tilt = random.nextRange(min: -maxTilt, max: maxTilt)
        return [
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 220, damping: 9, initialVelocity: 0),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: charStartFrame, value: tilt, easing: .linear)]),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .red,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: charStartFrame, value: Double(colour.r), easing: .linear)]),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .green,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: charStartFrame, value: Double(colour.g), easing: .linear)]),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .blue,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: charStartFrame, value: Double(colour.b), easing: .linear)]),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: charStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEnd, charStartFrame + 3), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(charStartFrame, lineEnd - 9), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: lineEnd, value: 0, easing: .easeInCubic),
            ]),
            startFrame: charStartFrame
          ),
        ]
      }
      for char in chars { builder.add(char) }

      // Stickers (procedural — no new image assets): a star, a
      // comic burst, and the line's stored emoji as a sticker.
      // Each springs in staggered, at a seeded corner.
      let stickerCorners: [CGPoint] = [
        CGPoint(x: canvas.width * 0.16, y: canvas.height * 0.24),
        CGPoint(x: canvas.width * 0.84, y: canvas.height * 0.68),
        CGPoint(x: canvas.width * 0.82, y: canvas.height * 0.26),
      ]
      let starSize = canvas.width * 0.11
      builder.add(extraStyleShapeNode(
        id: "co-sticker-star-\(lineIndex)",
        shape: extraStyleStarShape(outerRadius: starSize, innerRadius: starSize * 0.45, spikes: 5),
        fill: accent,
        stroke: ink, strokeWidth: 3,
        position: stickerCorners[0],
        zIndex: 12,
        visibleRange: lineStartFrame...lineEndFrame,
        fillColorParamId: "accent",
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 9, initialVelocity: 0),
            startFrame: lineStartFrame + 6,
            enabledParamId: "stickers"
          ),
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .loop(periodFrames: 300, periodParamId: nil, keys: [
              ExtraStyleKeyframe(frame: 0, value: -8, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: 8, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 300, value: -8, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame,
            enabledParamId: "stickers"
          ),
        ]
      ))
      let burstSize = canvas.width * 0.24
      builder.add(ExtraStyleNode(
        id: "co-sticker-burst-\(lineIndex)", kind: .image,
        position: stickerCorners[1],
        anchor: CGPoint(x: 0.5, y: 0.5),
        scale: burstSize / 512,
        zIndex: 12,
        visibleRange: lineStartFrame...lineEndFrame,
        imageAssetId: "comic-burst",
        tracks: [
          extraStyleSpringInTrack(start: lineStartFrame + 10, from: 0.2, stiffness: 200, damping: 9),
        ]
      ))
      // The burst's spring must respect the stickers toggle too:
      // rebuild the node with the toggle gating the track.
      if var burst = builder.nodes["co-sticker-burst-\(lineIndex)"] {
        burst.tracks = [
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 9, initialVelocity: 0),
            startFrame: lineStartFrame + 10,
            enabledParamId: "stickers"
          ),
        ]
        builder.nodes["co-sticker-burst-\(lineIndex)"] = burst
      }
      if let emojiSticker = extraStyleEmojiNode(
        id: "co-sticker-emoji-\(lineIndex)", line: line,
        position: stickerCorners[2], sizePoints: canvas.width * 0.1, zIndex: 12,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        var sticker = emojiSticker
        sticker.tracks = [
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 180, damping: 10, initialVelocity: 0),
            startFrame: lineStartFrame + 14,
            enabledParamId: "stickers"
          ),
        ]
        builder.add(sticker)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 19: Ink and Paint (design)

final class InkAndPaintExtraStyle: ExtraStyleDefinition {
  let id = "ink-and-paint"
  let version = 1
  let name = "Ink and Paint"
  let tagline = "Brush strokes, ink blots, and paint splashes."
  let category = "design"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false
  let rebuildParamIds = ["brushWidth"]

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "ink", label: "Ink colour", default: "#1B1B2E", affects: "appearance"),
      extraStyleSliderParam(
        id: "brushWidth", label: "Brush width", min: 4, max: 24, step: 1,
        default: 10, affects: "appearance", unit: "pt"
      ),
      extraStyleSliderParam(
        id: "splash", label: "Splash amount", min: 0, max: 100, step: 1,
        default: 40, affects: "density"
      ),
      extraStyleToggleParam(id: "bleed", label: "Ink bleed", default: true, affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "sumi", "label": "Sumi", "values": ["brushWidth": 16, "splash": 20]],
      ["id": "splashy", "label": "Splashy", "values": ["brushWidth": 8, "splash": 80]],
    ]
  }

  var inputs: [String] { ["lines", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let ink = extraStyleColor(extraStyleParamString(input.params, "ink", "#1B1B2E"))
    let brushWidth = CGFloat(extraStyleParamDouble(input.params, "brushWidth", 10))
    let splash = extraStyleParamDouble(input.params, "splash", 40)
    var builder = ExtraStyleSceneBuilder()

    // Rice-paper background.
    builder.add(extraStyleBackgroundGradientNode(
      id: "ink-background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.98, g: 0.96, b: 0.92, a: 1),
        ExtraStyleRGBA(r: 0.94, g: 0.91, b: 0.85, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 401))
      let sizePoints = canvas.width * 0.072
      let centerY = canvas.height * 0.48
      let textWidth = min(canvas.width * 0.86, extraStyleTextWidth(line.text, fontPostScriptName: ExtraStyleFonts.marker, sizePoints: sizePoints))
      let leftX = canvas.width / 2 - textWidth / 2
      let rightX = canvas.width / 2 + textWidth / 2

      // Brush strokes: an underline swoosh, a crossing stroke,
      // and a loose circle around the line. The engine has no
      // path-progress track, so each stroke "reveals" with a
      // staggered opacity envelope + a small slide — a draw-on
      // approximation, not a true stroke reveal (see header).
      let swoosh = CGMutablePath()
      swoosh.move(to: CGPoint(x: leftX, y: centerY + sizePoints * 0.85))
      swoosh.addQuadCurve(
        to: CGPoint(x: rightX, y: centerY + sizePoints * 0.7),
        control: CGPoint(x: canvas.width / 2, y: centerY + sizePoints * 1.25))
      let cross = CGMutablePath()
      cross.move(to: CGPoint(x: leftX - 10, y: centerY - sizePoints * 0.9))
      cross.addQuadCurve(
        to: CGPoint(x: rightX + 10, y: centerY - sizePoints * 0.55),
        control: CGPoint(x: canvas.width / 2, y: centerY - sizePoints * 1.1))
      let circle = CGMutablePath()
      circle.move(to: CGPoint(x: leftX - 20, y: centerY))
      circle.addQuadCurve(
        to: CGPoint(x: canvas.width / 2, y: centerY - sizePoints * 1.05),
        control: CGPoint(x: leftX, y: centerY - sizePoints * 1.05))
      circle.addQuadCurve(
        to: CGPoint(x: rightX + 20, y: centerY),
        control: CGPoint(x: rightX, y: centerY - sizePoints * 1.05))
      let strokes: [(String, CGPath, CGFloat)] = [
        ("swoosh", swoosh, brushWidth),
        ("cross", cross, brushWidth * 0.6),
        ("circle", circle, brushWidth * 0.45),
      ]
      for (strokeIndex, stroke) in strokes.enumerated() {
        let revealStart = lineStartFrame + strokeIndex * 6
        builder.add(ExtraStyleNode(
          id: "ink-stroke-\(lineIndex)-\(stroke.0)", kind: .path,
          position: .zero, anchor: .zero, zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: stroke.1,
            strokeColor: ink,
            strokeWidth: stroke.2,
            dash: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: revealStart, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, revealStart + 9), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: max(revealStart, lineEndFrame - 9), value: 1, easing: .linear),
                ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
              ]),
              startFrame: revealStart
            ),
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: revealStart, value: -18, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(lineEndFrame, revealStart + 9), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: revealStart
            ),
          ]
        ))
      }

      // Ink blots: seeded ellipses that bleed in (spring scale +
      // opacity), plus a larger faint bleed ring per blot while
      // the bleed toggle is on.
      for blotIndex in 0..<2 {
        let blotX = canvas.width / 2 + CGFloat(random.nextRange(min: -0.3, max: 0.3)) * canvas.width
        let blotY = centerY + CGFloat(random.nextRange(min: -0.18, max: 0.18)) * canvas.height
        let blotW = CGFloat(random.nextRange(min: 0.05, max: 0.11)) * canvas.width
        let blotH = blotW * CGFloat(random.nextRange(min: 0.6, max: 1.1))
        let blotStart = lineStartFrame + 3 + blotIndex * 5
        builder.add(extraStyleShapeNode(
          id: "ink-blot-\(lineIndex)-\(blotIndex)",
          shape: extraStyleEllipseShape(width: blotW, height: blotH),
          fill: ink.withAlpha(0.85),
          position: CGPoint(x: blotX, y: blotY),
          zIndex: 8,
          visibleRange: lineStartFrame...lineEndFrame,
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.3, to: 1, stiffness: 140, damping: 12, initialVelocity: 0),
              startFrame: blotStart
            ),
            extraStyleEnterExitOpacityTrack(start: blotStart, end: lineEndFrame, enterFrames: 8, exitFrames: 9),
          ]
        ))
        builder.add(extraStyleShapeNode(
          id: "ink-bleed-\(lineIndex)-\(blotIndex)",
          shape: extraStyleEllipseShape(width: blotW * 1.7, height: blotH * 1.7),
          fill: ink.withAlpha(0.12),
          position: CGPoint(x: blotX, y: blotY),
          zIndex: 7,
          visibleRange: lineStartFrame...lineEndFrame,
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.5, to: 1, stiffness: 90, damping: 14, initialVelocity: 0),
              startFrame: blotStart,
              enabledParamId: "bleed"
            ),
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: blotStart, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, blotStart + 14), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .linear),
              ]),
              startFrame: blotStart,
              enabledParamId: "bleed"
            ),
          ]
        ))
      }

      // Splash: a particle burst at the line's centre (rate bound
      // to the splash param, so the density slider needs no
      // rebuild) + static splat dots scattered around the text.
      builder.add(ExtraStyleNode(
        id: "ink-splash-\(lineIndex)", kind: .particles,
        position: CGPoint(x: canvas.width / 2, y: centerY),
        zIndex: 8,
        visibleRange: lineStartFrame...lineEndFrame,
        emitter: ExtraStyleEmitterContent(
          rate: max(0, min(60, splash * 0.5)),
          rateParamId: "splash",
          rateParamMultiplier: 0.5,
          lifetimeSeconds: 1.6,
          origin: CGPoint(x: 0.5, y: 0.48),
          velocity: CGVector(dx: 0, dy: 0.06),
          spread: CGVector(dx: 0.22, dy: 0.14),
          gravity: 0.05,
          size: 0.012,
          sizeSpread: 0.008,
          opacityFrom: 0.9,
          opacityTo: 0,
          color: ink,
          colorParamId: "ink",
          spriteKind: .softCircle
        )
      ))
      for splatIndex in 0..<5 {
        let splatX = canvas.width / 2 + CGFloat(random.nextRange(min: -0.4, max: 0.4)) * canvas.width
        let splatY = centerY + CGFloat(random.nextRange(min: -0.22, max: 0.22)) * canvas.height
        let splatSize = CGFloat(random.nextRange(min: 6, max: 22))
        builder.add(extraStyleShapeNode(
          id: "ink-splat-\(lineIndex)-\(splatIndex)",
          shape: extraStyleEllipseShape(width: splatSize, height: splatSize * CGFloat(random.nextRange(min: 0.6, max: 1))),
          fill: ink.withAlpha(0.8),
          position: CGPoint(x: splatX, y: splatY),
          zIndex: 8,
          visibleRange: lineStartFrame...lineEndFrame,
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 10, initialVelocity: 0),
              startFrame: lineStartFrame + 4 + splatIndex * 3
            ),
          ]
        ))
      }

      // The line itself, in marker — the hand-painted voice.
      builder.add(extraStyleTextNode(
        id: "ink-line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.marker, sizePoints: sizePoints,
        color: ink,
        position: CGPoint(x: canvas.width / 2, y: centerY),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        colorParamId: "ink",
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 12, exitFrames: 9)]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 20: Neon Sign World (design)

final class NeonSignWorldExtraStyle: ExtraStyleDefinition {
  let id = "neon-sign-world"
  let version = 1
  let name = "Neon Sign World"
  let tagline = "A buzzing neon sign, glowing over the night."
  let category = "design"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false
  let rebuildParamIds = ["signStyle"]

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "neon", label: "Neon colour", default: "#FF2E88", affects: "appearance"),
      extraStyleSegmentedParam(
        id: "signStyle", label: "Sign style",
        options: [("tube", "Tube"), ("script", "Script"), ("block", "Block")],
        default: "tube", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "glow", label: "Glow", min: 0, max: 1.5, step: 0.05,
        default: 1, affects: "appearance"
      ),
      extraStyleToggleParam(id: "flicker", label: "Flicker", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "pink-motel", "label": "Pink Motel", "values": ["neon": "#FF2E88", "signStyle": "script"]],
      ["id": "electric-blue", "label": "Electric Blue", "values": ["neon": "#00E5FF", "signStyle": "tube"]],
    ]
  }

  var inputs: [String] { ["lines", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let neon = extraStyleColor(extraStyleParamString(input.params, "neon", "#FF2E88"))
    let signStyle = extraStyleParamString(input.params, "signStyle", "tube")
    var builder = ExtraStyleSceneBuilder()

    // Night background.
    builder.add(extraStyleBackgroundGradientNode(
      id: "ne-background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.07, g: 0.07, b: 0.1, a: 1),
        ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    let font: String = {
      switch signStyle {
      case "script": return ExtraStyleFonts.marker
      case "block": return ExtraStyleFonts.black
      default: return ExtraStyleFonts.avenirHeavy
      }
    }()
    let sizePoints = canvas.width * (signStyle == "block" ? 0.075 : 0.085)

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let signY = canvas.height * 0.42
      let backingWidth = canvas.width * 0.88
      let backingHeight = sizePoints * 2.3
      let signCenter = CGPoint(x: canvas.width / 2, y: signY)

      // Sign backing: dark panel + neon tube border.
      builder.add(extraStyleShapeNode(
        id: "ne-backing-\(lineIndex)",
        shape: extraStyleRectShape(width: backingWidth, height: backingHeight),
        fill: ExtraStyleRGBA(r: 0.08, g: 0.08, b: 0.11, a: 1),
        stroke: neon, strokeWidth: 4,
        position: signCenter,
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 6, exitFrames: 9)]
      ))

      // Halo: a radial wash behind the sign, scaled by the glow param.
      // Position is the canvas centre (not the sign centre): the
      // gradient rect is the full canvas in local space, so only a
      // centre position lands local (0, 0) on canvas (0, 0) and
      // puts the radial centre exactly on the sign.
      builder.add(ExtraStyleNode(
        id: "ne-halo-\(lineIndex)", kind: .gradient,
        position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 8,
        visibleRange: lineStartFrame...lineEndFrame,
        gradient: ExtraStyleGradientContent(
          kind: .radial(center: signCenter, radius: max(canvas.width, canvas.height) * 0.45),
          colors: [neon.withAlpha(0.22), neon.withAlpha(0)],
          colorParamIds: ["neon", "neon"],
          locations: [0, 1],
          rect: CGRect(origin: .zero, size: canvas)
        ),
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: lineStartFrame, value: 1, easing: .linear)]),
            startFrame: lineStartFrame,
            paramScale: "glow"
          ),
        ]
      ))

      // Glow layers: the engine has no blur/glow node property,
      // so glow is two larger copies of the text at low opacity
      // in .screen blend, flickering with seeded noise while the
      // flicker toggle is on.
      for (glowIndex, glowScale) in [(0, 1.1), (1, 1.22)] {
        let glowAlpha: CGFloat = glowIndex == 0 ? 0.3 : 0.13
        builder.add(ExtraStyleNode(
          id: "ne-glow-\(lineIndex)-\(glowIndex)", kind: .text,
          position: signCenter,
          anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 10,
          blendMode: .screen,
          visibleRange: lineStartFrame...lineEndFrame,
          text: ExtraStyleTextContent(
            text: line.text,
            fontPostScriptName: font,
            sizePoints: sizePoints * CGFloat(glowScale),
            color: neon.withAlpha(glowAlpha),
            colorParamId: "neon",
            strokeColor: nil,
            strokeWidthPoints: 0,
            alignment: .center,
            maxWidthPoints: canvas.width * 0.86
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [ExtraStyleKeyframe(frame: lineStartFrame, value: 1, easing: .linear)]),
              startFrame: lineStartFrame,
              paramScale: "glow",
              enabledParamId: "flicker"
            ),
          ]
        ))
        // Seeded flicker on top of the glow copy: one flicker
        // track per copy, different seeds, so the two layers
        // shimmer out of phase.
        if var glowNode = builder.nodes["ne-glow-\(lineIndex)-\(glowIndex)"] {
          glowNode.tracks.append(extraStyleFlickerTrack(
            start: lineStartFrame, end: lineEndFrame,
            base: 0.9, amplitude: 0.28,
            seed: input.seed ^ UInt64(lineIndex * 10 + glowIndex + 501),
            stepFrames: 3
          ))
          // The flicker track must also respect the toggle.
          if let lastIndex = glowNode.tracks.indices.last {
            glowNode.tracks[lastIndex].enabledParamId = "flicker"
          }
          builder.nodes["ne-glow-\(lineIndex)-\(glowIndex)"] = glowNode
        }
      }

      // The tube itself: electrical activation — a flickering
      // ramp (off, buzz, off, on) then steady, with a glow swell
      // (spring scale) as it powers up.
      builder.add(extraStyleTextNode(
        id: "ne-line-\(lineIndex)",
        text: line.text, font: font, sizePoints: sizePoints,
        color: neon,
        position: signCenter,
        zIndex: 11, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.86,
        colorParamId: "neon",
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 2), value: 0.65, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 4), value: 0.12, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 7), value: 0.9, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 12), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 9), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.92, to: 1, stiffness: 160, damping: 12, initialVelocity: 0),
            startFrame: lineStartFrame
          ),
        ]
      ))

      // Reflection: node scale is a uniform CGFloat, so a true
      // vertical flip (1, -1) is impossible. The reflection is a
      // smaller, faded copy below the sign, shimmering on a loop,
      // with a gradient band fading it into the night.
      let reflectionY = signY + backingHeight * 0.85
      builder.add(extraStyleTextNode(
        id: "ne-reflection-\(lineIndex)",
        text: line.text, font: font, sizePoints: sizePoints,
        color: neon.withAlpha(0.5),
        position: CGPoint(x: canvas.width / 2, y: reflectionY),
        zIndex: 8, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.86,
        colorParamId: "neon",
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: lineStartFrame, value: 0.55, easing: .linear)]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .loop(periodFrames: 120, periodParamId: nil, keys: [
              ExtraStyleKeyframe(frame: 0, value: 0.1, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 60, value: 0.2, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 120, value: 0.1, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))
      let fadeHeight = backingHeight * 1.1
      builder.add(ExtraStyleNode(
        id: "ne-reflection-fade-\(lineIndex)", kind: .gradient,
        position: CGPoint(x: canvas.width / 2, y: reflectionY),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        gradient: ExtraStyleGradientContent(
          kind: .linear(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: fadeHeight)
          ),
          colors: [
            ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0),
            ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 1),
          ],
          colorParamIds: nil,
          locations: [0, 1],
          rect: CGRect(x: 0, y: 0, width: canvas.width, height: fadeHeight)
        )
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (design family)

extension ExtraStylesPhase3 {
  static func registerDesignRest(into registry: ExtraStyleRegistry) {
    registry.register(EditorialMagazineExtraStyle())
    registry.register(BrutalistTypographyExtraStyle())
    registry.register(CollageExplosionExtraStyle())
    registry.register(InkAndPaintExtraStyle())
    registry.register(NeonSignWorldExtraStyle())
  }
}
