import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3: Playful / Storytelling (rest)
//
// Cartoon Universe (#22), Message Universe (#23), Sticker World
// (#24) — docs/EXTRA-STYLES-2.0.md §17. All three are FALSE /
// FALSE for needsAudioAutomation / needsSubjectMasks (verified
// against src/lib/extra-styles/catalog.ts STYLE_CAPABILITY_MAP),
// so they never require automation or masks and read neither.
//
// LYRIC-ONLY RE-SCOPE (2026-11-13, Jaizon ~10:28 MST: "no styles
// that take up the whole screen just lyrics with cool animations").
// The video is the star: the full-screen sky / chat / paper
// backdrops are gone from this file, and the Sticker World ring
// that crowded the whole frame is gone too. What remains is words
// on the footage: word-by-word entrances tied to the lyric timing,
// emphasis pops from the stored intelligence, and small accents
// pinned to the words (a star burst, a reaction emoji, a sticker
// at the line's end). The chat/speech bubbles stay — they are
// sized to the words, not the frame — and the words inside them
// now type/pop in one by one instead of arriving as one block.
// Style IDs are unchanged.
//
// NOTE: the other two playful styles — Emoji Storytelling and
// Comic Book — live in ExtraStylesDemos.swift, NOT in this file,
// so they are NOT re-scoped here. Whoever owns Demos.swift needs
// to: strip Emoji Storytelling's tone-tinted full-canvas radial
// backdrop wash (keep the hero emoji + words, small and attached
// to the line) and shrink Comic Book's full panel (0.88W × 0.52H
// board) down to bold words with pop/slam entrances and small
// burst accents on emphasis words only. The unconditional emoji
// passthrough (extraStyleEmojiNode, no gate) must survive both.
//
// Shared notes:
// - Speech / chat bubbles are groups: a rounded-rect path shape
//   (+ a tail triangle for Cartoon) with word children, so the
//   whole bubble pops / slides as one unit while the words inside
//   arrive one by one.
// - No path-trim / draw-progress track kind exists in the engine,
//   so motion lines reveal with an opacity envelope (plus a short
//   scale-in on the burst shapes), not a stroke draw-on.
// - No rounded-rect shape kind exists either; bubbles use a
//   CGPath rounded rect as a `.path` shape kind, in positive
//   local space starting at (0, 0) so anchor math centres them.
// - Stickers are procedural shapes (the asset registry holds no
//   sticker art): star / heart / bolt / circle / rounded-rect,
//   each with a bold white stroke and an offset dark shadow layer.

// MARK: - Shared playful helpers

/// A rounded-rect path in positive local space (0, 0) → (w, h).
private func extraStylePlayfulRoundedRectPath(width: CGFloat, height: CGFloat, radius: CGFloat) -> CGPath {
  CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
    cornerWidth: radius, cornerHeight: radius, transform: nil
  )
}

/// A heart path in positive local space (0, 0) → (s, s).
private func extraStylePlayfulHeartPath(size s: CGFloat) -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: s * 0.5, y: s * 0.92))
  path.addCurve(
    to: CGPoint(x: s * 0.02, y: s * 0.38),
    control1: CGPoint(x: s * 0.18, y: s * 0.68),
    control2: CGPoint(x: s * 0.0, y: s * 0.52)
  )
  path.addCurve(
    to: CGPoint(x: s * 0.5, y: s * 0.18),
    control1: CGPoint(x: s * 0.05, y: s * 0.18),
    control2: CGPoint(x: s * 0.28, y: s * 0.05)
  )
  path.addCurve(
    to: CGPoint(x: s * 0.98, y: s * 0.38),
    control1: CGPoint(x: s * 0.72, y: s * 0.05),
    control2: CGPoint(x: s * 0.95, y: s * 0.18)
  )
  path.addCurve(
    to: CGPoint(x: s * 0.5, y: s * 0.92),
    control1: CGPoint(x: s * 1.0, y: s * 0.52),
    control2: CGPoint(x: s * 0.82, y: s * 0.68)
  )
  path.closeSubpath()
  return path
}

/// A lightning-bolt polygon in positive local space (0, 0) → (s, s).
private func extraStylePlayfulBoltPath(size s: CGFloat) -> CGPath {
  let path = CGMutablePath()
  let points: [CGPoint] = [
    CGPoint(x: s * 0.62, y: 0),
    CGPoint(x: s * 0.12, y: s * 0.55),
    CGPoint(x: s * 0.44, y: s * 0.55),
    CGPoint(x: s * 0.34, y: s),
    CGPoint(x: s * 0.88, y: s * 0.42),
    CGPoint(x: s * 0.54, y: s * 0.42),
  ]
  path.addLines(between: points)
  path.closeSubpath()
  return path
}

