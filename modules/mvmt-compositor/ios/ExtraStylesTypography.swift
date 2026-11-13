import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3, Typography family (rest)
//
// Styles #7–#10 (docs/EXTRA-STYLES-2.0.md §17):
//   - Liquid Letters — deformable text group, ripple paths, blobs.
//   - Infinite Tunnel — concentric rings, perspective-scaled text.
//   - Portal Typography — portal rings, words pass through per phrase.
//   - Typography Explosion — per-character explosion + spring reassembly.
//
// LYRIC-ONLY RE-SCOPE (Phase 4, Jaizon 2026-11-13 ~10:28 MST:
// "no styles that take up the whole screen just lyrics with cool
// animations" — the video is the star): every style below is now
// lyrics with kinetic animation ONLY. Full-screen backgrounds,
// full-frame displacement warps, tunnel rings, portal glows and
// full-width ripple paths are gone; what remains is word-attached
// accents (blobs behind the words, a ring hugging the line,
// shards bursting from the line) plus word-by-word entrances,
// emphasis pops from the stored intelligence, and karaoke-style
// timing. (Typography Physics, the 5th typography style, lives in
// ExtraStylesDemos.swift — not this file.)
//
// Audio flags match the authoritative TS static map
// (src/lib/extra-styles/catalog.ts, STYLE_CAPABILITY_MAP):
// Liquid Letters, Infinite Tunnel and Typography Explosion declare
// needsAudioAutomation = true (automation IS supplied at prepare
// time); Portal Typography is false. None needs subject masks.
// The only fallback in the audio styles is the beat-confidence
// gate: beatPhase(at:) is nil below 0.5 confidence, so builders
// fall back to the onset envelope there — never to a
// missing-automation case.

// MARK: - File-private helpers (this file only)

/// Append a keyframe only when its frame is strictly after the
/// previous key's frame — clamped schedules (short lines/words)
/// must never emit duplicate-frame keys.
private func typographyAppendKeyframe(
  _ keys: inout [ExtraStyleKeyframe], frame: Int, value: Double, easing: ExtraStyleEasing
) {
  guard keys.isEmpty || frame > keys[keys.count - 1].frame else { return }
  keys.append(ExtraStyleKeyframe(frame: frame, value: value, easing: easing))
}

/// Baked explosion flight for ONE axis (docs §5.2 — physics is
/// baked at build time, never integrated at render time): the
/// value rests at 0, flies out to `offset` over 10 frames from
/// `trigger`, holds to `trigger + 16`, then springs back to 0
/// sampled every 2 frames from the engine's analytic spring
/// solution. Used by Typography Explosion for position X/Y and
/// for the rotation snap-back.
private func typographyExplosionOffsetKeys(
  lineStart: Int, trigger: Int, end: Int, offset: Double, fps: Double
) -> [ExtraStyleKeyframe] {
  var keys: [ExtraStyleKeyframe] = [
    ExtraStyleKeyframe(frame: lineStart, value: 0, easing: .linear),
  ]
  if trigger > lineStart {
    keys.append(ExtraStyleKeyframe(frame: trigger, value: 0, easing: .linear))
  }
  let outFrame = min(end, trigger + 10)
  let holdFrame = min(end, trigger + 16)
  typographyAppendKeyframe(&keys, frame: outFrame, value: offset, easing: .easeOutCubic)
  typographyAppendKeyframe(&keys, frame: holdFrame, value: offset, easing: .linear)
  var frame = holdFrame + 2
  var settled = false
  while frame <= end, !settled {
    let t = Double(frame - holdFrame) / fps
    let value = extraStyleSpringPosition(
      from: offset, to: 0, stiffness: 90, damping: 9, mass: 1,
      initialVelocity: 0, tSeconds: t
    )
    keys.append(ExtraStyleKeyframe(frame: frame, value: value, easing: .linear))
    if abs(value) < 1 { settled = true }
    frame += 2
  }
  if keys.last?.value != 0 {
    let finalFrame = min(end, frame)
    if keys.isEmpty || finalFrame > keys[keys.count - 1].frame {
      keys.append(ExtraStyleKeyframe(frame: finalFrame, value: 0, easing: .linear))
    }
  }
  return keys
}

