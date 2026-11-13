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
// LYRIC-ONLY RE-SCOPE (2026-11-13, Jaizon ~10:28 MST: "no styles
// that take up the whole screen just lyrics with cool animations").
// The video is the star: every full-screen background, wash,
// collage, particle field, and full-frame panel is gone from this
// file. What remains is words on the footage, with word-by-word
// entrances tied to the lyric timing, emphasis pops from the
// stored intelligence, and ONE thin word-attached accent per style
// (a rule, a block, a paper chip, a brush stroke, a tight halo)
// that never covers the frame. Style IDs are unchanged.
//   - Editorial: paper background, masthead, pull-quote, body
//     columns, and folio are gone; the headline words (serif,
//     word-by-word rise, emphasis words in accent) sit on a
//     paper strip sized to the words, between two rule lines.
//   - Brutalist: paper background, full-width flash/beat bars,
//     and the foot index strip are gone; the massive words slam
//     in word by word on one accent block sized to the line,
//     with short bars above/below it.
//   - Collage: paper-texture + halftone full-screen backgrounds
//     and the three corner stickers are gone; torn-paper scraps
//     stay behind each word, cutout letters stay, and the small
//     star bursts now pin to emphasis words only. The line's
//     emoji rides at the end of the lyric line, ungated.
//   - Ink: rice-paper background, the splash emitter, and the
//     scattered splat dots are gone; brush strokes stay under
//     the words, blots are constrained to the lyric line's width,
//     and the words bleed in word by word (marker), with a small
//     splat on emphasis words only.
//   - Neon: night background, sign backing panel, reflection,
//     and reflection fade band are gone; the words buzz in word
//     by word with the tube-activation ramp, the layered glow
//     copies stay, and the halo is shrunk tight around the words.
// Legibility: text that sits directly on footage carries an
// outline stroke (Ink, Neon); text that sits on its own
// word-attached chip/block needs none (Editorial strip,
// Brutalist block, Collage scraps).
//
// Engine limits encountered while building (see the Phase 3 report):
//   - No path-progress track: Ink strokes reveal with an opacity
//     envelope, not a true stroke draw-on.
//   - No node blur/glow property: Neon glow is layered text copies
//     (larger, low-opacity, .screen) + a tight radial halo.
//   - Node scale is a uniform CGFloat: the Neon reflection cannot
//     be a true vertical flip (1, -1) — and the reflection is gone
//     in the lyric-only re-scope anyway (a second, faded lyric
//     rendering is not lyrics-only).
//   - No layout keyframes: Editorial no longer swaps layouts —
//     one headline word row, rules sized to it.
//   - No step/hold easing: Brutalist hard cuts are adjacent
//     keyframes 1 frame apart (linear).
//   - Word/char layout is uniform-size: a mixed-size drop cap
//     (Editorial) would need a custom layout pass, so the headline
//     keeps one size and the emphasis words carry the accent.

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

/// One word's measured placement on a single centred row.
private struct DesignWordPlacement {
  var index: Int
  var text: String
  var centerX: CGFloat
  var width: CGFloat
  var startFrame: Int
  var endFrame: Int
}

/// Word placements measured at one font/size, centred on the canvas.
/// Falls back to splitting the line text (staggered starts) when the
/// line carries no word timings. Same measurement the word/char node
/// helpers use, so accents placed from these land on their words.
private func designWordPlacements(
  line: ExtraStyleInputLine, fps: Double,
  lineStartFrame: Int, lineEndFrame: Int,
  font: String, sizePoints: CGFloat, canvasWidth: CGFloat,
  staggerFrames: Int = 3
) -> (placements: [DesignWordPlacement], totalWidth: CGFloat) {
  let raw: [(text: String, start: Int, end: Int)]
  if !line.words.isEmpty {
    raw = line.words.enumerated().map { (index, word) in
      let start = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
      let end = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
      return (
        text: word.text,
        start: start,
        end: end > start ? end : lineEndFrame
      )
    }
  } else {
    raw = designWords(of: line).enumerated().map { (index, word) in
      (
        text: word,
        start: min(lineEndFrame, lineStartFrame + index * staggerFrames),
        end: lineEndFrame
      )
    }
  }
  guard !raw.isEmpty else { return ([], 0) }
  let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
  let widths = raw.map { extraStyleTextWidth($0.text, fontPostScriptName: font, sizePoints: sizePoints) }
  let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, raw.count - 1))
  var cursorX = (canvasWidth - totalWidth) / 2
  var placements: [DesignWordPlacement] = []
  for (index, word) in raw.enumerated() {
    placements.append(DesignWordPlacement(
      index: index, text: word.text,
      centerX: cursorX + widths[index] / 2, width: widths[index],
      startFrame: word.start, endFrame: word.end
    ))
    cursorX += widths[index] + spaceWidth
  }
  return (placements, totalWidth)
}