/// A speech-bubble tail triangle in positive local space
/// (0, 0) → (width, height), apex pointing down.
private func extraStylePlayfulTailPath(width: CGFloat, height: CGFloat) -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: 0, y: 0))
  path.addLine(to: CGPoint(x: width, y: 0))
  path.addLine(to: CGPoint(x: width * 0.45, y: height))
  path.closeSubpath()
  return path
}

/// One word's placement on a centred, greedily wrapped row layout.
/// `x` / `y` are offsets from the line's centre, so the same
/// placements work as group-local coordinates (Cartoon, Message)
/// or shifted onto the canvas (Sticker).
private struct PlayfulWordPlacement {
  var index: Int
  var text: String
  var x: CGFloat
  var y: CGFloat
  var width: CGFloat
  var startFrame: Int
  var endFrame: Int
}

/// Word placements laid out in centred rows no wider than
/// `maxWidth`. Falls back to splitting the line text (staggered
/// starts) when the line carries no word timings.
private func playfulWordPlacements(
  line: ExtraStyleInputLine, fps: Double,
  lineStartFrame: Int, lineEndFrame: Int,
  font: String, sizePoints: CGFloat, maxWidth: CGFloat, lineHeight: CGFloat,
  staggerFrames: Int = 3
) -> (placements: [PlayfulWordPlacement], totalWidth: CGFloat, totalHeight: CGFloat) {
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
    raw = line.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.enumerated().map { (index, word) in
      (
        text: word,
        start: min(lineEndFrame, lineStartFrame + index * staggerFrames),
        end: lineEndFrame
      )
    }
  }
  guard !raw.isEmpty else { return ([], 0, 0) }
  let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
  let widths = raw.map { extraStyleTextWidth($0.text, fontPostScriptName: font, sizePoints: sizePoints) }
  // Greedy rows.
  var rows: [[Int]] = [[]]
  var rowWidths: [CGFloat] = [0]
  for (index, _) in raw.enumerated() {
    let needed = rowWidths[rowWidths.count - 1] == 0
      ? widths[index]
      : rowWidths[rowWidths.count - 1] + spaceWidth + widths[index]
    if needed > maxWidth, !rows[rows.count - 1].isEmpty {
      rows.append([index])
      rowWidths.append(widths[index])
    } else {
      rows[rows.count - 1].append(index)
      rowWidths[rowWidths.count - 1] = needed
    }
  }
  let totalWidth = rowWidths.max() ?? 0
  let totalHeight = CGFloat(rows.count) * lineHeight
  var placements: [PlayfulWordPlacement] = []
  for (rowIndex, row) in rows.enumerated() {
    var cursorX = -rowWidths[rowIndex] / 2
    let y = (CGFloat(rowIndex) - CGFloat(rows.count - 1) / 2) * lineHeight
    for index in row {
      placements.append(PlayfulWordPlacement(
        index: index, text: raw[index].text,
        x: cursorX + widths[index] / 2, y: y, width: widths[index],
        startFrame: raw[index].start, endFrame: raw[index].end
      ))
      cursorX += widths[index] + spaceWidth
    }
  }
  return (placements, totalWidth, totalHeight)
}

// MARK: - Style 22: Cartoon Universe (playful)