/// A procedural triangle (shard) in positive local space, so the
/// anchor math centres it. Points: (0,0) → (size, 0.45·size) →
/// (0,size).
private func typographyShardPath(size: CGFloat) -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: 0, y: 0))
  path.addLine(to: CGPoint(x: size, y: size * 0.45))
  path.addLine(to: CGPoint(x: 0, y: size))
  path.closeSubpath()
  return path
}

// MARK: - Style 7: Liquid Letters (typography)

final class LiquidLettersExtraStyle: ExtraStyleDefinition {
  let id = "liquid-letters"
  let version = 1
  let name = "Liquid Letters"
  let tagline = "Lyrics melt, stretch, and ripple like water."
  let category = "typography"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "flowSpeed", label: "Flow speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "ripple", label: "Ripple", min: 0, max: 30, step: 1,
        default: 14, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Liquid colour", default: "#7DD8FF", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "calm", "label": "Calm", "values": ["flowSpeed": 0.6, "ripple": 8]],
      ["id": "rapids", "label": "Rapids", "values": ["flowSpeed": 1.6, "ripple": 24]],
    ]
  }

  var inputs: [String] { ["lines", "words", "audio", "intelligence"] }

  /// Ripple amplitude is baked into the loop keyframe values.
  var rebuildParamIds: [String] { ["ripple"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let ripple = extraStyleParamDouble(input.params, "ripple", 14)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#7DD8FF"))
    var builder = ExtraStyleSceneBuilder()

    // LYRIC-ONLY: no background wash, no full-frame displacement
    // warp (it distorted the video itself, not just the text).
    // The liquid lives in the words: blobs behind the line,
    // rippling words, and a ripple stroke under the line.

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    let sizePoints = canvas.width * 0.075
    let centerY = canvas.height * 0.5
    let font = ExtraStyleFonts.avenirHeavy
    for (lineIndex, line) in sortedLines.enumerated() {
      guard !line.text.isEmpty,
        let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames)
      else { continue }
      let toneColor = extraStyleToneColor(line.tone)

      // Word entries: the stored words, or the whole line as one
      // entry when the line has no word timings.
      let entryTexts: [String] = line.words.isEmpty ? [line.text] : line.words.map { $0.text }
      let entryStarts: [Double] = line.words.isEmpty ? [line.startSeconds] : line.words.map { $0.startSeconds }
      let entryEnds: [Double] = line.words.isEmpty ? [line.endSeconds] : line.words.map { $0.endSeconds }
      let spaceWidth = extraStyleTextWidth(" ", fontPostScriptName: font, sizePoints: sizePoints)
      let widths = entryTexts.map { extraStyleTextWidth($0, fontPostScriptName: font, sizePoints: sizePoints) }
      let totalWidth = widths.reduce(0, +) + spaceWidth * CGFloat(max(0, entryTexts.count - 1))

      var members: [String] = []

      // Blob shapes behind the text — the liquid body the words
      // float in. They breathe on a loop and swell with loudness.
      // Fills are baked from the accent hex (with alpha) rather
      // than fillColorParamId, which would re-resolve to alpha 1.
      for blob in 0..<2 {
        let blobId = "liquid-blob-\(lineIndex)-\(blob)"
        let blobWidth = totalWidth * 0.55 + sizePoints
        let blobHeight = sizePoints * 1.9
        builder.addChild(extraStyleShapeNode(
          id: blobId,
          shape: extraStyleEllipseShape(width: blobWidth, height: blobHeight),
          fill: accent.withAlpha(0.16),
          position: CGPoint(
            x: -totalWidth * 0.22 + CGFloat(blob) * totalWidth * 0.44,
            y: blob == 0 ? -sizePoints * 0.35 : sizePoints * 0.4
          ),
          zIndex: 0,
          visibleRange: lineStartFrame...lineEndFrame,
          blendMode: .screen,
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .loop(periodFrames: 90, periodParamId: "flowSpeed", keys: [
                ExtraStyleKeyframe(frame: 0, value: 0.92, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 45, value: 1.12, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 90, value: 0.92, easing: .easeInOutSine),
              ]),
              startFrame: lineStartFrame
            ),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: .loudness, base: 1, gain: 0.2),
              startFrame: lineStartFrame
            ),
          ]
        ))
        members.append(blobId)
      }

      // Per-word nodes, laid out centred RELATIVE to the group
      // origin (group children are relative — the helper's
      // canvas-absolute layout is not used here). Each word
      // ripples on a sine loop (phase-staggered by index), merges
      // toward the centre on entry, and stretches mid-line.
      var cursorX: CGFloat = 0
      for (index, wordText) in entryTexts.enumerated() {
        let wordWidth = widths[index]
        defer { cursorX += wordWidth + spaceWidth }
        let wordStartFrame = max(lineStartFrame, Int((entryStarts[index] * fps).rounded()))
        var wordEndFrame = min(lineEndFrame, Int((entryEnds[index] * fps).rounded()))
        var startFrame = wordStartFrame
        if wordEndFrame <= wordStartFrame {
          // No usable word timing: stagger by index.
          startFrame = min(lineEndFrame - 1, lineStartFrame + index * 4)
          wordEndFrame = lineEndFrame
        }
        guard wordEndFrame > startFrame else { continue }
        let relX = cursorX + wordWidth / 2 - totalWidth / 2
        let midFrame = startFrame + (wordEndFrame - startFrame) / 2
        // Emphasis pop (stored intelligence): an emphasized word
        // stretches further and renders in the line's tone colour
        // instead of the accent.
        let isEmphasis = line.emphasisWordIndices.contains(index)
        var scaleKeys: [ExtraStyleKeyframe] = []
        typographyAppendKeyframe(&scaleKeys, frame: startFrame, value: 1, easing: .easeInOutSine)
        typographyAppendKeyframe(&scaleKeys, frame: midFrame, value: isEmphasis ? 1.3 : 1.16, easing: .easeInOutSine)
        typographyAppendKeyframe(&scaleKeys, frame: wordEndFrame, value: 1, easing: .easeInOutSine)
        var mergeKeys: [ExtraStyleKeyframe] = []
        typographyAppendKeyframe(&mergeKeys, frame: startFrame, value: Double(relX) * 0.15, easing: .easeOutCubic)
        typographyAppendKeyframe(&mergeKeys, frame: min(wordEndFrame, startFrame + 18), value: 0, easing: .easeOutCubic)
        builder.addChild(extraStyleTextNode(
          id: "liquid-word-\(lineIndex)-\(index)",
          text: wordText, font: font, sizePoints: sizePoints,
          color: isEmphasis ? toneColor : accent,
          position: CGPoint(x: relX, y: 0),
          zIndex: 2,
          visibleRange: startFrame...wordEndFrame,
          strokeColor: ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0.9),
          strokeWidthPoints: 2,
          colorParamId: isEmphasis ? nil : "accent",
          tracks: [
            // Sine ripple along the line; the loop's period is
            // re-timed by flowSpeed, and each word is phase-shifted
            // by its index so the ripple travels down the line.
            ExtraStyleTrack(
              property: .positionY,
              kind: .loop(periodFrames: 60, periodParamId: "flowSpeed", keys: [
                ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 15, value: -ripple, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 30, value: 0, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 45, value: ripple, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: 60, value: 0, easing: .easeInOutSine),
              ]),
              startFrame: startFrame + index * 3
            ),
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: mergeKeys),
              startFrame: startFrame
            ),
            ExtraStyleTrack(
              property: .scale,
              kind: .keyframes(keys: scaleKeys),
              startFrame: startFrame
            ),
            extraStyleEnterExitOpacityTrack(start: startFrame, end: wordEndFrame, enterFrames: 6, exitFrames: 6),
          ]
        ))
        members.append("liquid-word-\(lineIndex)-\(index)")
      }

      // The deformable group: a slow stretch envelope plus a
      // loudness-driven surge (the whole line flows with the song).
      var groupScaleKeys: [ExtraStyleKeyframe] = []
      let groupMid = lineStartFrame + (lineEndFrame - lineStartFrame) / 2
      typographyAppendKeyframe(&groupScaleKeys, frame: lineStartFrame, value: 1, easing: .easeInOutSine)
      typographyAppendKeyframe(&groupScaleKeys, frame: groupMid, value: 1.05, easing: .easeInOutSine)
      typographyAppendKeyframe(&groupScaleKeys, frame: lineEndFrame, value: 1, easing: .easeInOutSine)
      builder.add(ExtraStyleNode(
        id: "liquid-group-\(lineIndex)", kind: .group,
        children: members,
        position: CGPoint(x: canvas.width / 2, y: centerY),
        anchor: .zero,
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .keyframes(keys: groupScaleKeys),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .reaction(input: .loudness, base: 0, gain: 12),
            startFrame: lineStartFrame
          ),
        ]
      ))

      // Ripple stroke under the line — the width of the lyric
      // line only (was full canvas width), in the line's tone
      // colour, bobbing on the same flow loop.
      let ripplePath: CGPath = {
        let path = CGMutablePath()
        let leftX = canvas.width / 2 - totalWidth / 2
        let rightX = canvas.width / 2 + totalWidth / 2
        var x: CGFloat = leftX
        var first = true
        while x <= rightX {
          let t = (x - leftX) / max(1, rightX - leftX)
          let y = centerY + sizePoints * 1.15 + sin(t * .pi * 4) * 8
          if first { path.move(to: CGPoint(x: x, y: y)); first = false }
          else { path.addLine(to: CGPoint(x: x, y: y)) }
          x += 16
        }
        return path
      }()
      builder.add(ExtraStyleNode(
        id: "liquid-ripple-\(lineIndex)", kind: .path,
        position: .zero, anchor: .zero, zIndex: 9,
        visibleRange: lineStartFrame...lineEndFrame,
        path: ExtraStylePathContent(
          path: ripplePath,
          strokeColor: toneColor.withAlpha(0.55),
          strokeWidth: 3,
          dash: nil
        ),
        tracks: [
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 60, periodParamId: "flowSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 30, value: -10, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 60, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame, enterFrames: 9, exitFrames: 9),
        ]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 8: Infinite Tunnel (typography)

final class InfiniteTunnelExtraStyle: ExtraStyleDefinition {
  let id = "infinite-tunnel"
  let version = 1
  let name = "Infinite Tunnel"
  let tagline = "Words fly toward you, one by one, out of the dark."
  let category = "typography"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "speed", label: "Flight speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Emphasis colour", default: "#C9F36B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "slow-dive", "label": "Slow dive", "values": ["speed": 0.6]],
      ["id": "warp", "label": "Warp", "values": ["speed": 1.8]],
    ]
  }

  var inputs: [String] { ["lines", "words", "audio", "intelligence"] }

  /// Flight speed re-times the fly-in at build time; no param
  /// changes the node count anymore.
  var rebuildParamIds: [String] { [] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    var builder = ExtraStyleSceneBuilder()

    // LYRIC-ONLY: no background, no concentric tunnel rings, no
    // centre glow. The tunnel is now a depth path for the words
    // themselves: each word flies toward the viewer — small/far
    // at its sung start, overshooting to full size, then
    // settling — with the beat/onset pulse on top.
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    let speed = max(0.25, min(2, extraStyleParamDouble(input.params, "speed", 1)))
    let flyFrames = max(8, min(28, Int((16 / speed).rounded())))
    let ink = ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0.9)
    let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)

    // Beat-confidence gate (the only fallback): a confident beat
    // grid pulses the text on beat phase; below 0.5 confidence
    // the onset envelope drives the same pulse instead.
    let useBeatPulse = (input.automation?.beatConfidence ?? 0) >= 0.5
      && !(input.automation?.beats.isEmpty ?? true)
    let pulseInput: ExtraStyleReactionInput = useBeatPulse ? .beatPhase : .onset

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.075
      let centerY = canvas.height * 0.5

      let wordNodes = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints,
        color: warmWhite,
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width
      ) { _, wordStart, wordEnd in
        var scaleKeys: [ExtraStyleKeyframe] = []
        let settleFrame = min(wordEnd, wordStart + flyFrames)
        typographyAppendKeyframe(&scaleKeys, frame: wordStart, value: 0.5, easing: .easeOutCubic)
        typographyAppendKeyframe(&scaleKeys, frame: settleFrame, value: 1.12, easing: .easeOutCubic)
        typographyAppendKeyframe(&scaleKeys, frame: min(wordEnd, settleFrame + 8), value: 1, easing: .easeInOutSine)
        return [
          ExtraStyleTrack(
            property: .scale,
            kind: .keyframes(keys: scaleKeys),
            startFrame: wordStart
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: pulseInput, base: 1, gain: 0.12),
            startFrame: wordStart
          ),
          extraStyleEnterExitOpacityTrack(start: wordStart, end: wordEnd, enterFrames: 6, exitFrames: 6),
        ]
      }
      if wordNodes.isEmpty {
        // No word timings: the whole line flies in as one.
        var scaleKeys: [ExtraStyleKeyframe] = []
        let settleFrame = min(lineEndFrame, lineStartFrame + flyFrames)
        typographyAppendKeyframe(&scaleKeys, frame: lineStartFrame, value: 0.5, easing: .easeOutCubic)
        typographyAppendKeyframe(&scaleKeys, frame: settleFrame, value: 1.12, easing: .easeOutCubic)
        typographyAppendKeyframe(&scaleKeys, frame: min(lineEndFrame, settleFrame + 8), value: 1, easing: .easeInOutSine)
        builder.add(extraStyleTextNode(
          id: "tunnel-line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
          color: warmWhite,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: ink, strokeWidthPoints: 2,
          tracks: [
            ExtraStyleTrack(
              property: .scale,
              kind: .keyframes(keys: scaleKeys),
              startFrame: lineStartFrame
            ),
            ExtraStyleTrack(
              property: .scale,
              kind: .reaction(input: pulseInput, base: 1, gain: 0.12),
              startFrame: lineStartFrame
            ),
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          ]
        ))
        continue
      }
      // Legibility + emphasis: every word gets a dark outline;
      // an emphasized word (stored intelligence) renders larger
      // and in the accent colour. The word index comes from the
      // node id ("word-<line>-<index>") because the helper skips
      // zero-length words, so array position is not the index.
      for wordNode in wordNodes {
        var node = wordNode
        node.text?.strokeColor = ink
        node.text?.strokeWidthPoints = 2
        let wordIndex = node.id.split(separator: "-").last.flatMap { Int($0) } ?? -1
        if line.emphasisWordIndices.contains(wordIndex) {
          node.text?.color = accent
          node.text?.colorParamId = "accent"
          if let size = node.text?.sizePoints { node.text?.sizePoints = size * 1.15 }
        }
        builder.add(node)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 9: Portal Typography (typography)

final class PortalTypographyExtraStyle: ExtraStyleDefinition {
  let id = "portal-typography"
  let version = 1
  let name = "Portal Typography"
  let tagline = "Words emerge through a small ring around the line."
  let category = "typography"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "accent", label: "Ring colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleToggleParam(id: "spin", label: "Orbit spin", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "grand", "label": "Grand", "values": ["spin": true]],
      ["id": "quiet", "label": "Quiet", "values": ["spin": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "phrases", "intelligence"] }

  /// The ring is sized from the measured lyric line at build
  /// time; no param changes the node count anymore.
  var rebuildParamIds: [String] { [] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#7DF9FF"))
    var builder = ExtraStyleSceneBuilder()

    // LYRIC-ONLY: no background, no full-frame tone glow, no
    // disc, no cross-frame word flight. The portal is now a
    // small ring accent hugging the lyric line: it springs open
    // at the line start, a dashed orbit ellipse turns around it,
    // and the words spring out of it at their sung starts.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let sizePoints = canvas.width * 0.058
      let centerY = canvas.height * 0.5
      let center = CGPoint(x: canvas.width / 2, y: centerY)
      let ink = ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0.9)
      let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)

      // Measured line width — the ring hugs the lyric line.
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
      let ringWidth = min(canvas.width * 0.92, lineWidth + sizePoints * 1.8)
      let ringHeight = sizePoints * 2.7

      // Ring + spark (group): spring open on the line start.
      // Members are group children (addChild) — they move/scale
      // with the ring and are evaluated exactly once.
      var members: [String] = []
      let ringId = "portal-ring-\(lineIndex)"
      builder.addChild(extraStyleShapeNode(
        id: ringId,
        shape: extraStyleEllipseShape(width: ringWidth, height: ringHeight),
        fill: nil,
        stroke: accent, strokeWidth: 4,
        position: .zero, zIndex: 1
      ))
      members.append(ringId)
      let sparkId = "portal-spark-\(lineIndex)"
      builder.addChild(ExtraStyleNode(
        id: sparkId, kind: .shape,
        position: CGPoint(x: ringWidth / 2 * 0.85, y: -ringHeight / 2 * 0.85),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 2,
        shape: ExtraStyleShapeContent(
          shape: extraStyleStarShape(outerRadius: 14, innerRadius: 6, spikes: 4),
          fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
          stroke: nil, strokeWidth: 0
        ),
        tracks: [extraStyleSpringInTrack(start: lineStartFrame + 4, from: 0.2, stiffness: 200, damping: 9)]
      ))
      members.append(sparkId)
      builder.add(ExtraStyleNode(
        id: "portal-\(lineIndex)", kind: .group,
        children: members,
        position: center, anchor: .zero,
        zIndex: 5,
        visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          extraStyleSpringInTrack(start: lineStartFrame, from: 0.2, stiffness: 140, damping: 11),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
        ]
      ))

      // Dashed orbit ellipse around the ring, rotating on a loop.
      // The path lives in positive local space so the anchor
      // centres it on the line and the rotation pivots there.
      let orbitPath: CGPath = {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 0, y: 0, width: ringWidth * 1.1, height: ringHeight * 1.45))
        return path
      }()
      builder.add(ExtraStyleNode(
        id: "portal-orbit-\(lineIndex)", kind: .path,
        position: center, anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 6,
        visibleRange: lineStartFrame...lineEndFrame,
        path: ExtraStylePathContent(
          path: orbitPath,
          strokeColor: accent.withAlpha(0.8),
          strokeWidth: 3,
          dash: [16, 12]
        ),
        tracks: [
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .loop(periodFrames: 360, periodParamId: nil, keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: 360, value: 360, easing: .linear),
            ]),
            startFrame: lineStartFrame,
            enabledParamId: "spin"
          ),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
        ]
      ))

      // The line's stored emoji, when it has one, rides at the
      // line's end, small (unconditional helper — nil only when
      // the line genuinely has no stored emoji).
      if let hero = extraStyleEmojiNode(
        id: "portal-emoji-\(lineIndex)", line: line,
        position: CGPoint(
          x: min(canvas.width * 0.94, center.x + ringWidth / 2 + sizePoints * 0.8),
          y: centerY
        ),
        sizePoints: sizePoints * 0.9, zIndex: 7,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        builder.add(hero)
      }

      // Words emerge through the ring: spring in from small at
      // their sung start and settle on the line.
      let wordNodes = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints,
        color: warmWhite,
        font: ExtraStyleFonts.bold, zIndex: 10, canvasWidth: canvas.width
      ) { _, wordStart, wordEnd in
        [
          extraStyleSpringInTrack(start: wordStart, from: 0.35, stiffness: 160, damping: 11),
          extraStyleEnterExitOpacityTrack(start: wordStart, end: wordEnd, enterFrames: 4, exitFrames: 4),
        ]
      }
      if wordNodes.isEmpty {
        builder.add(extraStyleTextNode(
          id: "portal-line-\(lineIndex)",
          text: line.text, font: ExtraStyleFonts.bold, sizePoints: sizePoints,
          color: warmWhite,
          position: center,
          zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          strokeColor: ink, strokeWidthPoints: 2,
          tracks: [
            extraStyleSpringInTrack(start: lineStartFrame, from: 0.35, stiffness: 160, damping: 11),
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
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
          node.text?.color = accent
          node.text?.colorParamId = "accent"
          if let size = node.text?.sizePoints { node.text?.sizePoints = size * 1.15 }
        }
        builder.add(node)
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 10: Typography Explosion (typography)

final class TypographyExplosionExtraStyle: ExtraStyleDefinition {
  let id = "typography-explosion"
  let version = 1
  let name = "Typography Explosion"
  let tagline = "Letters blow apart on the accent — then snap back."
  let category = "typography"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "force", label: "Blast force", min: 0.5, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleNumberParam(
        id: "shards", label: "Shards", min: 0, max: 16, step: 1,
        default: 8, affects: "layout"
      ),
      extraStyleColorParam(id: "accent", label: "Blast colour", default: "#FF6B4A", affects: "appearance"),
      extraStyleToggleParam(id: "onsetPulse", label: "Pulse on the beat", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "firecracker", "label": "Firecracker", "values": ["force": 1.6, "shards": 14]],
      ["id": "pop", "label": "Pop", "values": ["force": 0.7, "shards": 4]],
    ]
  }

  var inputs: [String] { ["lines", "audio", "intelligence"] }

  /// Blast distance and shard count are baked into keyframes/nodes.
  var rebuildParamIds: [String] { ["force", "shards"] }

  /// The line's strongest onset accent (the normalised onset
  /// envelope, 0...1, peaks inside the line window). Below 0.35
  /// the envelope is effectively flat, so the explosion falls
  /// back to a fixed point just after the line starts — the
  /// keyframed envelope still plays either way.
  private func accentFrame(
    line: ExtraStyleInputLine, lineStartFrame: Int, lineEndFrame: Int, fps: Double,
    automation: ExtraStyleAutomationData?
  ) -> Int {
    let fallback = min(lineStartFrame + 8, max(lineStartFrame + 1, lineEndFrame - 6))
    guard let automation, !automation.onsetValues.isEmpty,
      automation.onsetHopSeconds > 0
    else { return fallback }
    let hop = automation.onsetHopSeconds
    var bestFrame = fallback
    var bestValue = 0.0
    var i = max(0, Int((line.startSeconds / hop).rounded()))
    let endIndex = min(automation.onsetValues.count - 1, Int((line.endSeconds / hop).rounded()))
    while i <= endIndex {
      let value = automation.onsetValues[i]
      let frame = Int((Double(i) * hop * fps).rounded())
      if value > bestValue, frame > lineStartFrame, frame < lineEndFrame - 6 {
        bestValue = value
        bestFrame = frame
      }
      i += 1
    }
    return bestValue >= 0.35 ? bestFrame : fallback
  }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let force = extraStyleParamDouble(input.params, "force", 1)
    let shardCount = max(0, min(16, Int(extraStyleParamDouble(input.params, "shards", 8).rounded())))
    var builder = ExtraStyleSceneBuilder()

    // LYRIC-ONLY: no background wash. The explosion is the
    // letters themselves, plus small shards bursting from the
    // line and fading — debris attached to the words, not a
    // full-screen effect.

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    let sizePoints = canvas.width * 0.08
    let centerY = canvas.height * 0.5
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let toneColor = extraStyleToneColor(line.tone)
      let trigger = accentFrame(
        line: line, lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame, fps: fps,
        automation: input.automation
      )
      let onsetAtTrigger = input.automation?.onset(at: Double(trigger) / fps) ?? 0.5

      // Which character indices belong to emphasized words
      // (stored intelligence): those letters fly 1.4× further.
      // Words are found in order in the line text, so the
      // mapping survives repeated words.
      let emphasisCharIndices: Set<Int> = {
        var indices = Set<Int>()
        let chars = Array(line.text)
        var cursor = 0
        for (wordIndex, word) in line.words.enumerated()
        where line.emphasisWordIndices.contains(wordIndex) {
          let wordChars = Array(word.text)
          guard !wordChars.isEmpty else { continue }
          var found: Int? = nil
          var i = cursor
          while i + wordChars.count <= chars.count {
            if Array(chars[i..<(i + wordChars.count)]) == wordChars { found = i; break }
            i += 1
          }
          if let start = found {
            for j in start..<(start + wordChars.count) { indices.insert(j) }
            cursor = start + wordChars.count
          }
        }
        return indices
      }()

      // Per-character explosion: each char flies out on a seeded
      // radial velocity from the accent frame (staggered 2 frames
      // apart), then springs back to its reading position. The
      // flight is baked keyframes (see the file helper); the
      // onset envelope modulates the scale gain on top via a
      // reaction track — the explosion still plays on its
      // keyframed envelope when the onset value is 0.
      let chars = extraStyleCharNodes(
        text: line.text, lineIndex: lineIndex,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: centerY, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        font: ExtraStyleFonts.black, zIndex: 10, canvasWidth: canvas.width,
        charDelayFrames: 2,
        colorParamId: "accent"
      ) { index, charStartFrame, lineEnd in
        var random = ExtraStyleSeededRandom(seed: input.seed
          ^ (UInt64(lineIndex + 1) &* 0x9e37_79b9_7f4a_7c15)
          ^ (UInt64(index + 1) &* 0xbf58_476d_1ce4_e5b9))
        let angle = random.nextRange(min: 0, max: 2 * Double.pi)
        let distance = (70 + random.nextDouble() * 130) * force * (0.7 + 0.3 * onsetAtTrigger)
          * (emphasisCharIndices.contains(index) ? 1.4 : 1)
        let dx = cos(angle) * distance
        let dy = sin(angle) * distance * 0.8
        let rotation = random.nextRange(min: -42, max: 42)
        let charTrigger = min(trigger + index * 2, max(lineStartFrame + 2, lineEndFrame - 14))
        return [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: typographyExplosionOffsetKeys(
              lineStart: charStartFrame, trigger: charTrigger, end: lineEnd, offset: dx, fps: fps
            )),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: typographyExplosionOffsetKeys(
              lineStart: charStartFrame, trigger: charTrigger, end: lineEnd, offset: dy, fps: fps
            )),
            startFrame: charStartFrame
          ),
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .keyframes(keys: typographyExplosionOffsetKeys(
              lineStart: charStartFrame, trigger: charTrigger, end: lineEnd, offset: rotation, fps: fps
            )),
            startFrame: charStartFrame
          ),
          extraStyleEnterExitOpacityTrack(start: charStartFrame, end: lineEnd),
          extraStyleSpringInTrack(start: charStartFrame, from: 0.5, stiffness: 160, damping: 12),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.22),
            startFrame: charStartFrame,
            enabledParamId: "onsetPulse"
          ),
        ]
      }
      for char in chars {
        var stroked = char
        stroked.text?.strokeColor = ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 0.9)
        stroked.text?.strokeWidthPoints = 2
        builder.add(stroked)
      }

      // Shards: small procedural triangles that burst from the
      // line centre at the same accent frame, spin, and fade.
      // Kept close to the line (short flight, small size) so
      // they read as debris from the words, not scenery.
      let shardEnd = min(lineEndFrame, trigger + 52)
      for shard in 0..<shardCount {
        var random = ExtraStyleSeededRandom(seed: input.seed
          ^ (UInt64(lineIndex + 1) &* 0x9e37_79b9_7f4a_7c15)
          ^ (UInt64(shard + 1) &* 0x94d0_49bb_1331_11eb))
        let angle = random.nextRange(min: 0, max: 2 * Double.pi)
        let distance = (60 + random.nextDouble() * 90) * force * (0.7 + 0.3 * onsetAtTrigger)
        let dx = cos(angle) * distance
        let dy = sin(angle) * distance * 0.8
        let spin = random.nextRange(min: -260, max: 260)
        let shardSize = CGFloat(12 + random.nextDouble() * 10)
        let shardId = "shard-\(lineIndex)-\(shard)"
        var opacityKeys: [ExtraStyleKeyframe] = []
        typographyAppendKeyframe(&opacityKeys, frame: trigger, value: 0, easing: .linear)
        typographyAppendKeyframe(&opacityKeys, frame: min(shardEnd, trigger + 3), value: 1, easing: .easeOutCubic)
        typographyAppendKeyframe(&opacityKeys, frame: min(shardEnd, trigger + 34), value: 1, easing: .linear)
        typographyAppendKeyframe(&opacityKeys, frame: shardEnd, value: 0, easing: .easeInCubic)
        builder.add(ExtraStyleNode(
          id: shardId, kind: .shape,
          position: CGPoint(x: canvas.width / 2, y: centerY),
          anchor: CGPoint(x: 0.5, y: 0.5),
          zIndex: 9,
          visibleRange: trigger...shardEnd,
          shape: ExtraStyleShapeContent(
            shape: .path(typographyShardPath(size: shardSize)),
            fill: toneColor,
            stroke: nil, strokeWidth: 0
          ),
          tracks: [
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: typographyExplosionOffsetKeys(
                lineStart: trigger, trigger: trigger, end: shardEnd, offset: dx, fps: fps
              )),
              startFrame: trigger
            ),
            ExtraStyleTrack(
              property: .positionY,
              kind: .keyframes(keys: typographyExplosionOffsetKeys(
                lineStart: trigger, trigger: trigger, end: shardEnd, offset: dy, fps: fps
              )),
              startFrame: trigger
            ),
            ExtraStyleTrack(
              property: .rotationDeg,
              kind: .keyframes(keys: typographyExplosionOffsetKeys(
                lineStart: trigger, trigger: trigger, end: shardEnd, offset: spin, fps: fps
              )),
              startFrame: trigger
            ),
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: opacityKeys),
              startFrame: trigger
            ),
          ]
        ))
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (Typography rest)

extension ExtraStylesPhase3 {
  static func registerTypographyRest(into registry: ExtraStyleRegistry) {
    registry.register(LiquidLettersExtraStyle())
    registry.register(InfiniteTunnelExtraStyle())
    registry.register(PortalTypographyExtraStyle())
    registry.register(TypographyExplosionExtraStyle())
  }
}
