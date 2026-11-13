import CoreGraphics
import CoreText
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3 builder helpers
//
// Shared by all 40 style definitions (docs/EXTRA-STYLES-2.0.md
// §17). These are the ONLY way styles build scenes: every helper
// is deterministic (seeded randomness only, no wall-clock) and
// frame-addressable (all times are integer frames on the 30fps
// grid). A style that needs something no helper provides builds
// it from the engine primitives directly — and if two styles need
// the same thing, the helper belongs here, not in both.
//
// Track semantics (the evaluator's contract — ExtraStylesCompositor.swift
// §7a, resolveNode): positionX/Y tracks are OFFSETS added to the
// node's base position; scale tracks are ABSOLUTE factors (× base
// scale); opacity tracks are ABSOLUTE (× base, × parents);
// keyframe values are ABSOLUTE scene frames, except loop tracks,
// whose keys are written against the nominal period. Physics is
// baked at build time (fixed-step simulation → keyframes), never
// integrated at render time — the evaluator has no physics track
// kind, and the plan's §5.2 physics is exactly this: deterministic
// integration from a fixed initial state, ahead of time.

// MARK: - Fonts (PostScript names known to exist on iOS)

enum ExtraStyleFonts {
  static let bold = "Helvetica-Bold"
  static let regular = "Helvetica"
  static let black = "HelveticaNeue-Bold"
  static let avenirHeavy = "AvenirNext-Heavy"
  static let avenirBold = "AvenirNext-Bold"
  static let avenir = "AvenirNext-Regular"
  static let mono = "Courier-Bold"
  static let monoRegular = "Courier"
  static let serif = "Georgia-Bold"
  static let serifRegular = "Georgia"
  static let chalk = "ChalkboardSE-Bold"
  static let marker = "MarkerFelt-Wide"
  static let didot = "Didot-Bold"
  static let times = "TimesNewRomanPS-BoldMT"
  static let emoji = "AppleColorEmoji"
}

// MARK: - Tone colours + reaction emoji (docs §7 — stored tone, never computed)

/// The stored tone's colour. Deterministic: same tone → same colour.
/// No tone → the acid-lime identity colour.
func extraStyleToneColor(_ tone: String?) -> ExtraStyleRGBA {
  switch tone {
  case "love":
    return ExtraStyleRGBA(r: 1, g: 0.42, b: 0.62, a: 1)
  case "joy":
    return ExtraStyleRGBA(r: 1, g: 0.85, b: 0.24, a: 1)
  case "hype":
    return ExtraStyleRGBA(r: 1, g: 0.48, b: 0.09, a: 1)
  case "sad":
    return ExtraStyleRGBA(r: 0.42, g: 0.66, b: 1, a: 1)
  case "anger":
    return ExtraStyleRGBA(r: 1, g: 0.3, b: 0.3, a: 1)
  default:
    return ExtraStyleRGBA(r: 0.788, g: 0.953, b: 0.42, a: 1)
  }
}

/// Reaction emoji for a line's stored tone — the extras around the
/// line's own stored emoji (which is always the hero, never a
/// reaction). Deterministic; no tone → sparkles.
func extraStyleReactionEmojis(for tone: String?) -> [String] {
  switch tone {
  case "love":
    return ["❤️", "💕", "😍"]
  case "joy":
    return ["⭐", "✨", "😊"]
  case "hype":
    return ["🔥", "⚡", "🎉"]
  case "sad":
    return ["💧", "🌧️", "💙"]
  case "anger":
    return ["💥", "😤", "🔥"]
  default:
    return ["✨", "⭐", "💫"]
  }
}

// MARK: - Parameter schema builders (docs §8.1)
//
// Parameters are [[String: Any]] dictionaries in the definition.
// These builders keep the schema spelling in one place so a typo
// cannot silently drop a control (an unknown `kind` makes the
// Swift resolver reject the value).