final class CartoonUniverseExtraStyle: ExtraStyleDefinition {
  let id = "cartoon-universe"
  let version = 1
  let name = "Cartoon Universe"
  let tagline = "Bouncy cartoon words in speech bubbles."
  let category = "playful"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "bubbleStyle", label: "Bubble style",
        options: [("speech", "Speech"), ("thought", "Thought"), ("shout", "Shout")],
        default: "speech", affects: "layout"
      ),
      extraStyleColorParam(id: "bubbleColor", label: "Bubble colour", default: "#FFFFFF", affects: "appearance"),
      extraStyleSliderParam(
        id: "popScale", label: "Pop size", min: 0.5, max: 1.5, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleToggleParam(id: "motionLines", label: "Motion lines", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "loud", "label": "Loud", "values": ["bubbleStyle": "shout", "popScale": 1.3]],
      ["id": "quiet", "label": "Quiet", "values": ["bubbleStyle": "thought", "popScale": 0.85, "motionLines": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }
  var rebuildParamIds: [String] { ["bubbleStyle"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let bubbleStyle = extraStyleParamString(input.params, "bubbleStyle", "speech")
    let bubbleColor = extraStyleColor(extraStyleParamString(input.params, "bubbleColor", "#FFFFFF"))
    let ink = ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.06, a: 1)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 1))
      let sizePoints = canvas.width * 0.055
      let lineHeight = sizePoints * 1.35
      let (placements, totalWidth, totalHeight) = playfulWordPlacements(
        line: line, fps: fps, lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        font: ExtraStyleFonts.marker, sizePoints: sizePoints,
        maxWidth: canvas.width * 0.68, lineHeight: lineHeight
      )
      guard !placements.isEmpty else { continue }
      let bubbleWidth = min(canvas.width * 0.86, max(totalWidth + 72, canvas.width * 0.42))
      let bubbleHeight = totalHeight + 58
      // Alternate sides / heights so consecutive bubbles feel
      // like a back-and-forth, and give each a slight tilt.
      let side: CGFloat = lineIndex % 2 == 0 ? -1 : 1
      let bubbleCenter = CGPoint(
        x: canvas.width / 2 + side * canvas.width * 0.05,
        y: canvas.height * (lineIndex % 2 == 0 ? 0.44 : 0.58)
      )
      let rotation = CGFloat(random.nextRange(min: -2, max: 2))
      let tailSide: CGFloat = side > 0 ? -1 : 1
      let tailX = tailSide * bubbleWidth * 0.22

      var members: [String] = []

      // Bubble body: rounded-rect path shape, ink outline.
      // "Shout" gets a starburst body instead of a rounded rect.
      let bodyId = "bubble-body-\(lineIndex)"
      if bubbleStyle == "shout" {
        builder.addChild(extraStyleShapeNode(
          id: bodyId,
          shape: extraStyleStarShape(
            outerRadius: max(bubbleWidth, bubbleHeight) * 0.62,
            innerRadius: max(bubbleWidth, bubbleHeight) * 0.44, spikes: 10
          ),
          fill: bubbleColor,
          stroke: ink, strokeWidth: 5,
          position: .zero, zIndex: 0,
          fillColorParamId: "bubbleColor"
        ))
      } else {
        builder.addChild(extraStyleShapeNode(
          id: bodyId,
          shape: .path(extraStylePlayfulRoundedRectPath(
            width: bubbleWidth, height: bubbleHeight, radius: 28
          )),
          fill: bubbleColor,
          stroke: ink, strokeWidth: 5,
          position: .zero, zIndex: 0,
          fillColorParamId: "bubbleColor"
        ))
      }
      members.append(bodyId)

      // Tail (speech) or thought bubbles (thought): a small
      // triangle tail, or two shrinking circles trailing down.
      if bubbleStyle == "thought" {
        for (dotIndex, dotSize) in [CGFloat(26), CGFloat(16)].enumerated() {
          let dotId = "bubble-thought-\(lineIndex)-\(dotIndex)"
          builder.addChild(extraStyleShapeNode(
            id: dotId,
            shape: extraStyleEllipseShape(width: dotSize, height: dotSize),
            fill: bubbleColor,
            stroke: ink, strokeWidth: 3,
            position: CGPoint(x: tailX, y: bubbleHeight / 2 + 26 + CGFloat(dotIndex) * 30),
            zIndex: 0,
            fillColorParamId: "bubbleColor"
          ))
          members.append(dotId)
        }
      } else {
        let tailId = "bubble-tail-\(lineIndex)"
        builder.addChild(extraStyleShapeNode(
          id: tailId,
          shape: .path(extraStylePlayfulTailPath(width: 44, height: 38)),
          fill: bubbleColor,
          stroke: ink, strokeWidth: 5,
          position: CGPoint(x: tailX, y: bubbleHeight / 2 + 14),
          zIndex: 0,
          fillColorParamId: "bubbleColor"
        ))
        members.append(tailId)
      }

      // The words, inside the bubble — bouncing in one by one at
      // their sung starts (spring scale + a short rise), instead
      // of arriving as one block. The bubble is the contrast the
      // words sit on, so no outline is needed.
      for placement in placements {
        guard placement.endFrame > placement.startFrame else { continue }
        let wordId = "bubble-word-\(lineIndex)-\(placement.index)"
        builder.addChild(extraStyleTextNode(
          id: wordId,
          text: placement.text, font: ExtraStyleFonts.marker, sizePoints: sizePoints,
          color: ink,
          position: CGPoint(x: placement.x, y: placement.y - 2),
          zIndex: 1,
          visibleRange: placement.startFrame...placement.endFrame,
          tracks: [
            extraStyleSpringInTrack(start: placement.startFrame, from: 0.55, stiffness: 170, damping: 11),
            ExtraStyleTrack(
              property: .positionY,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: placement.startFrame, value: -12, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(placement.endFrame, placement.startFrame + 8), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: placement.startFrame
            ),
            extraStyleEnterExitOpacityTrack(start: placement.startFrame, end: placement.endFrame, enterFrames: 6, exitFrames: 9),
          ]
        ))
        members.append(wordId)

        // Emphasis words get a small star burst pinned above the
        // word — the only burst in the style, and it is attached
        // to the word, not scattered over the frame.
        if line.emphasisWordIndices.contains(placement.index) {
          let burstId = "bubble-burst-\(lineIndex)-\(placement.index)"
          let burstSize = canvas.width * 0.045
          builder.addChild(extraStyleShapeNode(
            id: burstId,
            shape: extraStyleStarShape(outerRadius: burstSize, innerRadius: burstSize * 0.45, spikes: 5),
            fill: extraStyleToneColor(line.tone),
            stroke: ink, strokeWidth: 3,
            position: CGPoint(x: placement.x, y: placement.y - sizePoints * 1.15),
            zIndex: 2,
            visibleRange: placement.startFrame...placement.endFrame,
            tracks: [extraStyleSpringInTrack(start: placement.startFrame + 2, from: 0.2, stiffness: 200, damping: 9)]
          ))
          members.append(burstId)
        }
      }

      // A small star accent at the bubble corner, springing in.
      let starId = "bubble-star-\(lineIndex)"
      let starSize = canvas.width * 0.05
      builder.addChild(extraStyleShapeNode(
        id: starId,
        shape: extraStyleStarShape(outerRadius: starSize, innerRadius: starSize * 0.45, spikes: 5),
        fill: extraStyleToneColor(line.tone),
        stroke: ink, strokeWidth: 3,
        position: CGPoint(x: bubbleWidth / 2 - 6, y: -bubbleHeight / 2 + 6),
        zIndex: 2,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [extraStyleSpringInTrack(start: lineStartFrame + 4, from: 0.2, stiffness: 200, damping: 9)]
      ))
      members.append(starId)

      // Motion lines radiating from the bubble edge. No
      // path-trim support exists, so they reveal with an opacity
      // envelope (gated by the motionLines toggle) instead of a
      // stroke draw-on.
      for ray in 0..<3 {
        let rayId = "bubble-ray-\(lineIndex)-\(ray)"
        let rayY = -bubbleHeight * 0.28 + CGFloat(ray) * bubbleHeight * 0.28
        let rayPath = CGMutablePath()
        rayPath.move(to: CGPoint(x: -bubbleWidth / 2 - 12, y: rayY))
        rayPath.addLine(to: CGPoint(x: -bubbleWidth / 2 - 58, y: rayY - 8 + CGFloat(ray) * 8))
        builder.addChild(ExtraStyleNode(
          id: rayId, kind: .path,
          position: .zero, anchor: .zero,
          zIndex: 2,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: rayPath,
            strokeColor: ink.withAlpha(0.85),
            strokeWidth: 5,
            dash: nil
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame + ray * 2, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + ray * 2 + 5), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 6), value: 1, easing: .linear),
                ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .linear),
              ]),
              startFrame: lineStartFrame,
              enabledParamId: "motionLines"
            ),
          ]
        ))
        members.append(rayId)
      }

      // The bubble group: spring pop at the line start, scaled by
      // the popScale param, then a gentle exit.
      builder.add(ExtraStyleNode(
        id: "bubble-\(lineIndex)", kind: .group,
        children: members,
        position: bubbleCenter, anchor: .zero,
        rotationDeg: rotation,
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.55, to: 1, stiffness: 170, damping: 11, initialVelocity: 0),
            startFrame: lineStartFrame,
            paramScale: "popScale"
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
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 23: Message Universe (playful)

final class MessageUniverseExtraStyle: ExtraStyleDefinition {
  let id = "message-universe"
  let version = 1
  let name = "Message Universe"
  let tagline = "Chat bubbles, typing dots, and reactions."
  let category = "playful"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "incomingColor", label: "Their bubble", default: "#2E2E33", affects: "appearance"),
      extraStyleColorParam(id: "outgoingColor", label: "Your bubble", default: "#0A84FF", affects: "appearance"),
      extraStyleToggleParam(id: "typing", label: "Typing dots", default: true, affects: "motion"),
      extraStyleSliderParam(
        id: "reactionScale", label: "Reactions", min: 0, max: 1, step: 0.05,
        default: 0.8, affects: "motion"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "classic-chat", "label": "Classic chat", "values": ["incomingColor": "#2E2E33", "outgoingColor": "#0A84FF"]],
      ["id": "lime-chat", "label": "Lime chat", "values": ["incomingColor": "#2E2E33", "outgoingColor": "#8FBF2E", "reactionScale": 1]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }
  var rebuildParamIds: [String] { [] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let showTyping = extraStyleParamBool(input.params, "typing", true)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // Speaker alternation via LINE PARITY (§7.2): even lines are
      // the other speaker (left), odd lines are you (right). No
      // diarization exists — this is the documented stand-in.
      let isOutgoing = lineIndex % 2 == 1
      let bubbleColorParam = isOutgoing ? "outgoingColor" : "incomingColor"
      let bubbleColor = extraStyleColor(extraStyleParamString(
        input.params, bubbleColorParam, isOutgoing ? "#0A84FF" : "#2E2E33"
      ))
      let textColor = ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1)
      let sizePoints = canvas.width * 0.048
      let lineHeight = sizePoints * 1.4
      let (placements, totalWidth, totalHeight) = playfulWordPlacements(
        line: line, fps: fps, lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        font: ExtraStyleFonts.avenirBold, sizePoints: sizePoints,
        maxWidth: canvas.width * 0.62, lineHeight: lineHeight
      )
      guard !placements.isEmpty else { continue }
      let bubbleWidth = min(canvas.width * 0.78, max(totalWidth + 56, canvas.width * 0.3))
      let bubbleHeight = totalHeight + 44
      let margin = canvas.width * 0.06
      let bubbleCenterX = isOutgoing
        ? canvas.width - margin - bubbleWidth / 2
        : margin + bubbleWidth / 2
      let bubbleCenterY = canvas.height * (isOutgoing ? 0.62 : 0.52)

      // Typing window, then the reveal. When typing is off the
      // message appears at the line start. Words never appear
      // before the reveal, even when sung earlier.
      let typingFrames = showTyping ? min(21, max(0, (lineEndFrame - lineStartFrame) / 3)) : 0
      let revealFrame = min(lineEndFrame - 3, lineStartFrame + typingFrames)

      var members: [String] = []

      // Bubble body: rounded-rect path shape, sized to the words.
      let bodyId = "msg-body-\(lineIndex)"
      builder.addChild(extraStyleShapeNode(
        id: bodyId,
        shape: .path(extraStylePlayfulRoundedRectPath(
          width: bubbleWidth, height: bubbleHeight, radius: 24
        )),
        fill: bubbleColor,
        position: .zero, zIndex: 0,
        visibleRange: revealFrame...lineEndFrame,
        fillColorParamId: bubbleColorParam
      ))
      members.append(bodyId)

      // The message words, typing in one by one: each word pops
      // in at its sung start (or the reveal, whichever is later),
      // so the bubble reads as typed live in time with the song.
      // The bubble is the contrast the words sit on.
      for placement in placements {
        let wordStart = max(placement.startFrame, revealFrame)
        guard placement.endFrame > wordStart else { continue }
        let wordId = "msg-word-\(lineIndex)-\(placement.index)"
        builder.addChild(extraStyleTextNode(
          id: wordId,
          text: placement.text, font: ExtraStyleFonts.avenirBold, sizePoints: sizePoints,
          color: textColor,
          position: CGPoint(x: placement.x, y: placement.y - 1),
          zIndex: 1,
          visibleRange: wordStart...placement.endFrame,
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: wordStart, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(placement.endFrame, wordStart + 4), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: max(wordStart, placement.endFrame - 9), value: 1, easing: .linear),
                ExtraStyleKeyframe(frame: placement.endFrame, value: 0, easing: .easeInCubic),
              ]),
              startFrame: wordStart
            ),
            ExtraStyleTrack(
              property: .scale,
              kind: .spring(from: 0.6, to: 1, stiffness: 200, damping: 12, initialVelocity: 0),
              startFrame: wordStart
            ),
          ]
        ))
        members.append(wordId)
      }

      // Typing dots: three circles on a staggered loop, visible
      // only until the reveal. Each dot's loop keys are offset
      // within the 30-frame period so they pulse in sequence.
      if showTyping, revealFrame > lineStartFrame {
        for dot in 0..<3 {
          let dotId = "msg-dot-\(lineIndex)-\(dot)"
          let offset = dot * 10
          builder.addChild(extraStyleShapeNode(
            id: dotId,
            shape: extraStyleEllipseShape(width: 14, height: 14),
            fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.75),
            position: CGPoint(x: CGFloat(dot - 1) * 26, y: 0),
            zIndex: 1,
            visibleRange: lineStartFrame...revealFrame,
            tracks: [
              ExtraStyleTrack(
                property: .opacity,
                kind: .loop(periodFrames: 30, periodParamId: nil, keys: [
                  ExtraStyleKeyframe(frame: offset, value: 0.3, easing: .easeInOutSine),
                  ExtraStyleKeyframe(frame: offset + 5, value: 1, easing: .easeInOutSine),
                  ExtraStyleKeyframe(frame: offset + 10, value: 0.3, easing: .easeInOutSine),
                  ExtraStyleKeyframe(frame: 30, value: 0.3, easing: .linear),
                ]),
                startFrame: lineStartFrame
              ),
            ]
          ))
          members.append(dotId)
        }
      }

      // Reaction: the line's stored emoji at the bubble corner
      // (nil-safe — no emoji, no node), popping in after reveal.
      if let reaction = extraStyleEmojiNode(
        id: "msg-emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: isOutgoing ? bubbleWidth / 2 - 8 : -bubbleWidth / 2 + 8,
          y: -bubbleHeight / 2 - 14
        ),
        sizePoints: canvas.width * 0.07, zIndex: 3,
        visibleRange: revealFrame...lineEndFrame
      ) {
        // extraStyleEmojiNode's spring starts at the visible
        // range's lower bound, which is the reveal frame here.
        builder.addChild(reaction)
        members.append("msg-emoji-\(lineIndex)")
      } else {
        // No stored emoji: the tone's first reaction emoji stands
        // in, so the bubble still gets a reaction.
        let fallback = extraStyleReactionEmojis(for: line.tone)[0]
        let fallbackId = "msg-emoji-\(lineIndex)"
        builder.addChild(ExtraStyleNode(
          id: fallbackId, kind: .emoji,
          position: CGPoint(
            x: isOutgoing ? bubbleWidth / 2 - 8 : -bubbleWidth / 2 + 8,
            y: -bubbleHeight / 2 - 14
          ),
          anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 3,
          visibleRange: revealFrame...lineEndFrame,
          text: ExtraStyleTextContent(
            text: fallback,
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
              startFrame: revealFrame + 4,
              paramScale: "reactionScale"
            ),
          ]
        ))
        members.append(fallbackId)
      }

      // The bubble group: slides in from its side at the reveal.
      let slideFrom: Double = isOutgoing ? 90 : -90
      builder.add(ExtraStyleNode(
        id: "msg-\(lineIndex)", kind: .group,
        children: members,
        position: CGPoint(x: bubbleCenterX, y: bubbleCenterY), anchor: .zero,
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: revealFrame, value: slideFrom, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(lineEndFrame, revealFrame + 9), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: revealFrame
          ),
          // Group opacity stays 1 from the line start: the typing
          // dots must be visible BEFORE the reveal, and the bubble
          // body / text gate themselves with visibleRange instead.
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 9), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 24: Sticker World (playful)

