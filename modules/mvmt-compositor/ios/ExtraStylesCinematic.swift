import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 4 re-scope, Cinematic family
//
// LYRIC-ONLY (Jaizon, 2026-11-13 ~10:28 MST): "no styles that take
// up the whole screen — just lyrics with cool animations and
// stuff." The video is the star. Every style in this file is now
// words on the footage: no full-screen background, wash, tunnel,
// portal, particle field, HUD, planet, photo frame, letterbox, or
// scene composition. Decor survives only as small accents attached
// to the words (a twinkle star, a faint echo copy, a tone rule, a
// burst). Dream Sequence is NOT in this file — it lives in
// ExtraStylesDemos.swift and is registered once, there; do not
// duplicate it here.
//
// Four styles (docs/EXTRA-STYLES-2.0.md §17 rows 2–5):
//   - Memory Fragments — words surfacing like developing photos.
//   - Floating Universe — words adrift, twinkling on emphasis.
//   - Film Credits Reimagined — large tracked type, words only.
//   - Parallel Worlds — one line, two voices, switching on the beat.
//
// Flags match src/lib/extra-styles/catalog.ts (STYLE_CAPABILITY_MAP)
// — the coordinator owns that map; flag changes are listed in the
// re-scope report. All four styles are FALSE/FALSE except
// parallel-worlds (TRUE/FALSE: the beat switch still reads
// automation).

// MARK: - Lyric-only shared helpers (also used by ExtraStylesDemos.swift)
//
// The word/character helpers in ExtraStyleBuilders.swift expose no
// stroke parameter, and the engine has no blur/glow property — so
// legibility over arbitrary footage is a dark outline, stamped
// onto the built nodes here. Single-line text nodes take their
// stroke directly via extraStyleTextNode.

/// Stamp a dark legibility outline onto text nodes (word/char
/// nodes built by the shared helpers). Non-text nodes pass through
/// untouched.
func extraStyleStrokeTextNodes(
  _ nodes: [ExtraStyleNode], sizePoints: CGFloat,
  stroke: ExtraStyleRGBA = ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 0.55)
) -> [ExtraStyleNode] {
  nodes.map { node in
    var stamped = node
    if stamped.text != nil {
      stamped.text?.strokeColor = stroke
      stamped.text?.strokeWidthPoints = max(1, sizePoints * 0.04)
    }
    return stamped
  }
}

/// Word layout measured exactly the way extraStyleWordNodes lays
/// words out (same widths, same centred cursor): the total width
/// of the line and each word's centre-x, for placing word-attached
/// accents (twinkle stars, bursts, emoji) on the same grid.
func extraStyleWordLayout(
  words: [String], font: String, sizePoints: CGFloat, canvasWidth: CGFloat
) -> (totalWidth: CGFloat, centres: [CGFloat]) {
  let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
  let widths = words.map { extraStyleTextWidth($0, fontPostScriptName: font, sizePoints: sizePoints) }
  let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, words.count - 1))
  var cursorX = (canvasWidth - totalWidth) / 2
  var centres: [CGFloat] = []
  for width in widths {
    centres.append(cursorX + width / 2)
    cursorX += width + spaceWidth
  }
  return (totalWidth, centres)
}

/// Fit a size to the frame: shrink only when the line would run
/// wider than `maxWidthRatio` of the canvas. Word nodes do not
/// wrap, so a long line must fit on one row.
func extraStyleFitSize(
  baseSize: CGFloat, text: String, font: String, canvasWidth: CGFloat,
  maxWidthRatio: CGFloat = 0.88
) -> CGFloat {
  let width = extraStyleTextWidth(text, fontPostScriptName: font, sizePoints: baseSize)
  guard width > 0 else { return baseSize }
  return min(baseSize, baseSize * canvasWidth * maxWidthRatio / width)
}