func extraStyleSliderParam(
  id: String, label: String, min: Double, max: Double, step: Double,
  default defaultValue: Double, affects: String, unit: String? = nil
) -> [String: Any] {
  var param: [String: Any] = [
    "id": id, "label": label, "kind": "slider",
    "min": min, "max": max, "step": step,
    "default": defaultValue, "affects": affects,
  ]
  if let unit { param["unit"] = unit }
  return param
}

func extraStyleNumberParam(
  id: String, label: String, min: Double, max: Double, step: Double,
  default defaultValue: Double, affects: String
) -> [String: Any] {
  [
    "id": id, "label": label, "kind": "number",
    "min": min, "max": max, "step": step,
    "default": defaultValue, "affects": affects,
  ]
}

func extraStyleToggleParam(
  id: String, label: String, default defaultValue: Bool, affects: String
) -> [String: Any] {
  [
    "id": id, "label": label, "kind": "toggle",
    "default": defaultValue, "affects": affects,
  ]
}

func extraStyleColorParam(
  id: String, label: String, default defaultValue: String, affects: String
) -> [String: Any] {
  [
    "id": id, "label": label, "kind": "color",
    "default": defaultValue, "affects": affects,
  ]
}

func extraStyleSegmentedParam(
  id: String, label: String, options: [(value: String, label: String)],
  default defaultValue: String, affects: String
) -> [String: Any] {
  [
    "id": id, "label": label, "kind": "segmented",
    "options": options.map { ["value": $0.value, "label": $0.label] },
    "default": defaultValue, "affects": affects,
  ]
}

func extraStyleSelectParam(
  id: String, label: String, options: [(value: String, label: String)],
  default defaultValue: String, affects: String
) -> [String: Any] {
  [
    "id": id, "label": label, "kind": "select",
    "options": options.map { ["value": $0.value, "label": $0.label] },
    "default": defaultValue, "affects": affects,
  ]
}

// MARK: - Scene assembly

/// Accumulates nodes into a scene. `add` puts a node at the top
/// level (a child of root); `addChild` registers a node that
/// belongs to a group (its id must appear in that group's
/// `children` — it is NOT also a root child, so it is evaluated
/// exactly once). Every node id must be unique across the scene.
struct ExtraStyleSceneBuilder {
  var nodes: [String: ExtraStyleNode] = [:]
  var topLevel: [String] = []

  mutating func add(_ node: ExtraStyleNode) {
    nodes[node.id] = node
    topLevel.append(node.id)
  }

  mutating func addChild(_ node: ExtraStyleNode) {
    nodes[node.id] = node
  }

  func build(canvas: CGSize, durationFrames: Int) -> ExtraStyleScene {
    var all = nodes
    let root = ExtraStyleNode(
      id: "root", kind: .group, children: topLevel,
      position: .zero, anchor: .zero
    )
    all["root"] = root
    return ExtraStyleScene(rootId: "root", nodes: all, canvas: canvas, durationFrames: durationFrames)
  }
}

// MARK: - Line timing + standard tracks

/// Line timing in integer frames, clamped to the scene. Nil when
/// the line has no frames inside the scene (entirely outside the
/// composition — the style never sees it).
func extraStyleLineFrames(
  _ line: ExtraStyleInputLine, fps: Double, durationFrames: Int
) -> (start: Int, end: Int)? {
  let start = max(0, Int((line.startSeconds * fps).rounded()))
  let end = min(durationFrames, Int((line.endSeconds * fps).rounded()))
  guard end > start else { return nil }
  return (start, end)
}