final class StickerWorldExtraStyle: ExtraStyleDefinition {
  let id = "sticker-world"
  let version = 1
  let name = "Sticker World"
  let tagline = "Lyrics as peel-and-stick stickers that pop in word by word."
  let category = "playful"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "theme", label: "Sticker set",
        options: [("party", "Party"), ("love", "Love"), ("retro", "Retro")],
        default: "party", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "stickerSize", label: "Sticker size", min: 0.6, max: 1.6, step: 0.05,
        default: 1, affects: "layout"
      ),
      extraStyleToggleParam(id: "bounce", label: "Bounce in", default: true, affects: "motion"),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#FFD93D", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "big-party", "label": "Big party", "values": ["theme": "party", "stickerSize": 1.4]],
      ["id": "soft-love", "label": "Soft love", "values": ["theme": "love", "stickerSize": 0.9, "bounce": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }
  var rebuildParamIds: [String] { ["theme"] }

  /// One themed sticker shape (procedural — no sticker art in the
  /// asset registry). `kind` cycles star / heart / bolt / circle /
  /// rounded-rect; the palette comes from the theme.
  private func stickerShape(kind: Int, size: CGFloat) -> ExtraStyleShapeKind {
    switch kind % 5 {
    case 0:
      return extraStyleStarShape(outerRadius: size / 2, innerRadius: size / 4, spikes: 5)
    case 1:
      return .path(extraStylePlayfulHeartPath(size: size))
    case 2:
      return .path(extraStylePlayfulBoltPath(size: size))
    case 3:
      return extraStyleEllipseShape(width: size, height: size)
    default:
      return .path(extraStylePlayfulRoundedRectPath(width: size, height: size * 0.8, radius: size * 0.2))
    }
  }

  private func stickerPalette(theme: String, accent: ExtraStyleRGBA) -> [ExtraStyleRGBA] {
    switch theme {
    case "love":
      return [
        ExtraStyleRGBA(r: 1, g: 0.42, b: 0.62, a: 1),
        ExtraStyleRGBA(r: 1, g: 0.3, b: 0.3, a: 1),
        ExtraStyleRGBA(r: 1, g: 0.85, b: 0.24, a: 1),
        ExtraStyleRGBA(r: 0.85, g: 0.5, b: 0.95, a: 1),
      ]
    case "retro":
      return [
        ExtraStyleRGBA(r: 0.95, g: 0.55, b: 0.25, a: 1),
        ExtraStyleRGBA(r: 0.25, g: 0.65, b: 0.6, a: 1),
        ExtraStyleRGBA(r: 0.95, g: 0.85, b: 0.24, a: 1),
        ExtraStyleRGBA(r: 0.85, g: 0.45, b: 0.35, a: 1),
      ]
    default: // party
      return [
        accent,
        ExtraStyleRGBA(r: 0.4, g: 0.8, b: 1, a: 1),
        ExtraStyleRGBA(r: 0.85, g: 0.5, b: 0.95, a: 1),
        ExtraStyleRGBA(r: 0.55, g: 0.95, b: 0.45, a: 1),
      ]
    }
  }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let theme = extraStyleParamString(input.params, "theme", "party")
    let stickerSizeScale = extraStyleParamDouble(input.params, "stickerSize", 1)
    let bounce = extraStyleParamBool(input.params, "bounce", true)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#FFD93D"))
    let palette = stickerPalette(theme: theme, accent: accent)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 11))
      let centerY = canvas.height * 0.5
      let sizePoints = canvas.width * 0.06 * CGFloat(stickerSizeScale)
      let lineHeight = sizePoints * 1.35
      let (placements, totalWidth, totalHeight) = playfulWordPlacements(
        line: line, fps: fps, lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        font: ExtraStyleFonts.black, sizePoints: sizePoints,
        maxWidth: canvas.width * 0.72, lineHeight: lineHeight
      )
      guard !placements.isEmpty else { continue }
      let stickerBase = canvas.width * 0.13 * CGFloat(stickerSizeScale)

      // Each word IS a sticker: bold ink text with a white
      // peel outline, a seeded tilt, springing in at its sung
      // start. Emphasis words get a theme-coloured star stuck
      // behind them.
      for placement in placements {
        guard placement.endFrame > placement.startFrame else { continue }
        let wordPosition = CGPoint(x: canvas.width / 2 + placement.x, y: centerY + placement.y)
        let tilt = CGFloat(random.nextRange(min: -6, max: 6))
        if line.emphasisWordIndices.contains(placement.index) {
          let starSize = sizePoints * 1.1
          builder.add(extraStyleShapeNode(
            id: "sticker-star-\(lineIndex)-\(placement.index)",
            shape: extraStyleStarShape(outerRadius: starSize / 2, innerRadius: starSize / 4, spikes: 5),
            fill: palette[placement.index % palette.count],
            stroke: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1), strokeWidth: 4,
            position: wordPosition,
            zIndex: 9,
            visibleRange: placement.startFrame...placement.endFrame,
            tracks: [
              ExtraStyleTrack(
                property: .scale,
                kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 10, initialVelocity: 0),
                startFrame: placement.startFrame
              ),
            ]
          ))
        }
        var wordTracks: [ExtraStyleTrack] = [
          extraStyleEnterExitOpacityTrack(start: placement.startFrame, end: placement.endFrame),
        ]
        if bounce {
          wordTracks.append(ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 10, initialVelocity: 0),
            startFrame: placement.startFrame
          ))
        }
        builder.add(ExtraStyleNode(
          id: "sticker-word-\(lineIndex)-\(placement.index)", kind: .text,
          position: wordPosition,
          anchor: CGPoint(x: 0.5, y: 0.5),
          rotationDeg: tilt,
          zIndex: 10,
          visibleRange: placement.startFrame...placement.endFrame,
          text: ExtraStyleTextContent(
            text: placement.text,
            fontPostScriptName: ExtraStyleFonts.black,
            sizePoints: sizePoints,
            color: ExtraStyleRGBA(r: 0.1, g: 0.1, b: 0.12, a: 1),
            colorParamId: nil,
            strokeColor: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
            strokeWidthPoints: 5,
            alignment: .center,
            maxWidthPoints: nil
          ),
          tracks: wordTracks
        ))
      }

      // Two small stickers tucked at the ends of the lyric line —
      // the only free-floating stickers left, and they stay
      // attached to the line. Each has a dark offset shadow layer
      // (the sticker "peel" depth) and a bold white stroke, a
      // spring entrance, and a gentle float.
      let accentSpots: [(x: CGFloat, y: CGFloat, kind: Int)] = [
        (
          x: max(canvas.width * 0.09, canvas.width / 2 - totalWidth / 2 - stickerBase * 0.7),
          y: centerY - totalHeight / 2 - stickerBase * 0.35,
          kind: lineIndex % 5
        ),
        (
          x: min(canvas.width * 0.91, canvas.width / 2 + totalWidth / 2 + stickerBase * 0.7),
          y: centerY + totalHeight / 2 + stickerBase * 0.35,
          kind: (lineIndex + 2) % 5
        ),
      ]
      for (accentIndex, spot) in accentSpots.enumerated() {
        let stickerSize = stickerBase * 0.8 * CGFloat(random.nextRange(min: 0.85, max: 1.15))
        let fill = palette[(accentIndex + lineIndex) % palette.count]
        let startFrame = lineStartFrame + accentIndex * 4
        var accentTracks: [ExtraStyleTrack] = [
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 150, periodParamId: nil, keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 75, value: -10, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
        ]
        if bounce {
          accentTracks.append(ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.2, to: 1, stiffness: 200, damping: 10, initialVelocity: 0),
            startFrame: startFrame
          ))
        }
        // Shadow layer (offset, dark, no stroke).
        builder.add(extraStyleShapeNode(
          id: "sticker-shadow-\(lineIndex)-\(accentIndex)",
          shape: stickerShape(kind: spot.kind, size: stickerSize),
          fill: ExtraStyleRGBA(r: 0.1, g: 0.1, b: 0.1, a: 0.25),
          position: CGPoint(x: spot.x + 6, y: spot.y + 8),
          zIndex: 8,
          visibleRange: lineStartFrame...lineEndFrame,
          tracks: accentTracks
        ))
        // Face layer (theme colour, bold white stroke).
        builder.add(extraStyleShapeNode(
          id: "sticker-accent-\(lineIndex)-\(accentIndex)",
          shape: stickerShape(kind: spot.kind, size: stickerSize),
          fill: fill,
          stroke: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1), strokeWidth: 6,
          position: CGPoint(x: spot.x, y: spot.y),
          zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          tracks: accentTracks
        ))
      }

      // The line's stored emoji rides as one more sticker, above
      // the line — nil-safe, never gated on a template flag.
      if let hero = extraStyleEmojiNode(
        id: "sticker-emoji-\(lineIndex)", line: line,
        position: CGPoint(x: canvas.width / 2, y: centerY - totalHeight / 2 - canvas.width * 0.09),
        sizePoints: canvas.width * 0.1, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(hero)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (playful rest)

extension ExtraStylesPhase3 {
  static func registerPlayfulRest(into registry: ExtraStyleRegistry) {
    registry.register(CartoonUniverseExtraStyle())
    registry.register(MessageUniverseExtraStyle())
    registry.register(StickerWorldExtraStyle())
  }
}