/// Fallback for a line with no word timings (e.g. a hand-added
/// line): one centred, outlined line node with a soft enter/exit,
/// so the line never vanishes just because its words are untimed.
func extraStyleLyricFallbackNode(
  id: String, line: ExtraStyleInputLine, range: ClosedRange<Int>,
  y: CGFloat, sizePoints: CGFloat, color: ExtraStyleRGBA, font: String,
  zIndex: Int, canvasWidth: CGFloat
) -> ExtraStyleNode {
  extraStyleTextNode(
    id: id, text: line.text, font: font, sizePoints: sizePoints,
    color: color,
    position: CGPoint(x: canvasWidth / 2, y: y), zIndex: zIndex,
    visibleRange: range,
    maxWidthPoints: canvasWidth * 0.88,
    strokeColor: ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 0.55),
    strokeWidthPoints: max(1, sizePoints * 0.04),
    tracks: [extraStyleEnterExitOpacityTrack(
      start: range.lowerBound, end: range.upperBound, enterFrames: 12, exitFrames: 12
    )]
  )
}

// MARK: - Memory Fragments (cinematic, §17 #2)
//
// LYRIC-ONLY: the photo frames are gone (paper texture, sepia
// "photo", captions-in-frames, layered back frames, face
// avoidance — all of it was scene, not lyrics). What survives is
// the feeling: words surfacing one at a time like a photograph
// developing — a slow dissolve per word, a gentle drift, serif
// type, the line's emoji as a small stamp at the end of the line.