/// Standard enter/exit opacity: fade in over `enterFrames`, hold,
/// fade out over `exitFrames`. Keyframes are absolute scene frames.
func extraStyleEnterExitOpacityTrack(
  start: Int, end: Int, enterFrames: Int = 9, exitFrames: Int = 9
) -> ExtraStyleTrack {
  ExtraStyleTrack(
    property: .opacity,
    kind: .keyframes(keys: [
      ExtraStyleKeyframe(frame: start, value: 0, easing: .linear),
      ExtraStyleKeyframe(frame: min(end, start + max(1, enterFrames)), value: 1, easing: .easeOutCubic),
      ExtraStyleKeyframe(frame: max(start, end - max(1, exitFrames)), value: 1, easing: .linear),
      ExtraStyleKeyframe(frame: end, value: 0, easing: .easeInCubic),
    ]),
    startFrame: start
  )
}

/// Spring scale-in (from → 1) starting at `start`. The track is
/// absolute scale (× base scale), so it composes with the node's
/// own scale.
func extraStyleSpringInTrack(
  start: Int, from: Double = 0.6, stiffness: Double = 140, damping: Double = 11
) -> ExtraStyleTrack {
  ExtraStyleTrack(
    property: .scale,
    kind: .spring(from: from, to: 1, stiffness: stiffness, damping: damping, initialVelocity: 0),
    startFrame: start
  )
}

/// Seeded flicker opacity keyframes (deterministic noise): one key
/// every `stepFrames` frames, values in [base − amplitude,
/// base + amplitude], clamped to [0, 1]. The seed makes the
/// flicker identical in preview and export.
func extraStyleFlickerTrack(
  start: Int, end: Int, base: Double, amplitude: Double, seed: UInt64, stepFrames: Int = 3
) -> ExtraStyleTrack {
  var random = ExtraStyleSeededRandom(seed: seed)
  var keys: [ExtraStyleKeyframe] = []
  var frame = start
  while frame <= end {
    let value = max(0, min(1, base + (random.nextDouble() * 2 - 1) * amplitude))
    keys.append(ExtraStyleKeyframe(frame: frame, value: value, easing: .linear))
    frame += max(1, stepFrames)
  }
  if keys.isEmpty {
    keys.append(ExtraStyleKeyframe(frame: start, value: base, easing: .linear))
  }
  return ExtraStyleTrack(property: .opacity, kind: .keyframes(keys: keys), startFrame: start)
}

// MARK: - Text measurement + text nodes