/// Timed lyric nodes: per-word nodes when the line carries word
/// timings, per-character nodes otherwise. The caller owns emphasis
/// recolouring — see designRecolorEmphasisWords, which must only
/// run on the word path (character indices are not word indices).
private func designLyricNodes(
  line: ExtraStyleInputLine, lineIndex: Int, fps: Double,
  lineStartFrame: Int, lineEndFrame: Int,
  y: CGFloat, sizePoints: CGFloat, color: ExtraStyleRGBA, font: String,
  zIndex: Int, canvasWidth: CGFloat,
  colorParamId: String? = nil,
  wordTracks: ((Int, Int, Int) -> [ExtraStyleTrack])? = nil,
  charTracks: ((Int, Int, Int) -> [ExtraStyleTrack])? = nil
) -> [ExtraStyleNode] {
  let words = extraStyleWordNodes(
    line: line, lineIndex: lineIndex, fps: fps,
    lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
    y: y, sizePoints: sizePoints, color: color, font: font, zIndex: zIndex,
    canvasWidth: canvasWidth, colorParamId: colorParamId, trackBuilder: wordTracks
  )
  if !words.isEmpty { return words }
  return extraStyleCharNodes(
    text: line.text, lineIndex: lineIndex,
    lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
    y: y, sizePoints: sizePoints, color: color, font: font, zIndex: zIndex,
    canvasWidth: canvasWidth, trackBuilder: charTracks ?? wordTracks
  )
}

/// Which word indices actually produced a node. extraStyleWordNodes
/// skips a word whose window is empty, so node position and word
/// index only line up through this mapping.
private func designSurvivingWordIndices(
  line: ExtraStyleInputLine, fps: Double,
  lineStartFrame: Int, lineEndFrame: Int, staggerFrames: Int = 3
) -> [Int] {
  var surviving: [Int] = []
  for (index, word) in line.words.enumerated() {
    let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
    let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
    let startFrame = wordEndFrame > wordStartFrame
      ? wordStartFrame : min(lineEndFrame, lineStartFrame + index * staggerFrames)
    let endFrame = wordEndFrame > wordStartFrame ? wordEndFrame : lineEndFrame
    if endFrame > startFrame { surviving.append(index) }
  }
  return surviving
}

/// Recolour the emphasis words of a word-path node array (nodes in
/// word order, as designLyricNodes returns them when line.words is
/// non-empty). No-op on the character path.
private func designRecolorEmphasisWords(
  nodes: [ExtraStyleNode], line: ExtraStyleInputLine, fps: Double,
  lineStartFrame: Int, lineEndFrame: Int,
  color: ExtraStyleRGBA, colorParamId: String?
) -> [ExtraStyleNode] {
  guard !line.words.isEmpty else { return nodes }
  let surviving = designSurvivingWordIndices(
    line: line, fps: fps, lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame
  )
  return nodes.enumerated().map { (position, node) in
    var node = node
    if position < surviving.count, line.emphasisWordIndices.contains(surviving[position]) {
      node.text?.color = color
      node.text?.colorParamId = colorParamId
    }
    return node
  }
}

/// Uppercase every lyric node (Brutalist).
private func designUppercaseLyricNodes(_ nodes: [ExtraStyleNode]) -> [ExtraStyleNode] {
  nodes.map { node in
    var node = node
    if let text = node.text?.text {
      node.text?.text = text.uppercased()
    }
    return node
  }
}