final class MemoryFragmentsExtraStyle: ExtraStyleDefinition {
  let id = "memory-fragments"
  let version = 1
  let name = "Memory Fragments"
  let tagline = "Words surfacing like old photographs, one memory at a time."
  let category = "cinematic"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "layout", label: "Layout",
        options: [("scattered", "Scattered"), ("stack", "Stack"), ("grid", "Grid")],
        default: "scattered", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "dissolve", label: "Cross-dissolve", min: 0.25, max: 2, step: 0.05,
        default: 0.6, affects: "motion", unit: "s"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "warm-album", "label": "Warm album", "values": ["layout": "scattered", "dissolve": 0.8]],
      ["id": "clean-stack", "label": "Clean stack", "values": ["layout": "stack", "dissolve": 0.4]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["layout", "dissolve"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let layout = extraStyleParamString(input.params, "layout", "scattered")
    let dissolveSeconds = extraStyleParamDouble(input.params, "dissolve", 0.6)
    let dissolveFrames = max(3, Int((dissolveSeconds * fps).rounded()))
    let font = ExtraStyleFonts.serifRegular
    let ink = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // Scattered lines alternate height (the old scattered
      // frames did); stack/grid sit centred.
      let centreY: CGFloat = layout == "scattered"
        ? canvas.height * (lineIndex % 2 == 0 ? 0.47 : 0.53)
        : canvas.height * 0.5
      let sizePoints = extraStyleFitSize(
        baseSize: canvas.width * 0.058, text: line.text, font: font, canvasWidth: canvas.width
      )
      let emphasis = Set(line.emphasisWordIndices)
      // Drift direction by layout: scattered wanders both axes,
      // stack rises from below, grid barely moves (stagger only).
      let (driftX, driftY): (Double, Double) = {
        switch layout {
        case "stack": return (0, 10)
        case "grid": return (4, 4)
        default: return (8, 6)
        }
      }()
      let side: Double = lineIndex % 2 == 0 ? 1 : -1
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centreY, sizePoints: sizePoints, color: ink, font: font,
        zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStart, wordEnd in
        var tracks: [ExtraStyleTrack] = [
          // Developing-photo dissolve, per word.
          extraStyleEnterExitOpacityTrack(
            start: wordStart, end: wordEnd,
            enterFrames: dissolveFrames, exitFrames: dissolveFrames
          ),
        ]
        if emphasis.contains(index) {
          tracks.append(extraStyleSpringInTrack(start: wordStart, from: 0.8, stiffness: 160, damping: 12))
        }
        tracks.append(ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 240, periodParamId: nil, keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 120, value: -driftY, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: wordStart
        ))
        if driftX > 0 {
          tracks.append(ExtraStyleTrack(
            property: .positionX,
            kind: .loop(periodFrames: 300, periodParamId: nil, keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: driftX * side, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 300, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: wordStart
          ))
        }
        return tracks
      }
      if words.isEmpty {
        builder.add(extraStyleLyricFallbackNode(
          id: "line-\(lineIndex)", line: line,
          range: lineStartFrame...lineEndFrame,
          y: centreY, sizePoints: sizePoints, color: ink, font: font,
          zIndex: 10, canvasWidth: canvas.width
        ))
      } else {
        for word in extraStyleStrokeTextNodes(words, sizePoints: sizePoints) { builder.add(word) }
      }
      // The line's emoji as a small stamp at the end of the line
      // (clamped inside the frame — a full-width line leaves no
      // room past its last word).
      let layoutWidth = extraStyleWordLayout(
        words: line.words.map { $0.text }, font: font,
        sizePoints: sizePoints, canvasWidth: canvas.width
      ).totalWidth
      let stampSize = sizePoints * 0.85
      if let stamp = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width - stampSize * 0.6, canvas.width / 2 + layoutWidth / 2 + sizePoints * 0.9),
          y: centreY - sizePoints * 0.55
        ),
        sizePoints: stampSize, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(stamp)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Floating Universe (cinematic, §17 #3)
//
// LYRIC-ONLY: the deep-space background, both star-field
// emitters, all three planets, orbit paths, both moons and the
// constellation are gone — a full-screen space scene. What
// survives is the motion: words floating with a slow drift on
// depth layers (far / mid / near by line index), and a twinkle
// that lands ONLY on emphasis words (a small star above the word,
// flickering), plus the line's emoji as a small satellite at the
// end of the line.

final class FloatingUniverseExtraStyle: ExtraStyleDefinition {
  let id = "floating-universe"
  let version = 1
  let name = "Floating Universe"
  let tagline = "Words adrift in slow orbit, twinkling on the words that matter."
  let category = "cinematic"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "orbitSpeed", label: "Orbit speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Twinkle colour", default: "#8FA8FF", affects: "appearance"),
      extraStyleToggleParam(id: "twinkle", label: "Twinkle on emphasis", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "deep-field", "label": "Deep field", "values": ["orbitSpeed": 0.6, "twinkle": true]],
      ["id": "sparse-drift", "label": "Sparse drift", "values": ["orbitSpeed": 1.4, "twinkle": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["twinkle"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#8FA8FF"))
    let twinkle = extraStyleParamBool(input.params, "twinkle", true)
    var builder = ExtraStyleSceneBuilder()

    // Depth layers by line index — size, base opacity, drift
    // amplitude and height all grow with depth. Typography only.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let depth = lineIndex % 3
      let (baseSize, baseOpacity, parallax, yFraction): (CGFloat, CGFloat, Double, CGFloat) = {
        switch depth {
        case 0: return (canvas.width * 0.042, 0.55, 5, 0.44)
        case 2: return (canvas.width * 0.075, 1, 15, 0.56)
        default: return (canvas.width * 0.058, 0.8, 9, 0.5)
        }
      }()
      let centreY = canvas.height * yFraction
      let font = depth == 2 ? ExtraStyleFonts.avenirHeavy : ExtraStyleFonts.avenir
      let sizePoints = extraStyleFitSize(
        baseSize: baseSize, text: line.text, font: font, canvasWidth: canvas.width
      )
      let emphasis = Set(line.emphasisWordIndices)
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centreY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: font, zIndex: 10, canvasWidth: canvas.width
      ) { index, wordStart, wordEnd in
        var tracks: [ExtraStyleTrack] = [
          // Enter/exit envelope capped at the depth layer's base
          // opacity (the text helper exposes no base opacity).
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStart, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(wordEnd, wordStart + 12), value: Double(baseOpacity), easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(wordStart, wordEnd - 12), value: Double(baseOpacity), easing: .linear),
              ExtraStyleKeyframe(frame: wordEnd, value: 0, easing: .easeInCubic),
            ]),
            startFrame: wordStart
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 240, periodParamId: "orbitSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 120, value: -parallax, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: wordStart
          ),
          ExtraStyleTrack(
            property: .positionX,
            kind: .loop(periodFrames: 300, periodParamId: "orbitSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: parallax * 0.6, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 300, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: wordStart
          ),
        ]
        if emphasis.contains(index) {
          tracks.append(extraStyleSpringInTrack(start: wordStart, from: 0.85, stiffness: 170, damping: 11))
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
      // Twinkle stars: one small star above each emphasis word,
      // flickering on its own seeded track. Word-attached only —
      // no star field anywhere else in the frame.
      if twinkle {
        let layout = extraStyleWordLayout(
          words: line.words.map { $0.text }, font: font,
          sizePoints: sizePoints, canvasWidth: canvas.width
        )
        for wordIndex in emphasis where wordIndex >= 0 && wordIndex < line.words.count && wordIndex < layout.centres.count {
          let word = line.words[wordIndex]
          let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
          let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
          guard wordEndFrame > wordStartFrame else { continue }
          let radius = sizePoints * 0.22
          builder.add(extraStyleShapeNode(
            id: "twinkle-\(lineIndex)-\(wordIndex)",
            shape: extraStyleStarShape(outerRadius: radius, innerRadius: radius * 0.45, spikes: 4),
            fill: accent,
            position: CGPoint(x: layout.centres[wordIndex], y: centreY - sizePoints * 0.95),
            zIndex: 11,
            visibleRange: wordStartFrame...wordEndFrame,
            fillColorParamId: "accent",
            tracks: [extraStyleFlickerTrack(
              start: wordStartFrame, end: wordEndFrame,
              base: 0.9, amplitude: 0.35,
              seed: input.seed ^ UInt64(lineIndex * 16 + wordIndex + 1)
            )]
          ))
        }
      }
      // The line's emoji as a small satellite at the end of the line
      // (clamped inside the frame — a full-width line leaves no
      // room past its last word).
      let layoutWidth = extraStyleWordLayout(
        words: line.words.map { $0.text }, font: font,
        sizePoints: sizePoints, canvasWidth: canvas.width
      ).totalWidth
      let satelliteSize = sizePoints * 0.8
      if var satellite = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width - satelliteSize * 0.6, canvas.width / 2 + layoutWidth / 2 + sizePoints * 0.9),
          y: centreY - sizePoints * 0.6
        ),
        sizePoints: satelliteSize, zIndex: 12,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        satellite.tracks.append(ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 240, periodParamId: "orbitSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 120, value: -8, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: lineStartFrame
        ))
        builder.add(satellite)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Film Credits Reimagined (cinematic, §17 #4)
//
// LYRIC-ONLY: the dark background gradient, the vignette and the
// letterbox bars are gone — all three were frame furniture, not
// lyrics. What survives is the type itself: large tracked Didot,
// each glyph spreading out from the centre line into its tracked
// slot, a tone-coloured rule under the words, and a slow push-in
// with a gentle rise per line over a slow camera drift. Words
// only; the footage shows through everywhere else.

final class FilmCreditsReimaginedExtraStyle: ExtraStyleDefinition {
  let id = "film-credits-reimagined"
  let version = 1
  let name = "Film Credits Reimagined"
  let tagline = "Large tracked type, rolling in like end credits — words only."
  let category = "cinematic"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "tracking", label: "Letter tracking", min: 0, max: 0.6, step: 0.01,
        default: 0.25, affects: "layout"
      ),
      extraStyleSliderParam(
        id: "pushIn", label: "Push-in", min: 0, max: 0.2, step: 0.01,
        default: 0.08, affects: "motion"
      ),
      extraStyleColorParam(id: "textColor", label: "Text colour", default: "#F4F1E9", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "classic", "label": "Classic", "values": ["tracking": 0.35, "pushIn": 0.05]],
      ["id": "modern-tight", "label": "Modern tight", "values": ["tracking": 0.08, "pushIn": 0.12]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  var rebuildParamIds: [String] { ["tracking", "pushIn"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let durationFrames = input.durationFrames
    // Letter-spacing: the engine exposes no tracking knob
    // (ExtraStyleTextContent has no letterSpacing field), so
    // tracking is faked with per-character layout — each glyph is
    // its own node, laid out with a baked gap, and the gap is
    // animated open from the centre (see addCreditLine).
    let tracking = extraStyleParamDouble(input.params, "tracking", 0.25)
    let pushIn = extraStyleParamDouble(input.params, "pushIn", 0.08)
    let textColor = extraStyleColor(extraStyleParamString(input.params, "textColor", "#F4F1E9"))
    var builder = ExtraStyleSceneBuilder()

    // One credit line: uppercased tracked type (per-character
    // nodes), a tone-coloured rule beneath, inside its own group
    // (slow push-in + gentle rise). The group is a child of the
    // camera group, whose slow translate is the camera-move
    // illusion; `cameraChildren` collects the line group ids.
    func addCreditLine(
      _ builder: inout ExtraStyleSceneBuilder,
      cameraChildren: inout [String],
      index: Int, text: String, tone: String?,
      lineStartFrame: Int, lineEndFrame: Int
    ) {
      let upper = text.uppercased()
      let sizePoints = canvas.width * 0.075
      let font = ExtraStyleFonts.didot
      let gap = CGFloat(tracking) * sizePoints
      let chars = Array(upper)
      let widths = chars.map { $0 == " " ? extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints) : extraStyleTextWidth(String($0), fontPostScriptName: font, sizePoints: sizePoints) }
      let totalWidth = widths.reduce(0, +) + gap * CGFloat(max(0, chars.count - 1))
      var cursorX = (canvas.width - totalWidth) / 2
      var members: [String] = []
      for (charIndex, char) in chars.enumerated() {
        let charWidth = widths[charIndex]
        defer { cursorX += charWidth + gap }
        guard char != " " else { continue }
        let charCentreX = cursorX + charWidth / 2
        let charStart = min(lineEndFrame, lineStartFrame + charIndex * 2)
        guard lineEndFrame > charStart else { continue }
        let charId = "credit-char-\(index)-\(charIndex)"
        // Dramatic tracking: the glyph starts at the centre line
        // (offset = centre − final position) and spreads out to
        // its tracked slot over ~26 frames, staggered per glyph.
        builder.addChild(extraStyleTextNode(
          id: charId,
          text: String(char), font: font, sizePoints: sizePoints,
          color: textColor,
          position: CGPoint(x: charCentreX - canvas.width / 2, y: 0),
          zIndex: 1,
          visibleRange: charStart...lineEndFrame,
          colorParamId: "textColor",
          strokeColor: ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 0.6),
          strokeWidthPoints: max(1, sizePoints * 0.03),
          tracks: [
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: charStart, value: Double(canvas.width / 2 - charCentreX), easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(lineEndFrame, charStart + 26), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: charStart
            ),
            ExtraStyleTrack(
              property: .positionY,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: charStart, value: 8, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(lineEndFrame, charStart + 20), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: charStart
            ),
          ]
        ))
        members.append(charId)
      }
      // Tone-coloured rule under the type.
      let ruleWidth = totalWidth * 0.8
      let rulePath = CGMutablePath()
      rulePath.move(to: CGPoint(x: 0, y: 0))
      rulePath.addLine(to: CGPoint(x: ruleWidth, y: 0))
      let ruleId = "credit-rule-\(index)"
      builder.addChild(ExtraStyleNode(
        id: ruleId, kind: .path,
        position: CGPoint(x: -ruleWidth / 2, y: sizePoints * 0.85),
        anchor: .zero, zIndex: 1,
        visibleRange: lineStartFrame...lineEndFrame,
        path: ExtraStylePathContent(
          path: rulePath,
          strokeColor: extraStyleToneColor(tone).withAlpha(0.8),
          strokeWidth: 2,
          dash: nil
        )
      ))
      members.append(ruleId)
      let groupId = "credit-\(index)"
      builder.addChild(ExtraStyleNode(
        id: groupId, kind: .group,
        children: members,
        position: .zero, anchor: .zero,
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          // Slow push-in (scale) + gentle rise over the line.
          ExtraStyleTrack(
            property: .scale,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: lineEndFrame, value: 1 + pushIn, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 6, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: lineEndFrame, value: -10, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 12, exitFrames: 12),
        ]
      ))
      cameraChildren.append(groupId)
    }

    var cameraChildren: [String] = []
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    if sortedLines.isEmpty {
      addCreditLine(
        &builder, cameraChildren: &cameraChildren,
        index: 0, text: "MVMT Studio", tone: nil,
        lineStartFrame: 0, lineEndFrame: max(1, durationFrames)
      )
    } else {
      for (lineIndex, line) in sortedLines.enumerated() {
        guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: durationFrames) else { continue }
        addCreditLine(
          &builder, cameraChildren: &cameraChildren,
          index: lineIndex, text: line.text, tone: line.tone,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame
        )
      }
    }
    // The camera group: one slow upward translate over the whole
    // scene — the camera-move illusion behind the per-line push-in.
    builder.add(ExtraStyleNode(
      id: "credits-camera", kind: .group,
      children: cameraChildren,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: .zero,
      zIndex: 10,
      tracks: [
        ExtraStyleTrack(
          property: .positionY,
          kind: .keyframes(keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: durationFrames, value: -Double(canvas.height) * 0.04, easing: .easeInOutSine),
          ]),
          startFrame: 0
        ),
        ExtraStyleTrack(
          property: .positionX,
          kind: .keyframes(keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: durationFrames, value: 6, easing: .easeInOutSine),
          ]),
          startFrame: 0
        ),
      ]
    ))
    return builder.build(canvas: canvas, durationFrames: durationFrames)
  }
}