/// Width of one string at a font/size (CTLine typographic width).
func extraStyleTextWidth(_ text: String, fontPostScriptName: String, sizePoints: CGFloat) -> CGFloat {
  guard let font = CTFontCreateWithName(fontPostScriptName as CFString, sizePoints, nil) else { return 0 }
  let attributed = NSAttributedString(
    string: text, attributes: [NSAttributedString.Key.font: font]
  )
  let line = CTLineCreateWithAttributedString(attributed)
  return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// A text node. Position is the node's anchor point (default
/// centre anchor); the layout's width/height come from the
/// prepared text layout, so the anchor centres the wrapped block.
func extraStyleTextNode(
  id: String, text: String, font: String, sizePoints: CGFloat,
  color: ExtraStyleRGBA, position: CGPoint, zIndex: Int,
  visibleRange: ClosedRange<Int>?,
  maxWidthPoints: CGFloat? = nil,
  strokeColor: ExtraStyleRGBA? = nil, strokeWidthPoints: CGFloat = 0,
  alignment: NSTextAlignment = .center,
  colorParamId: String? = nil,
  tracks: [ExtraStyleTrack] = []
) -> ExtraStyleNode {
  ExtraStyleNode(
    id: id, kind: .text,
    position: position, anchor: CGPoint(x: 0.5, y: 0.5),
    zIndex: zIndex,
    visibleRange: visibleRange,
    text: ExtraStyleTextContent(
      text: text,
      fontPostScriptName: font,
      sizePoints: sizePoints,
      color: color,
      colorParamId: colorParamId,
      strokeColor: strokeColor,
      strokeWidthPoints: strokeWidthPoints,
      alignment: alignment,
      maxWidthPoints: maxWidthPoints
    ),
    tracks: tracks
  )
}

/// THE EMOJI NODE (docs §Emoji Story acceptance, Jaizon
/// 2026-11-13 ~01:26 MST): the line's stored emoji, rendered as
/// an emoji glyph with a spring pop — whenever the payload line
/// HAS one. Returns nil ONLY when the line has no stored emoji.
/// No gate, no template check: the payload is the only source.
/// Every style that shows the line's emoji uses this helper, so
/// the unconditional path is one function, not forty copies.
func extraStyleEmojiNode(
  id: String, line: ExtraStyleInputLine,
  position: CGPoint, sizePoints: CGFloat, zIndex: Int,
  visibleRange: ClosedRange<Int>,
  popStiffness: Double = 180, popDamping: Double = 10
) -> ExtraStyleNode? {
  guard let emoji = line.emoji, !emoji.isEmpty else { return nil }
  return ExtraStyleNode(
    id: id, kind: .emoji,
    position: position, anchor: CGPoint(x: 0.5, y: 0.5),
    zIndex: zIndex,
    visibleRange: visibleRange,
    text: ExtraStyleTextContent(
      text: emoji,
      fontPostScriptName: ExtraStyleFonts.emoji,
      sizePoints: sizePoints,
      color: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
      strokeColor: nil,
      strokeWidthPoints: 0,
      alignment: .center,
      maxWidthPoints: nil
    ),
    tracks: [
      extraStyleSpringInTrack(
        start: visibleRange.lowerBound, from: 0.2,
        stiffness: popStiffness, damping: popDamping
      ),
    ]
  )
}

// MARK: - Word / character nodes

/// Per-word nodes laid out along one centered line: each word
/// pops in at its sung start (or, without timings, staggered by
/// `staggerFrames`). The caller supplies the tracks per word via
/// `trackBuilder` (index, wordStartFrame, wordEndFrame); the
/// default is a short opacity enter at the word's start.
/// Words are positioned by measured width, so the line stays
/// centred whatever the words are.
func extraStyleWordNodes(
  line: ExtraStyleInputLine, lineIndex: Int, fps: Double,
  lineStartFrame: Int, lineEndFrame: Int,
  y: CGFloat, sizePoints: CGFloat, color: ExtraStyleRGBA, font: String,
  zIndex: Int, canvasWidth: CGFloat,
  staggerFrames: Int = 3,
  colorParamId: String? = nil,
  trackBuilder: ((Int, Int, Int) -> [ExtraStyleTrack])? = nil
) -> [ExtraStyleNode] {
  let words = line.words
  guard !words.isEmpty else { return [] }
  let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
  let widths = words.map { extraStyleTextWidth($0.text, fontPostScriptName: font, sizePoints: sizePoints) }
  let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, words.count - 1))
  var cursorX = (canvasWidth - totalWidth) / 2
  var nodes: [ExtraStyleNode] = []
  for (index, word) in words.enumerated() {
    let wordStartFrame = max(
      lineStartFrame, Int((word.startSeconds * fps).rounded()))
    let wordEndFrame = min(
      lineEndFrame, Int((word.endSeconds * fps).rounded()))
    let startFrame = wordEndFrame > wordStartFrame
      ? wordStartFrame : min(lineEndFrame, lineStartFrame + index * staggerFrames)
    let endFrame = wordEndFrame > wordStartFrame
      ? wordEndFrame : lineEndFrame
    guard endFrame > startFrame else {
      cursorX += widths[index] + spaceWidth
      continue
    }
    let tracks: [ExtraStyleTrack] = trackBuilder?(index, startFrame, endFrame) ?? [
      ExtraStyleTrack(
        property: .opacity,
        kind: .keyframes(keys: [
          ExtraStyleKeyframe(frame: startFrame, value: 0, easing: .linear),
          ExtraStyleKeyframe(frame: min(endFrame, startFrame + 4), value: 1, easing: .easeOutCubic),
          ExtraStyleKeyframe(frame: endFrame, value: 0, easing: .linear),
        ]),
        startFrame: startFrame
      ),
    ]
    nodes.append(extraStyleTextNode(
      id: "word-\(lineIndex)-\(index)",
      text: word.text, font: font, sizePoints: sizePoints, color: color,
      position: CGPoint(x: cursorX + widths[index] / 2, y: y),
      zIndex: zIndex,
      visibleRange: startFrame...endFrame,
      colorParamId: colorParamId,
      tracks: tracks
    ))
    cursorX += widths[index] + spaceWidth
  }
  return nodes
}