/// Outline every lyric node so it reads over any footage.
private func designOutlineLyricNodes(
  nodes: [ExtraStyleNode], strokeColor: ExtraStyleRGBA, strokeWidthPoints: CGFloat
) -> [ExtraStyleNode] {
  nodes.map { node in
    var node = node
    node.text?.strokeColor = strokeColor
    node.text?.strokeWidthPoints = strokeWidthPoints
    return node
  }
}

// MARK: - Style 16: Editorial Magazine (design)

final class EditorialMagazineExtraStyle: ExtraStyleDefinition {
  let id = "editorial-magazine"
  let version = 1
  let name = "Editorial Magazine"
  let tagline = "Headlines and rule lines — lyrics in print."
  let category = "design"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false
  let rebuildParamIds = ["headlineSize"]

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "headlineSize", label: "Headline size", min: 0.5, max: 1.5, step: 0.05,
        default: 1, affects: "layout"
      ),
      extraStyleColorParam(id: "ink", label: "Ink colour", default: "#1A1A1A", affects: "appearance"),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C0392B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "broadsheet", "label": "Broadsheet", "values": ["headlineSize": 1.2]],
      ["id": "tabloid", "label": "Tabloid", "values": ["headlineSize": 1.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let headlineScale = extraStyleParamDouble(input.params, "headlineSize", 1)
    let ink = extraStyleColor(extraStyleParamString(input.params, "ink", "#1A1A1A"))
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C0392B"))
    let paper = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let headlineSize = canvas.width * 0.072 * CGFloat(headlineScale)
      let headlineY = canvas.height * 0.46
      let (_, totalWidth) = designWordPlacements(
        line: line, fps: fps, lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        font: ExtraStyleFonts.serif, sizePoints: headlineSize, canvasWidth: canvas.width
      )
      let stripWidth = min(canvas.width * 0.9, totalWidth + 56)

      // Headline strip: a paper chip sized to the words — the
      // contrast the words sit on, so no outline is needed.
      builder.add(extraStyleShapeNode(
        id: "ed-strip-\(lineIndex)",
        shape: extraStyleRectShape(width: stripWidth, height: headlineSize * 1.6),
        fill: paper,
        stroke: ink, strokeWidth: 2,
        position: CGPoint(x: canvas.width / 2, y: headlineY),
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 10, exitFrames: 9)]
      ))

      // Headline words: rise in one by one at their sung starts;
      // emphasis words slam in with a spring and turn accent.
      var wordNodes = designLyricNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: headlineY, sizePoints: headlineSize, color: ink, font: ExtraStyleFonts.serif,
        zIndex: 10, canvasWidth: canvas.width, colorParamId: "ink"
      ) { index, wordStartFrame, wordEndFrame in
        let opacity = extraStyleEnterExitOpacityTrack(
          start: wordStartFrame, end: wordEndFrame, enterFrames: 6, exitFrames: 9
        )
        if line.emphasisWordIndices.contains(index) {
          return [
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.2, to: 1, stiffness: 220, damping: 9, initialVelocity: 0),
              startFrame: wordStartFrame
            ),
            opacity,
          ]
        }
        return [
          ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: -14, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 8), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ),
          opacity,
        ]
      }
      wordNodes = designRecolorEmphasisWords(
        nodes: wordNodes, line: line, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        color: accent, colorParamId: "accent"
      )
      for node in wordNodes { builder.add(node) }

      // Rule lines above and below the headline, sized to the
      // words (not the frame), staggered in.
      for (ruleIndex, ruleY) in [headlineY - headlineSize * 0.95, headlineY + headlineSize * 0.95].enumerated() {
        builder.add(ExtraStyleNode(
          id: "ed-rule-\(lineIndex)-\(ruleIndex)", kind: .path,
          position: CGPoint(x: canvas.width / 2, y: ruleY),
          anchor: CGPoint(x: 0.5, y: 0.5), zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: designRulePath(width: stripWidth),
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
  // onset pop on the words read it directly. No missing-automation
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
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#FF3B00", affects: "appearance"),
      extraStyleSliderParam(
        id: "slideDistance", label: "Slide distance", min: 0, max: 300, step: 10,
        default: 140, affects: "motion", unit: "pt"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "poster", "label": "Poster", "values": ["slideDistance": 220]],
      ["id": "stark", "label": "Stark", "values": ["slideDistance": 60]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let ink = extraStyleColor(extraStyleParamString(input.params, "ink", "#111111"))
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FF3B00"))
    let slideDistance = extraStyleParamDouble(input.params, "slideDistance", 140)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 201))
      // Unexpected placement: per-line anchor — alternating band,
      // seeded horizontal offset and tilt.
      let bandY = canvas.height * [0.36, 0.52, 0.66][lineIndex % 3]
      let centerX = canvas.width / 2 + CGFloat(random.nextRange(min: -0.08, max: 0.08)) * canvas.width
      let tilt = CGFloat(random.nextRange(min: -3, max: 3))
      let sizePoints = canvas.width * 0.105

      // Accent block behind the words, sized to the line and
      // offset like a misprint — the contrast the words sit on.
      let textWidth = extraStyleTextWidth(line.text.uppercased(), fontPostScriptName: ExtraStyleFonts.black, sizePoints: sizePoints)
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

      // The massive words: hard cut in, aggressive slide, onset
      // pop on the scale — emphasis words pop harder.
      let wordNodes = designLyricNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: bandY, sizePoints: sizePoints, color: ink, font: ExtraStyleFonts.black,
        zIndex: 10, canvasWidth: canvas.width, colorParamId: "ink"
      ) { index, wordStartFrame, wordEndFrame in
        let slideFrom: Double = index % 2 == 0 ? -slideDistance : slideDistance
        return [
          designHardCutOpacityTrack(start: wordStartFrame, end: wordEndFrame),
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: slideFrom, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 4), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(
              input: .onset, base: 1,
              gain: line.emphasisWordIndices.contains(index) ? 0.18 : 0.1
            ),
            startFrame: wordStartFrame
          ),
        ]
      }
      let styledNodes = designUppercaseLyricNodes(wordNodes).map { node -> ExtraStyleNode in
        var node = node
        node.rotationDeg = tilt
        return node
      }
      for node in styledNodes { builder.add(node) }

      // Geometric bars: one ink bar, one accent bar, seeded
      // lengths, hard-cut with the line — short, sized to the
      // words, not the frame.
      for barIndex in 0..<2 {
        let barWidth = min(blockWidth, CGFloat(random.nextRange(min: 0.2, max: 0.55)) * canvas.width)
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
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 18: Collage Explosion (design)

final class CollageExplosionExtraStyle: ExtraStyleDefinition {
  let id = "collage-explosion"
  let version = 1
  let name = "Collage Explosion"
  let tagline = "Cut-out letters on torn-paper word chips."
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
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "scrapbook", "label": "Scrapbook", "values": ["tilt": 20]],
      ["id": "tidy", "label": "Tidy", "values": ["tilt": 5]],
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
      let (placements, totalWidth) = designWordPlacements(
        line: line, fps: fps, lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        font: ExtraStyleFonts.black, sizePoints: sizePoints, canvasWidth: canvas.width
      )

      // Torn-paper scraps behind each word: rotated rects with a
      // bold outline, one per word — the contrast the letters sit
      // on. Emphasis words get a small star burst pinned above
      // the word, and nothing else decorates the frame.
      for placement in placements {
        let scrapRotation = CGFloat(random.nextRange(min: -maxTilt, max: maxTilt))
        builder.add(extraStyleShapeNode(
          id: "co-scrap-\(lineIndex)-\(placement.index)",
          shape: extraStyleRectShape(width: placement.width + 28, height: sizePoints * 1.5),
          fill: paperTint,
          stroke: ink, strokeWidth: 3,
          position: CGPoint(x: placement.centerX, y: lineY),
          zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          fillColorParamId: "paperTint",
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 10, initialVelocity: 0),
              startFrame: placement.startFrame
            ),
          ]
        ))
        // Rotate the scrap via a rotation track (single key =
        // held tilt): shape nodes carry no rotation param in
        // the helper, so the track does it.
        if var scrap = builder.nodes["co-scrap-\(lineIndex)-\(placement.index)"] {
          scrap.tracks.append(ExtraStyleTrack(
            property: .rotationDeg,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: placement.startFrame, value: Double(scrapRotation), easing: .linear)]),
            startFrame: placement.startFrame
          ))
          builder.nodes["co-scrap-\(lineIndex)-\(placement.index)"] = scrap
        }
        if line.emphasisWordIndices.contains(placement.index) {
          builder.add(extraStyleShapeNode(
            id: "co-star-\(lineIndex)-\(placement.index)",
            shape: extraStyleStarShape(outerRadius: sizePoints * 0.3, innerRadius: sizePoints * 0.14, spikes: 5),
            fill: accent,
            stroke: ink, strokeWidth: 2,
            position: CGPoint(x: placement.centerX, y: lineY - sizePoints * 1.05),
            zIndex: 12,
            visibleRange: lineStartFrame...lineEndFrame,
            fillColorParamId: "accent",
            tracks: [
              ExtraStyleTrack(
                property: .scale,
                kind: .spring(from: 0.2, to: 1, stiffness: 220, damping: 9, initialVelocity: 0),
                startFrame: placement.startFrame
              ),
            ]
          ))
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

      // The line's stored emoji, tucked at the end of the lyric
      // line — unconditional, never gated (see the builders' emoji
      // note). Nothing when the line has no stored emoji.
      if let emojiNode = extraStyleEmojiNode(
        id: "co-emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width * 0.92, canvas.width / 2 + totalWidth / 2 + canvas.width * 0.06),
          y: lineY
        ),
        sizePoints: canvas.width * 0.08, zIndex: 12,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(emojiNode)
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
  let tagline = "Brush strokes and ink blots, word by word."
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
      extraStyleToggleParam(id: "bleed", label: "Ink bleed", default: true, affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "sumi", "label": "Sumi", "values": ["brushWidth": 16]],
      ["id": "splashy", "label": "Loose", "values": ["brushWidth": 8]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let ink = extraStyleColor(extraStyleParamString(input.params, "ink", "#1B1B2E"))
    let brushWidth = CGFloat(extraStyleParamDouble(input.params, "brushWidth", 10))
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 401))
      let sizePoints = canvas.width * 0.072
      let centerY = canvas.height * 0.48
      let textWidth = min(canvas.width * 0.86, extraStyleTextWidth(line.text, fontPostScriptName: ExtraStyleFonts.marker, sizePoints: sizePoints))
      let leftX = canvas.width / 2 - textWidth / 2
      let rightX = canvas.width / 2 + textWidth / 2
      let (placements, _) = designWordPlacements(
        line: line, fps: fps, lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        font: ExtraStyleFonts.marker, sizePoints: sizePoints, canvasWidth: canvas.width
      )

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
      // the bleed toggle is on. Blots stay inside the lyric
      // line's width and close to it — no frame scatter.
      for blotIndex in 0..<2 {
        let blotW = CGFloat(random.nextRange(min: 0.05, max: 0.11)) * canvas.width
        let blotH = blotW * CGFloat(random.nextRange(min: 0.6, max: 1.1))
        let maxBlotOffset = max(0, (textWidth - blotW) / 2)
        let blotX = canvas.width / 2 + CGFloat(random.nextRange(min: -Double(maxBlotOffset), max: Double(maxBlotOffset)))
        let blotY = centerY + CGFloat(random.nextRange(min: -0.05, max: 0.05)) * canvas.height
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

      // A small paint splat pinned above each emphasis word only.
      for placement in placements where line.emphasisWordIndices.contains(placement.index) {
        let splatSize = sizePoints * CGFloat(random.nextRange(min: 0.18, max: 0.26))
        builder.add(extraStyleShapeNode(
          id: "ink-splat-\(lineIndex)-\(placement.index)",
          shape: extraStyleEllipseShape(width: splatSize, height: splatSize * CGFloat(random.nextRange(min: 0.6, max: 1))),
          fill: ink.withAlpha(0.8),
          position: CGPoint(x: placement.centerX, y: centerY - sizePoints * 1.0),
          zIndex: 8,
          visibleRange: lineStartFrame...lineEndFrame,
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 10, initialVelocity: 0),
              startFrame: placement.startFrame
            ),
          ]
        ))
      }

      // The words themselves, in marker — the hand-painted voice —
      // bleeding in word by word at their sung starts, emphasis
      // words with a harder spring. A light outline keeps them
      // readable over any footage.
      var wordNodes = designLyricNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints, color: ink, font: ExtraStyleFonts.marker,
        zIndex: 10, canvasWidth: canvas.width, colorParamId: "ink"
      ) { index, wordStartFrame, wordEndFrame in
        let isEmphasis = line.emphasisWordIndices.contains(index)
        return [
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(
              from: isEmphasis ? 0.2 : 0.3, to: 1,
              stiffness: isEmphasis ? 180 : 140, damping: 12, initialVelocity: 0
            ),
            startFrame: wordStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: wordStartFrame, end: wordEndFrame, enterFrames: 8, exitFrames: 9),
        ]
      }
      wordNodes = designOutlineLyricNodes(
        nodes: wordNodes,
        strokeColor: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.9),
        strokeWidthPoints: max(2, sizePoints * 0.04)
      )
      for node in wordNodes { builder.add(node) }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 20: Neon Sign World (design)