// MARK: - Parallel Worlds (cinematic, §17 #5)
//
// LYRIC-ONLY, REPLACEMENT CONCEPT UNDER THE SAME ID: the old
// scene — full-screen background, tint washes, a mirrored
// (reversed, mirror-written) copy of the line as the second world,
// split-screen divider, sweeping wipe bar, and a full-frame
// displacement overlay — cannot exist as lyrics-only, and the
// mirrored text is retired outright: reversed text as a lyric
// line is unreadable, and a true glyph flip is not expressible
// (uniform scale only). The replacement keeps the idea — two
// worlds, one line: each line is sung in the voice of the world
// active on the downbeat (warm World A / cool World B, alternating
// per the switch), with a faint offset echo of the words in the
// same reading order, and the line's emoji small at the end.
// The beat-phase switch (needsAudioAutomation = true) still
// drives which world a line belongs to.

final class ParallelWorldsExtraStyle: ExtraStyleDefinition {
  let id = "parallel-worlds"
  let version = 1
  let name = "Parallel Worlds"
  let tagline = "One line, two voices — warm and cool, trading places on the downbeat."
  let category = "cinematic"
  // TRUE per src/lib/extra-styles/catalog.ts
  // (STYLE_CAPABILITY_MAP): the UI prepares automation for this
  // style, so the beat-phase switch reads input.automation
  // directly. Only the low-confidence case falls back (tempo
  // cadence, then a fixed 3 s cadence) — never a missing-automation
  // case.
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSegmentedParam(
        id: "switchMode", label: "Switch on",
        options: [("downbeat", "Downbeat"), ("bar", "Every bar"), ("halfBar", "Half bar")],
        default: "downbeat", affects: "motion"
      ),
      extraStyleColorParam(id: "worldAColor", label: "World A colour", default: "#FFD9A0", affects: "appearance"),
      extraStyleColorParam(id: "worldBColor", label: "World B colour", default: "#8FB8FF", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "warm-cool", "label": "Warm / Cool", "values": ["switchMode": "downbeat"]],
      ["id": "neon-split", "label": "Neon split", "values": ["worldAColor": "#FF5C8A", "worldBColor": "#35F2D8"]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  var rebuildParamIds: [String] { ["switchMode"] }

  // Switch frames from the beat grid. Confidence-gated: below 0.5
  // beatPhase(at:) reports no grid, so fall back to the tempo
  // (bar = 4 beats) and then to a fixed 90-frame cadence.
  private func switchFrames(input: ExtraStyleBuildInput, mode: String) -> [Int] {
    let fps = input.fps > 0 ? input.fps : 30
    let durationFrames = input.durationFrames
    func frame(of seconds: Double) -> Int {
      max(0, min(durationFrames, Int((seconds * fps).rounded())))
    }
    var frames: [Int] = []
    if let automation = input.automation, automation.beatConfidence >= 0.5, !automation.beats.isEmpty {
      let beats = automation.beats
      switch mode {
      case "halfBar":
        frames = stride(from: 0, to: beats.count, by: 2).map { frame(of: beats[$0].timeSeconds) }
      case "bar":
        let downbeats = beats.filter { $0.isDownbeat }
        if !downbeats.isEmpty {
          frames = downbeats.map { frame(of: $0.timeSeconds) }
        } else {
          frames = stride(from: 0, to: beats.count, by: 4).map { frame(of: beats[$0].timeSeconds) }
        }
      default: // downbeat
        let downbeats = beats.filter { $0.isDownbeat }
        let source = downbeats.isEmpty ? beats : downbeats
        frames = source.map { frame(of: $0.timeSeconds) }
      }
    } else if let automation = input.automation, automation.tempoBpm > 0 {
      let beatFrames = max(15, Int((60.0 / automation.tempoBpm * fps).rounded()))
      let step = mode == "halfBar" ? beatFrames * 2 : beatFrames * 4
      var f = step
      while f < durationFrames { frames.append(f); f += step }
    } else {
      var f = 90
      while f < durationFrames { frames.append(f); f += 90 }
    }
    let cleaned = Array(Set(frames)).filter { $0 > 0 && $0 < durationFrames }.sorted()
    if cleaned.isEmpty, durationFrames > 120 { return [durationFrames / 2] }
    return cleaned
  }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let switchMode = extraStyleParamString(input.params, "switchMode", "downbeat")
    let worldAColor = extraStyleColor(extraStyleParamString(input.params, "worldAColor", "#FFD9A0"))
    let worldBColor = extraStyleColor(extraStyleParamString(input.params, "worldBColor", "#8FB8FF"))
    let switches = switchFrames(input: input, mode: switchMode)
    var builder = ExtraStyleSceneBuilder()

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      // The world active when this line starts: the number of
      // switches at or before the line start decides it (even →
      // World A, odd → World B). Consecutive lines trade voices
      // on the downbeat; the switch itself is visible as the
      // tint change, not as a wipe or divider.
      let switchesBefore = switches.filter { $0 <= lineStartFrame }.count
      let tint = switchesBefore % 2 == 0 ? worldAColor : worldBColor
      let tintParamId = switchesBefore % 2 == 0 ? "worldAColor" : "worldBColor"
      let centreY = canvas.height * 0.5
      let font = ExtraStyleFonts.black
      let sizePoints = extraStyleFitSize(
        baseSize: canvas.width * 0.06, text: line.text, font: font, canvasWidth: canvas.width
      )
      let emphasis = Set(line.emphasisWordIndices)
      // Faint offset echo of the words — same reading order, same
      // tint at low alpha, offset down-right behind the words.
      // Never a mirrored or reversed copy.
      builder.add(extraStyleTextNode(
        id: "echo-\(lineIndex)",
        text: line.text, font: font, sizePoints: sizePoints,
        color: tint.withAlpha(0.18),
        position: CGPoint(x: canvas.width / 2 + 10, y: centreY + 8),
        zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        colorParamId: tintParamId,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))
      let words = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centreY, sizePoints: sizePoints, color: tint, font: font,
        zIndex: 10, canvasWidth: canvas.width,
        colorParamId: tintParamId
      ) { index, wordStart, wordEnd in
        var tracks: [ExtraStyleTrack] = [
          extraStyleEnterExitOpacityTrack(start: wordStart, end: wordEnd),
        ]
        if emphasis.contains(index) {
          tracks.append(extraStyleSpringInTrack(start: wordStart, from: 0.7, stiffness: 200, damping: 10))
        }
        return tracks
      }
      if words.isEmpty {
        builder.add(extraStyleLyricFallbackNode(
          id: "line-\(lineIndex)", line: line,
          range: lineStartFrame...lineEndFrame,
          y: centreY, sizePoints: sizePoints, color: tint, font: font,
          zIndex: 10, canvasWidth: canvas.width
        ))
      } else {
        for word in extraStyleStrokeTextNodes(words, sizePoints: sizePoints) { builder.add(word) }
      }
      // The line's emoji, small, at the end of the line (clamped
      // inside the frame — a full-width line leaves no room past
      // its last word).
      let layoutWidth = extraStyleWordLayout(
        words: line.words.map { $0.text }, font: font,
        sizePoints: sizePoints, canvasWidth: canvas.width
      ).totalWidth
      let emojiSize = sizePoints * 0.85
      if let emoji = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width - emojiSize * 0.6, canvas.width / 2 + layoutWidth / 2 + sizePoints * 0.9),
          y: centreY - sizePoints * 0.55
        ),
        sizePoints: emojiSize, zIndex: 11,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(emoji)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (cinematic rest)

extension ExtraStylesPhase3 {
  static func registerCinematicRest(into registry: ExtraStyleRegistry) {
    registry.register(MemoryFragmentsExtraStyle())
    registry.register(FloatingUniverseExtraStyle())
    registry.register(FilmCreditsReimaginedExtraStyle())
    registry.register(ParallelWorldsExtraStyle())
  }
}