/// Per-character nodes laid out along one centered line. Spaces
/// take layout width but get no node. The caller supplies the
/// tracks per character via `trackBuilder` (index, charStartFrame,
/// lineEndFrame); the default is a small rise + opacity enter at
/// the character's staggered start (firstCharStartFrame +
/// index × charDelayFrames).
func extraStyleCharNodes(
  text: String, lineIndex: Int, lineStartFrame: Int, lineEndFrame: Int,
  y: CGFloat, sizePoints: CGFloat, color: ExtraStyleRGBA, font: String,
  zIndex: Int, canvasWidth: CGFloat,
  firstCharStartFrame: Int? = nil, charDelayFrames: Int = 2,
  colorParamId: String? = nil,
  trackBuilder: ((Int, Int, Int) -> [ExtraStyleTrack])? = nil
) -> [ExtraStyleNode] {
  let chars = Array(text)
  guard !chars.isEmpty else { return [] }
  let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
  let widths = chars.map { $0 == " " ? spaceWidth : extraStyleTextWidth(String($0), fontPostScriptName: font, sizePoints: sizePoints) }
  let totalWidth = widths.reduce(0, +)
  var cursorX = (canvasWidth - totalWidth) / 2
  let firstStart = firstCharStartFrame ?? lineStartFrame
  var nodes: [ExtraStyleNode] = []
  for (index, char) in chars.enumerated() {
    let charWidth = widths[index]
    defer { cursorX += charWidth }
    guard char != " " else { continue }
    let startFrame = min(lineEndFrame, firstStart + index * charDelayFrames)
    guard lineEndFrame > startFrame else { continue }
    let tracks: [ExtraStyleTrack] = trackBuilder?(index, startFrame, lineEndFrame) ?? [
      ExtraStyleTrack(
        property: .opacity,
        kind: .keyframes(keys: [
          ExtraStyleKeyframe(frame: startFrame, value: 0, easing: .linear),
          ExtraStyleKeyframe(frame: min(lineEndFrame, startFrame + 5), value: 1, easing: .easeOutCubic),
        ]),
        startFrame: startFrame
      ),
      ExtraStyleTrack(
        property: .positionY,
        kind: .keyframes(keys: [
          ExtraStyleKeyframe(frame: startFrame, value: -14, easing: .easeOutCubic),
          ExtraStyleKeyframe(frame: min(lineEndFrame, startFrame + 8), value: 0, easing: .easeOutCubic),
        ]),
        startFrame: startFrame
      ),
    ]
    nodes.append(extraStyleTextNode(
      id: "char-\(lineIndex)-\(index)",
      text: String(char), font: font, sizePoints: sizePoints, color: color,
      position: CGPoint(x: cursorX + charWidth / 2, y: y),
      zIndex: zIndex,
      visibleRange: startFrame...lineEndFrame,
      colorParamId: colorParamId,
      tracks: tracks
    ))
  }
  return nodes
}

// MARK: - Physics (baked at build time, docs §5.2)
//
// Fixed-step deterministic integration from a fixed initial
// state: a node falls from `startYOffset` (negative — above its
// rest position) under `gravity` points/frame², bounces on the
// floor (offset 0) with `restitution`, and settles. The result is
// positionY-offset keyframes (absolute scene frames, linear
// easing) — the evaluator only interpolates, it never integrates.
// Same inputs → same keyframes, in preview and export.