final class NeonSignWorldExtraStyle: ExtraStyleDefinition {
  let id = "neon-sign-world"
  let version = 1
  let name = "Neon Sign World"
  let tagline = "Buzzing neon words, glowing over the video."
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

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let neon = extraStyleColor(extraStyleParamString(input.params, "neon", "#FF2E88"))
    let signStyle = extraStyleParamString(input.params, "signStyle", "tube")
    var builder = ExtraStyleSceneBuilder()

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
      let signCenter = CGPoint(x: canvas.width / 2, y: signY)
      let textWidth = extraStyleTextWidth(line.text, fontPostScriptName: font, sizePoints: sizePoints)

      // Halo: a radial wash tight around the words (radius from
      // the measured lyric width, not the frame). Position is the
      // canvas centre (not the sign centre): the gradient rect is
      // the full canvas in local space, so only a centre position
      // lands local (0, 0) on canvas (0, 0) and puts the radial
      // centre exactly on the words.
      builder.add(ExtraStyleNode(
        id: "ne-halo-\(lineIndex)", kind: .gradient,
        position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 8,
        visibleRange: lineStartFrame...lineEndFrame,
        gradient: ExtraStyleGradientContent(
          kind: .radial(center: signCenter, radius: max(textWidth * 0.75, sizePoints * 2.0)),
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

      // The tube itself, word by word: electrical activation — a
      // flickering ramp (off, buzz, off, on) then steady — per
      // word at its sung start, with a glow swell (spring scale)
      // as it powers up. A thin white core stroke reads as the
      // hot tube centre and keeps the words legible.
      var wordNodes = designLyricNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: signY, sizePoints: sizePoints, color: neon, font: font,
        zIndex: 11, canvasWidth: canvas.width, colorParamId: "neon"
      ) { _, wordStartFrame, wordEndFrame in
        [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 2), value: 0.65, easing: .linear),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 4), value: 0.12, easing: .linear),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 7), value: 0.9, easing: .linear),
              ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 12), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(wordStartFrame, wordEndFrame - 9), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: wordEndFrame, value: 0, easing: .easeInCubic),
            ]),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.92, to: 1, stiffness: 160, damping: 12, initialVelocity: 0),
            startFrame: wordStartFrame
          ),
        ]
      }
      wordNodes = designOutlineLyricNodes(
        nodes: wordNodes,
        strokeColor: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.85),
        strokeWidthPoints: max(1.5, sizePoints * 0.03)
      )
      for node in wordNodes { builder.add(node) }
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