/// Gravity fall → positionY-offset keyframes. The node rests at
/// offset 0; the first key is `startYOffset` at `startFrame`.
/// Keys are emitted every 2 frames until the fall settles (or
/// `maxFrames` passes); the final key is always (frame, 0).
func extraStyleFallKeyframes(
  startFrame: Int, startYOffset: Double, gravity: Double,
  restitution: Double, maxFrames: Int = 180
) -> [ExtraStyleKeyframe] {
  var keys: [ExtraStyleKeyframe] = [
    ExtraStyleKeyframe(frame: startFrame, value: startYOffset, easing: .linear),
  ]
  var yOff = startYOffset
  var velocity = 0.0
  var frame = startFrame
  var settled = false
  while frame - startFrame < maxFrames, !settled {
    velocity += gravity
    yOff += velocity
    if yOff >= 0 {
      yOff = 0
      velocity = -velocity * max(0, min(1, restitution))
      if abs(velocity) < 20 {
        velocity = 0
        settled = true
      }
    }
    frame += 1
    if (frame - startFrame) % 2 == 0 || settled {
      keys.append(ExtraStyleKeyframe(frame: frame, value: yOff, easing: .linear))
    }
    if settled { break }
  }
  if keys.last?.value != 0 {
    keys.append(ExtraStyleKeyframe(frame: frame, value: 0, easing: .linear))
  }
  return keys
}

// MARK: - Counters (docs §17 #15)
//
// Text content is baked at build time, so a counter is a set of
// text nodes — one per step — each visible for its window. The
// steps are evenly spread over [startFrame, endFrame].

/// Counter nodes from `from` to `to` in `steps` steps.
func extraStyleCounterNodes(
  idPrefix: String, from: Double, to: Double, steps: Int,
  startFrame: Int, endFrame: Int,
  position: CGPoint, sizePoints: CGFloat, color: ExtraStyleRGBA,
  font: String, zIndex: Int,
  format: (Double) -> String
) -> [ExtraStyleNode] {
  guard steps > 0, endFrame > startFrame else { return [] }
  let span = endFrame - startFrame
  var nodes: [ExtraStyleNode] = []
  for step in 0...steps {
    let value = from + (to - from) * Double(step) / Double(steps)
    let windowStart = startFrame + span * step / (steps + 1)
    let windowEnd = step == steps ? endFrame : startFrame + span * (step + 1) / (steps + 1)
    guard windowEnd > windowStart else { continue }
    nodes.append(extraStyleTextNode(
      id: "\(idPrefix)-\(step)",
      text: format(value), font: font, sizePoints: sizePoints, color: color,
      position: position, zIndex: zIndex,
      visibleRange: windowStart...windowEnd
    ))
  }
  return nodes
}

// MARK: - Face boxes (docs §10.2)
//
// The mask index carries face boxes per 2fps sample. A tracking
// box follows them as positionX/Y keyframe tracks (nearest-sample
// hold, sampled every 15 frames): the box node sits at position
// (0, 0) and the tracks carry ABSOLUTE canvas points (position
// tracks are offsets added to the base position). No boxes at all
// → no tracks (the node stays wherever its base position puts it).

/// Position tracks following the face-box centre across
/// [startFrame, endFrame]. Empty when the index has no boxes.
func extraStyleFaceBoxTracks(
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
    if let box = boxes.first {
      let cx = Double(box.origin.x + box.size.width / 2) * Double(canvas.width)
      let cy = Double(box.origin.y + box.size.height / 2) * Double(canvas.height)
      xKeys.append(ExtraStyleKeyframe(frame: frame, value: cx, easing: .linear))
      yKeys.append(ExtraStyleKeyframe(frame: frame, value: cy, easing: .linear))
    }
    frame += 15
  }
  guard !xKeys.isEmpty else { return [] }
  return [
    ExtraStyleTrack(property: .positionX, kind: .keyframes(keys: xKeys), startFrame: startFrame),
    ExtraStyleTrack(property: .positionY, kind: .keyframes(keys: yKeys), startFrame: startFrame),
  ]
}

// MARK: - Shape helpers

/// A star path centred at (outerRadius, outerRadius) in local
/// space, so it spans [0, 2R] × [0, 2R] and the anchor math
/// centres it (the shape's nodeSize is the 2R square — a star
/// centred at (0, 0) would render offset by a radius).
func extraStyleStarShape(outerRadius: CGFloat, innerRadius: CGFloat, spikes: Int) -> ExtraStyleShapeKind {
  .star(
    center: CGPoint(x: outerRadius, y: outerRadius),
    outerRadius: outerRadius, innerRadius: innerRadius, spikes: spikes
  )
}

/// A rectangle path in local space: origin (0, 0), positive
/// extents — the anchor math centres it.
func extraStyleRectShape(width: CGFloat, height: CGFloat) -> ExtraStyleShapeKind {
  .rect(CGRect(x: 0, y: 0, width: width, height: height))
}

/// An ellipse in local space, same convention as the rect.
func extraStyleEllipseShape(width: CGFloat, height: CGFloat) -> ExtraStyleShapeKind {
  .ellipse(CGRect(x: 0, y: 0, width: width, height: height))
}

/// A shape node from a shape kind + fill/stroke.
func extraStyleShapeNode(
  id: String, shape: ExtraStyleShapeKind, fill: ExtraStyleRGBA?,
  stroke: ExtraStyleRGBA? = nil, strokeWidth: CGFloat = 0,
  position: CGPoint, zIndex: Int,
  visibleRange: ClosedRange<Int>? = nil,
  fillColorParamId: String? = nil,
  blendMode: ExtraStyleBlendMode = .normal,
  mask: ExtraStyleMask? = nil,
  tracks: [ExtraStyleTrack] = []
) -> ExtraStyleNode {
  ExtraStyleNode(
    id: id, kind: .shape,
    position: position, anchor: CGPoint(x: 0.5, y: 0.5),
    zIndex: zIndex,
    blendMode: blendMode,
    mask: mask,
    visibleRange: visibleRange,
    shape: ExtraStyleShapeContent(
      shape: shape, fill: fill, fillColorParamId: fillColorParamId,
      stroke: stroke, strokeWidth: strokeWidth
    ),
    tracks: tracks
  )
}

/// A full-frame gradient node (background). Position is the canvas
/// centre and the rect is the full canvas in local space, so the
/// anchor math lands it exactly on the frame (local (0, 0) maps to
/// canvas (0, 0)). Vertical linear by default; radial centres on
/// the upper-middle of the frame.
func extraStyleBackgroundGradientNode(
  id: String, canvas: CGSize, colors: [ExtraStyleRGBA], locations: [CGFloat]? = nil,
  colorParamIds: [String?]? = nil, zIndex: Int = 0,
  vertical: Bool = true, radial: Bool = false
) -> ExtraStyleNode {
  let kind: ExtraStyleGradientKind = radial
    ? .radial(
      center: CGPoint(x: canvas.width / 2, y: canvas.height * 0.4),
      radius: max(canvas.width, canvas.height) * 0.75
    )
    : .linear(
      start: CGPoint(x: 0, y: 0),
      end: vertical
        ? CGPoint(x: 0, y: canvas.height)
        : CGPoint(x: canvas.width, y: 0)
    )
  return ExtraStyleNode(
    id: id, kind: .gradient,
    position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
    anchor: CGPoint(x: 0.5, y: 0.5),
    zIndex: zIndex,
    gradient: ExtraStyleGradientContent(
      kind: kind,
      colors: colors,
      colorParamIds: colorParamIds,
      locations: locations,
      rect: CGRect(origin: .zero, size: canvas)
    )
  )
}
