import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3, Experimental family, part A
//
// Styles 31–35 (docs/EXTRA-STYLES-2.0.md §17):
//   31 Glitch Reality — 32 Surveillance System — 33 Newspaper Explosion
//   34 VHS Dream — 35 Optical Illusion
//
// Flags match the authoritative TS static map
// (src/lib/extra-styles/catalog.ts STYLE_CAPABILITY_MAP) exactly:
// glitch-reality needsAudioAutomation = true (automation WILL be
// supplied; break-apart bursts are driven from the onset envelope
// directly — the only fallback is the beat-confidence gate when
// beatPhase is used, never a missing-automation case);
// surveillance-system needsSubjectMasks = true; the other three
// need neither input.
//
// Displacement notes (§17 Metal-spike candidates): Glitch Reality
// and VHS Dream use the engine's displacement nodes
// (ExtraStyleDisplacementContent, Core Image CIDisplacementDistortion
// path). A per-node Metal displacement shader is a Phase 2 spike
// candidate (adopt only on a measured >= 2x win); NO Metal work is
// attempted here.

// MARK: - Shared helpers (this file only)

/// Seeded position jitter keyframes: one key every `stepFrames`
/// frames, values in [-amplitude, +amplitude]. Deterministic.
private func experimentalJitterKeys(
  start: Int, end: Int, stepFrames: Int, amplitude: Double, seed: UInt64
) -> [ExtraStyleKeyframe] {
  var random = ExtraStyleSeededRandom(seed: seed)
  var keys: [ExtraStyleKeyframe] = []
  var frame = start
  while frame <= end {
    keys.append(ExtraStyleKeyframe(
      frame: frame, value: random.nextRange(min: -amplitude, max: amplitude),
      easing: .linear))
    frame += max(1, stepFrames)
  }
  if keys.isEmpty {
    keys.append(ExtraStyleKeyframe(frame: start, value: 0, easing: .linear))
  }
  return keys
}

/// "MM:SS" timecode for a seconds value.
private func experimentalTimecode(_ seconds: Double) -> String {
  let total = max(0, Int(seconds.rounded()))
  return String(format: "%02d:%02d", total / 60, total % 60)
}

/// "H:MM:SS" timecode for a seconds value (VHS tape counter).
private func experimentalTapeTimecode(_ seconds: Double) -> String {
  let total = max(0, Int(seconds.rounded()))
  return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}

// MARK: - Style 31: Glitch Reality (experimental)

final class GlitchRealityExtraStyle: ExtraStyleDefinition {
  let id = "glitch-reality"
  let version = 1
  let name = "Glitch Reality"
  let tagline = "The signal breaks apart on the accent — then rebuilds."
  let category = "experimental"
  let needsAudioAutomation = true
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "glitchIntensity", label: "Glitch intensity", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "motion"
      ),
      extraStyleNumberParam(
        id: "fragmentCount", label: "Fragment copies", min: 2, max: 6, step: 1,
        default: 4, affects: "layout"
      ),
      extraStyleSegmentedParam(
        id: "breakMode", label: "Break apart",
        options: [("bands", "Bands"), ("shards", "Shards"), ("both", "Both")],
        default: "both", affects: "layout"
      ),
      extraStyleColorParam(id: "accent", label: "Glitch colour", default: "#00F0FF", affects: "appearance"),
      extraStyleToggleParam(id: "displacement", label: "Displacement wave", default: true, affects: "motion"),
      extraStyleToggleParam(id: "onsetBreak", label: "Break on the accent", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "subtle", "label": "Subtle", "values": ["glitchIntensity": 0.35, "fragmentCount": 2, "breakMode": "bands"]],
      ["id": "total", "label": "Total breakdown", "values": ["glitchIntensity": 1, "fragmentCount": 6, "breakMode": "both"]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  var rebuildParamIds: [String] { ["glitchIntensity", "fragmentCount", "breakMode", "displacement"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let intensity = extraStyleParamDouble(input.params, "glitchIntensity", 0.7)
    let fragmentCount = max(2, min(6, Int(extraStyleParamDouble(input.params, "fragmentCount", 4))))
    let breakMode = extraStyleParamString(input.params, "breakMode", "both")
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#00F0FF"))
    let magenta = ExtraStyleRGBA(r: 1, g: 0.18, b: 0.39, a: 1)
    let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "glitch-background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.04, g: 0.02, b: 0.07, a: 1),
        ExtraStyleRGBA(r: 0.01, g: 0.01, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Full-frame displacement wave (Core Image path). A Metal
    // displacement shader is the documented spike candidate for
    // this node — see the file header; not attempted here.
    // The scale track re-times the wave on the onset envelope.
    if extraStyleParamBool(input.params, "displacement", true) {
      builder.add(ExtraStyleNode(
        id: "glitch-displacement", kind: .displacement,
        displacement: ExtraStyleDisplacementContent(
          baseScale: 10 + 30 * intensity, frequency: 4),
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.9),
            startFrame: 0,
            enabledParamId: "onsetBreak"
          ),
        ]
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centerY = canvas.height * 0.5
      let sizePoints = canvas.width * 0.075

      // The main line: seeded jitter + a small onset pop.
      builder.add(extraStyleTextNode(
        id: "glitch-line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.black, sizePoints: sizePoints,
        color: warmWhite,
        position: CGPoint(x: canvas.width / 2, y: centerY),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: experimentalJitterKeys(
              start: lineStartFrame, end: lineEndFrame, stepFrames: 5,
              amplitude: 10 * intensity, seed: input.seed ^ UInt64(lineIndex + 1))),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 1, gain: 0.08),
            startFrame: lineStartFrame,
            enabledParamId: "onsetBreak"
          ),
        ]
      ))

      // Fragmented text copies: RGB-split layers, each moving on
      // its own seeded offset, in screen blend so they tint
      // rather than cover the main line.
      for fragment in 0..<fragmentCount {
        var fragmentRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 31 + fragment * 7 + 11))
        let dx = fragmentRandom.nextRange(min: -26, max: 26) * intensity
        let dy = fragmentRandom.nextRange(min: -14, max: 14) * intensity
        let copyColor = fragment % 2 == 0 ? accent.withAlpha(0.6) : magenta.withAlpha(0.6)
        builder.add(ExtraStyleNode(
          id: "glitch-frag-\(lineIndex)-\(fragment)", kind: .text,
          position: CGPoint(x: canvas.width / 2 + CGFloat(dx), y: centerY + CGFloat(dy)),
          anchor: CGPoint(x: 0.5, y: 0.5),
          opacity: 0.6,
          zIndex: 11,
          blendMode: .screen,
          visibleRange: lineStartFrame...lineEndFrame,
          text: ExtraStyleTextContent(
            text: line.text,
            fontPostScriptName: ExtraStyleFonts.black,
            sizePoints: sizePoints,
            color: copyColor,
            colorParamId: fragment % 2 == 0 ? "accent" : nil,
            strokeColor: nil,
            strokeWidthPoints: 0,
            alignment: .center,
            maxWidthPoints: canvas.width * 0.88
          ),
          tracks: [
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: experimentalJitterKeys(
                start: lineStartFrame, end: lineEndFrame, stepFrames: 4,
                amplitude: 18 * intensity,
                seed: input.seed ^ UInt64(lineIndex * 31 + fragment * 7 + 101))),
              startFrame: lineStartFrame
            ),
            extraStyleFlickerTrack(
              start: lineStartFrame, end: lineEndFrame, base: 0.6, amplitude: 0.4,
              seed: input.seed ^ UInt64(lineIndex * 31 + fragment * 7 + 202), stepFrames: 3),
          ]
        ))
      }

      // Break-apart mask bands: full-width slices that jump on the
      // onset envelope (reaction positionY) and flicker.
      if breakMode != "shards" {
        for band in 0..<3 {
          var bandRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 17 + band * 5 + 31))
          let bandY = centerY + CGFloat(bandRandom.nextRange(min: -0.14, max: 0.14)) * canvas.height
          let bandHeight = CGFloat(bandRandom.nextRange(min: 10, max: 28))
          let bandColor: ExtraStyleRGBA = {
            switch band {
            case 0: return accent.withAlpha(0.5)
            case 1: return magenta.withAlpha(0.5)
            default: return warmWhite.withAlpha(0.4)
            }
          }()
          builder.add(extraStyleShapeNode(
            id: "glitch-band-\(lineIndex)-\(band)",
            shape: extraStyleRectShape(width: canvas.width, height: bandHeight),
            fill: bandColor,
            position: CGPoint(x: canvas.width / 2, y: bandY),
            zIndex: 12,
            visibleRange: lineStartFrame...lineEndFrame,
            blendMode: .screen,
            tracks: [
              ExtraStyleTrack(
                property: .positionY,
                kind: .reaction(input: .onset, base: 0, gain: 30),
                startFrame: lineStartFrame,
                enabledParamId: "onsetBreak"
              ),
              extraStyleFlickerTrack(
                start: lineStartFrame, end: lineEndFrame, base: 0.7, amplitude: 0.3,
                seed: input.seed ^ UInt64(lineIndex * 17 + band * 5 + 303), stepFrames: 4),
            ]
          ))
        }
      }

      // Onset burst: a star that flashes (scale + opacity) on
      // accents and is invisible between them (reaction base 0).
      // Beat phase is the stronger signal when the beat grid is
      // confident; beatPhase(at:) returns nil below 0.5
      // confidence, so the onset reaction above is the fallback
      // that always fires.
      let burstSize = canvas.width * 0.3
      builder.add(ExtraStyleNode(
        id: "glitch-burst-\(lineIndex)", kind: .shape,
        position: CGPoint(x: canvas.width / 2, y: centerY),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 13,
        blendMode: .screen,
        visibleRange: lineStartFrame...lineEndFrame,
        shape: ExtraStyleShapeContent(
          shape: extraStyleStarShape(
            outerRadius: burstSize / 2, innerRadius: burstSize / 6, spikes: 8),
          fill: accent.withAlpha(0.8),
          fillColorParamId: "accent",
          stroke: nil, strokeWidth: 0
        ),
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .reaction(input: .onset, base: 0, gain: 1.2),
            startFrame: lineStartFrame,
            enabledParamId: "onsetBreak"
          ),
          ExtraStyleTrack(
            property: .opacity,
            kind: .reaction(input: .onset, base: 0, gain: 1),
            startFrame: lineStartFrame,
            enabledParamId: "onsetBreak"
          ),
        ]
      ))

      // Shard echoes: the words scattered radially from their
      // reading position at the word start, settling back — the
      // break-apart half of the row, shown below the main line so
      // it never covers it.
      if breakMode != "bands" {
        let shards = extraStyleWordNodes(
          line: line, lineIndex: lineIndex, fps: fps,
          lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
          y: canvas.height * 0.68, sizePoints: canvas.width * 0.045,
          color: accent, font: ExtraStyleFonts.black, zIndex: 9,
          canvasWidth: canvas.width,
          colorParamId: "accent"
        ) { index, wordStartFrame, wordEndFrame in
          var shardRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 1000 + index * 17 + 3))
          let angle = shardRandom.nextDouble() * 2 * Double.pi
          let distance = shardRandom.nextRange(min: 40, max: 140) * intensity
          let dx = cos(angle) * distance
          let dy = sin(angle) * distance * 0.6
          let settleFrame = min(wordEndFrame, wordStartFrame + 12)
          let scatterFrame = max(wordStartFrame, wordEndFrame - 12)
          return [
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: wordStartFrame, value: dx, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: scatterFrame, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: wordEndFrame, value: dx * 0.7, easing: .easeInCubic),
              ]),
              startFrame: wordStartFrame
            ),
            ExtraStyleTrack(
              property: .positionY,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: wordStartFrame, value: dy, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: scatterFrame, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: wordEndFrame, value: dy * 0.7, easing: .easeInCubic),
              ]),
              startFrame: wordStartFrame
            ),
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: wordStartFrame, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 4), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: wordEndFrame, value: 0, easing: .linear),
              ]),
              startFrame: wordStartFrame
            ),
          ]
        }
        for shard in shards { builder.add(shard) }
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 32: Surveillance System (experimental)

final class SurveillanceSystemExtraStyle: ExtraStyleDefinition {
  let id = "surveillance-system"
  let version = 1
  let name = "Surveillance System"
  let tagline = "Target locked. Every move tracked, every second stamped."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = true
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleColorParam(id: "hudColor", label: "HUD colour", default: "#7DF9FF", affects: "appearance"),
      extraStyleSliderParam(
        id: "lockPulse", label: "Lock-ring pulse", min: 0.5, max: 1.5, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleToggleParam(id: "showTimestamp", label: "Timestamp", default: true, affects: "motion"),
      extraStyleSliderParam(
        id: "scanSpeed", label: "Scan speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleSegmentedParam(
        id: "targetLabel", label: "Target label",
        options: [("subject", "Subject"), ("target", "Target"), ("person", "Person")],
        default: "subject", affects: "layout"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "stealth", "label": "Stealth", "values": ["hudColor": "#C9F36B", "lockPulse": 0.7, "scanSpeed": 0.5]],
      ["id": "alert", "label": "Alert", "values": ["hudColor": "#FF5C5C", "lockPulse": 1.4, "scanSpeed": 1.6]],
    ]
  }

  var inputs: [String] { ["lines", "subject"] }

  var rebuildParamIds: [String] { ["targetLabel"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let hud = extraStyleColor(extraStyleParamString(input.params, "hudColor", "#7DF9FF"))
    let red = ExtraStyleRGBA(r: 1, g: 0.3, b: 0.3, a: 1)
    let targetLabel = extraStyleParamString(input.params, "targetLabel", "subject").uppercased()
    let durationSeconds = Double(input.durationFrames) / fps
    var builder = ExtraStyleSceneBuilder()

    // Top-left REC marker + camera id (static HUD chrome).
    builder.add(extraStyleTextNode(
      id: "surv-rec",
      text: "● REC", font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.032,
      color: red,
      position: CGPoint(x: canvas.width * 0.1, y: canvas.height * 0.055),
      zIndex: 20
    ))
    builder.add(extraStyleTextNode(
      id: "surv-cam",
      text: "CAM 01", font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
      color: hud,
      position: CGPoint(x: canvas.width * 0.24, y: canvas.height * 0.055),
      zIndex: 20,
      colorParamId: "hudColor"
    ))

    // Ticking timestamp (top-right): one text node per second —
    // text content is baked at build time, so a counter is a set
    // of prebuilt nodes with visible ranges.
    if extraStyleParamBool(input.params, "showTimestamp", true) {
      let steps = max(1, min(180, Int(durationSeconds.rounded())))
      for stamp in extraStyleCounterNodes(
        idPrefix: "surv-timestamp", from: 0, to: durationSeconds, steps: steps,
        startFrame: 0, endFrame: input.durationFrames,
        position: CGPoint(x: canvas.width * 0.84, y: canvas.height * 0.055),
        sizePoints: canvas.width * 0.03, color: hud,
        font: ExtraStyleFonts.mono, zIndex: 20,
        format: { "REC " + experimentalTimecode($0) }
      ) { builder.add(stamp) }
    }

    // Scan sweep: a bright bar travelling top → bottom on a loop.
    builder.add(ExtraStyleNode(
      id: "surv-sweep", kind: .shape,
      position: CGPoint(x: canvas.width / 2, y: 0),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 2,
      shape: ExtraStyleShapeContent(
        shape: extraStyleRectShape(width: canvas.width, height: 10),
        fill: hud.withAlpha(0.18),
        fillColorParamId: "hudColor",
        stroke: nil, strokeWidth: 0
      ),
      tracks: [
        ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 240, periodParamId: "scanSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: 240, value: Double(canvas.height), easing: .linear),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // ---- The tracking box ----
    // The group sits at (0, 0); extraStyleFaceBoxTracks carries
    // ABSOLUTE canvas points for the face-box centre, so the box
    // follows the subject. The mask index is 2 fps nearest-sample,
    // so the box holds between samples — the documented behaviour.
    // When a time has no face box at all, the box falls back to a
    // centre patrol loop instead of freezing off-frame.
    // LIMITATION (engine as-is): the box size is fixed — there is
    // no track that resizes a node from the face-box size, so a
    // near/far subject is framed by the same box.
    let boxWidth = canvas.width * 0.34
    let boxHeight = canvas.height * 0.19
    let faceTracks = extraStyleFaceBoxTracks(
      input.maskIndex, fps: fps, canvas: canvas,
      startFrame: 0, endFrame: input.durationFrames)
    var boxTracks: [ExtraStyleTrack]
    if !faceTracks.isEmpty {
      boxTracks = faceTracks
    } else {
      // Centre patrol: slow figure-eight-ish drift on loops.
      boxTracks = [
        ExtraStyleTrack(
          property: .positionX,
          kind: .loop(periodFrames: 300, periodParamId: "scanSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: Double(canvas.width * 0.35), easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 150, value: Double(canvas.width * 0.65), easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 300, value: Double(canvas.width * 0.35), easing: .easeInOutSine),
          ]),
          startFrame: 0
        ),
        ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 300, periodParamId: "scanSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: Double(canvas.height * 0.38), easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 150, value: Double(canvas.height * 0.52), easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 300, value: Double(canvas.height * 0.38), easing: .easeInOutSine),
          ]),
          startFrame: 0
        ),
      ]
    }
    // Lock-on scale + opacity: the box breathes gently and
    // flickers with seeded noise while locked. (lockPulse scales
    // the lock RING only — scaling the whole box would shrink the
    // tracking frame itself.)
    boxTracks.append(ExtraStyleTrack(
      property: .scale,
      kind: .loop(periodFrames: 90, periodParamId: nil, keys: [
        ExtraStyleKeyframe(frame: 0, value: 1, easing: .easeInOutSine),
        ExtraStyleKeyframe(frame: 45, value: 1.04, easing: .easeInOutSine),
        ExtraStyleKeyframe(frame: 90, value: 1, easing: .easeInOutSine),
      ]),
      startFrame: 0
    ))
    boxTracks.append(extraStyleFlickerTrack(
      start: 0, end: input.durationFrames, base: 0.95, amplitude: 0.08,
      seed: input.seed ^ 0x5355_5256_0001, stepFrames: 6))

    // Group members are registered first (addChild), then the
    // group (add) — children move with the box, evaluated once.
    builder.addChild(extraStyleShapeNode(
      id: "surv-box-border",
      shape: extraStyleRectShape(width: boxWidth, height: boxHeight),
      fill: nil,
      stroke: hud, strokeWidth: 3,
      position: .zero, zIndex: 0
    ))
    // Corner marks: L-shaped paths at the four box corners.
    let cornerLength = canvas.width * 0.05
    let halfW = boxWidth / 2
    let halfH = boxHeight / 2
    let corners: [(String, CGPoint, CGFloat, CGFloat)] = [
      ("tl", CGPoint(x: -halfW, y: -halfH), 1, 1),
      ("tr", CGPoint(x: halfW, y: -halfH), -1, 1),
      ("bl", CGPoint(x: -halfW, y: halfH), 1, -1),
      ("br", CGPoint(x: halfW, y: halfH), -1, -1),
    ]
    for (cornerName, corner, sx, sy) in corners {
      let path = CGMutablePath()
      path.move(to: CGPoint(x: corner.x + sx * cornerLength, y: corner.y))
      path.addLine(to: corner)
      path.addLine(to: CGPoint(x: corner.x, y: corner.y + sy * cornerLength))
      builder.addChild(ExtraStyleNode(
        id: "surv-corner-\(cornerName)", kind: .path,
        position: .zero, anchor: .zero, zIndex: 1,
        path: ExtraStylePathContent(
          path: path, strokeColor: hud, strokeWidth: 5, dash: nil)
      ))
    }
    // Crosshair through the box centre.
    builder.addChild(extraStyleShapeNode(
      id: "surv-cross-h",
      shape: extraStyleRectShape(width: boxWidth, height: 2),
      fill: hud.withAlpha(0.35),
      position: .zero, zIndex: 1
    ))
    builder.addChild(extraStyleShapeNode(
      id: "surv-cross-v",
      shape: extraStyleRectShape(width: 2, height: boxHeight),
      fill: hud.withAlpha(0.35),
      position: .zero, zIndex: 1
    ))
    // Target-lock ring around the box, pulsing on its own loop.
    builder.addChild(ExtraStyleNode(
      id: "surv-lock-ring", kind: .shape,
      position: .zero, anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 2,
      shape: ExtraStyleShapeContent(
        shape: extraStyleEllipseShape(width: boxWidth * 1.3, height: boxHeight * 1.3),
        fill: nil,
        stroke: hud, strokeWidth: 2
      ),
      tracks: [
        ExtraStyleTrack(
          property: .scale,
          kind: .loop(periodFrames: 90, periodParamId: nil, keys: [
            ExtraStyleKeyframe(frame: 0, value: 1, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 45, value: 1.12, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 90, value: 1, easing: .easeInOutSine),
          ]),
          startFrame: 0,
          paramScale: "lockPulse"
        ),
      ]
    ))
    // Subject tint: the HUD colour clipped to the person mask, so
    // the highlight follows the subject's silhouette, not the box.
    builder.addChild(extraStyleShapeNode(
      id: "surv-subject-tint",
      shape: extraStyleRectShape(width: boxWidth, height: boxHeight),
      fill: hud.withAlpha(0.12),
      position: .zero, zIndex: 1,
      mask: .subject(invert: false)
    ))
    // Label above the box — updates per line below via the
    // caption; the box label itself is the lock state.
    builder.addChild(extraStyleTextNode(
      id: "surv-label",
      text: "\(targetLabel) LOCKED", font: ExtraStyleFonts.mono,
      sizePoints: canvas.width * 0.026, color: hud,
      position: CGPoint(x: 0, y: -halfH - 28),
      zIndex: 3,
      colorParamId: "hudColor"
    ))
    builder.addChild(extraStyleTextNode(
      id: "surv-sublabel",
      text: "TRACKING • 30FPS", font: ExtraStyleFonts.mono,
      sizePoints: canvas.width * 0.022, color: hud.withAlpha(0.8),
      position: CGPoint(x: 0, y: halfH + 28),
      zIndex: 3,
      colorParamId: "hudColor"
    ))
    builder.add(ExtraStyleNode(
      id: "surv-track", kind: .group,
      children: [
        "surv-box-border",
        "surv-corner-tl", "surv-corner-tr", "surv-corner-bl", "surv-corner-br",
        "surv-cross-h", "surv-cross-v", "surv-lock-ring",
        "surv-subject-tint", "surv-label", "surv-sublabel",
      ],
      position: .zero, anchor: .zero,
      zIndex: 20,
      tracks: boxTracks
    ))

    // Transcript captions: the active line as a HUD readout at
    // the bottom, with a static header above it.
    builder.add(extraStyleTextNode(
      id: "surv-transcript-header",
      text: "— TRANSCRIPT —", font: ExtraStyleFonts.mono,
      sizePoints: canvas.width * 0.024, color: hud.withAlpha(0.7),
      position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.82),
      zIndex: 20,
      colorParamId: "hudColor"
    ))
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      builder.add(extraStyleTextNode(
        id: "surv-caption-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.038,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.87),
        zIndex: 21, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 33: Newspaper Explosion (experimental)

final class NewspaperExplosionExtraStyle: ExtraStyleDefinition {
  let id = "newspaper-explosion"
  let version = 1
  let name = "Newspaper Explosion"
  let tagline = "Hot off the press — headlines that burst off the page."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "headlineScale", label: "Headline scale", min: 0.8, max: 1.6, step: 0.05,
        default: 1.1, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "scatter", label: "Scatter", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "motion"
      ),
      extraStyleSegmentedParam(
        id: "columns", label: "Columns",
        options: [("two", "2 columns"), ("three", "3 columns")],
        default: "two", affects: "layout"
      ),
      extraStyleColorParam(id: "paperColor", label: "Paper colour", default: "#F4F1E9", affects: "appearance"),
      extraStyleColorParam(id: "inkColor", label: "Ink colour", default: "#101114", affects: "appearance"),
      extraStyleToggleParam(id: "showRules", label: "Rule lines", default: true, affects: "motion"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "broadsheet", "label": "Broadsheet", "values": ["columns": "two", "scatter": 0.5, "headlineScale": 1.2]],
      ["id": "tabloid", "label": "Tabloid", "values": ["columns": "three", "scatter": 1, "headlineScale": 1.4]],
    ]
  }

  var inputs: [String] { ["lines", "words"] }

  var rebuildParamIds: [String] { ["scatter", "columns"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let scatter = extraStyleParamDouble(input.params, "scatter", 0.7)
    let columnCount = extraStyleParamString(input.params, "columns", "two") == "three" ? 3 : 2
    let paper = extraStyleColor(extraStyleParamString(input.params, "paperColor", "#F4F1E9"))
    let ink = extraStyleColor(extraStyleParamString(input.params, "inkColor", "#101114"))
    let showRules = extraStyleParamBool(input.params, "showRules", true)
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "news-background", canvas: canvas,
      colors: [paper, ExtraStyleRGBA(r: 0.91, g: 0.89, b: 0.82, a: 1)],
      locations: [0, 1], zIndex: 0
    ))
    // Halftone print grain over the paper (bundled procedural
    // asset — no new asset needed).
    builder.add(ExtraStyleNode(
      id: "news-halftone", kind: .image,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      scale: canvas.width / 256,
      opacity: 0.12,
      zIndex: 1,
      imageAssetId: "halftone-dots"
    ))

    // Masthead + rules (static front-page chrome).
    builder.add(extraStyleTextNode(
      id: "news-masthead",
      text: "THE MVMT TIMES", font: ExtraStyleFonts.serif, sizePoints: canvas.width * 0.072,
      color: ink,
      position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.075),
      zIndex: 10,
      colorParamId: "inkColor"
    ))
    let rulePath = CGMutablePath()
    rulePath.move(to: CGPoint(x: 0, y: 0))
    rulePath.addLine(to: CGPoint(x: canvas.width * 0.88, y: 0))
    builder.add(ExtraStyleNode(
      id: "news-rule-top", kind: .path,
      position: CGPoint(x: canvas.width * 0.06, y: canvas.height * 0.115),
      anchor: .zero, zIndex: 10,
      path: ExtraStylePathContent(
        path: rulePath, strokeColor: ink, strokeWidth: 3, dash: nil)
    ))
    builder.add(extraStyleTextNode(
      id: "news-dateline",
      text: "VOL. 2 — BREAKING NEWS — ALL THE LYRICS THAT FIT",
      font: ExtraStyleFonts.serifRegular, sizePoints: canvas.width * 0.024,
      color: ink.withAlpha(0.75),
      position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.14),
      zIndex: 10,
      colorParamId: "inkColor"
    ))

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let headlineY = canvas.height * 0.3

      // Kicker above the headline.
      builder.add(extraStyleTextNode(
        id: "news-kicker-\(lineIndex)",
        text: "★ BREAKING ★", font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
        color: ExtraStyleRGBA(r: 0.75, g: 0.22, b: 0.17, a: 1),
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.2),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        tracks: [
          extraStyleSpringInTrack(start: lineStartFrame, from: 0.4),
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
        ]
      ))

      // Headline = per-word nodes: each word springs in from a
      // seeded radial scatter, holds, then scatters out at the
      // line end — the explosion.
      let headlineWords = extraStyleWordNodes(
        line: line, lineIndex: lineIndex, fps: fps,
        lineStartFrame: lineStartFrame, lineEndFrame: lineEndFrame,
        y: headlineY, sizePoints: canvas.width * 0.07,
        color: ink, font: ExtraStyleFonts.serif, zIndex: 11,
        canvasWidth: canvas.width,
        colorParamId: "inkColor"
      ) { index, wordStartFrame, wordEndFrame in
        var wordRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex * 1000 + index * 19 + 5))
        let angle = wordRandom.nextDouble() * 2 * Double.pi
        let distance = wordRandom.nextRange(min: 60, max: 220) * scatter
        let dx = cos(angle) * distance
        let dy = sin(angle) * distance * 0.6
        let settleFrame = min(wordEndFrame, wordStartFrame + 14)
        let scatterFrame = max(wordStartFrame, wordEndFrame - 14)
        return [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: dx, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: scatterFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: wordEndFrame, value: dx, easing: .easeInCubic),
            ]),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: wordStartFrame, value: dy, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: settleFrame, value: 0, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: scatterFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: wordEndFrame, value: dy, easing: .easeInCubic),
            ]),
            startFrame: wordStartFrame
          ),
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.5, to: 1, stiffness: 160, damping: 11, initialVelocity: 0),
            startFrame: wordStartFrame,
            paramScale: "headlineScale"
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
      for word in headlineWords { builder.add(word) }

      // Rule under the headline.
      if showRules {
        builder.add(ExtraStyleNode(
          id: "news-rule-\(lineIndex)", kind: .path,
          position: CGPoint(x: canvas.width * 0.06, y: canvas.height * 0.38),
          anchor: .zero, zIndex: 10,
          visibleRange: lineStartFrame...lineEndFrame,
          path: ExtraStylePathContent(
            path: rulePath, strokeColor: ink, strokeWidth: 2, dash: nil)
        ))
      }

      // Column blocks slide in from alternating sides; the first
      // column carries the line as body copy.
      let gutter = canvas.width * 0.04
      let totalWidth = canvas.width * 0.88
      let columnWidth = (totalWidth - gutter * CGFloat(columnCount - 1)) / CGFloat(columnCount)
      let columnHeight = canvas.height * 0.24
      let columnY = canvas.height * 0.56
      for column in 0..<columnCount {
        let columnX = canvas.width * 0.06 + columnWidth / 2
          + CGFloat(column) * (columnWidth + gutter)
        let slideFrom: Double = column % 2 == 0 ? -120 : 120
        builder.add(extraStyleShapeNode(
          id: "news-column-\(lineIndex)-\(column)",
          shape: extraStyleRectShape(width: columnWidth, height: columnHeight),
          fill: ink.withAlpha(0.07),
          stroke: ink.withAlpha(0.35), strokeWidth: 1,
          position: CGPoint(x: columnX, y: columnY),
          zIndex: 9,
          visibleRange: lineStartFrame...lineEndFrame,
          tracks: [
            ExtraStyleTrack(
              property: .positionX,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: lineStartFrame + column * 4, value: slideFrom, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + column * 4 + 14), value: 0, easing: .easeOutCubic),
              ]),
              startFrame: lineStartFrame
            ),
            extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          ]
        ))
        if column == 0 {
          builder.add(extraStyleTextNode(
            id: "news-body-\(lineIndex)",
            text: line.text, font: ExtraStyleFonts.serifRegular,
            sizePoints: canvas.width * 0.03, color: ink,
            position: CGPoint(x: columnX, y: columnY),
            zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
            maxWidthPoints: columnWidth * 0.88,
            colorParamId: "inkColor",
            tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
          ))
        }
      }
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 34: VHS Dream (experimental)

final class VHSDreamExtraStyle: ExtraStyleDefinition {
  let id = "vhs-dream"
  let version = 1
  let name = "VHS Dream"
  let tagline = "Tracking errors, tape hiss you can see, and retro type."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "trackingAmount", label: "Tracking errors", min: 0, max: 1, step: 0.05,
        default: 0.6, affects: "motion"
      ),
      extraStyleSliderParam(
        id: "distortion", label: "Analog distortion", min: 0, max: 1, step: 0.05,
        default: 0.5, affects: "motion"
      ),
      extraStyleToggleParam(id: "showTimestamp", label: "Timestamp", default: true, affects: "motion"),
      extraStyleSegmentedParam(
        id: "tapeSpeed", label: "Tape speed",
        options: [("SP", "SP"), ("LP", "LP"), ("EP", "EP")],
        default: "SP", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "scanlines", label: "Scanlines", min: 0, max: 1, step: 0.05,
        default: 0.5, affects: "appearance"
      ),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "clean-tape", "label": "Clean tape", "values": ["trackingAmount": 0.2, "distortion": 0.2, "scanlines": 0.3]],
      ["id": "worn-out", "label": "Worn out", "values": ["trackingAmount": 1, "distortion": 1, "scanlines": 0.8]],
    ]
  }

  var inputs: [String] { ["lines"] }

  var rebuildParamIds: [String] { ["trackingAmount", "distortion", "tapeSpeed"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let trackingAmount = extraStyleParamDouble(input.params, "trackingAmount", 0.6)
    let distortion = extraStyleParamDouble(input.params, "distortion", 0.5)
    let tapeSpeed = extraStyleParamString(input.params, "tapeSpeed", "SP")
    let durationSeconds = Double(input.durationFrames) / fps
    let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    let cyan = ExtraStyleRGBA(r: 0.49, g: 0.98, b: 1, a: 1)
    var builder = ExtraStyleSceneBuilder()

    // A faint dark wash so the retro chrome reads over bright video.
    builder.add(extraStyleBackgroundGradientNode(
      id: "vhs-wash", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 0.22),
        ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 0),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Analog distortion: full-frame displacement (Core Image
    // path). A Metal displacement shader is the documented spike
    // candidate for this node — see the file header; not
    // attempted here. The scale loop slowly re-times the wave.
    builder.add(ExtraStyleNode(
      id: "vhs-displacement", kind: .displacement,
      displacement: ExtraStyleDisplacementContent(
        baseScale: 4 + 26 * distortion, frequency: 3),
      tracks: [
        ExtraStyleTrack(
          property: .scale,
          kind: .loop(periodFrames: 180, periodParamId: nil, keys: [
            ExtraStyleKeyframe(frame: 0, value: 1, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 90, value: 1.3, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 180, value: 1, easing: .easeInOutSine),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // Tracking-error bands: full-width slices that jump
    // vertically on seeded keyframes and flicker.
    for band in 0..<6 {
      var bandRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(band * 13 + 41))
      let bandHeight = CGFloat(bandRandom.nextRange(min: 8, max: 36))
      let bandY = canvas.height * CGFloat(bandRandom.nextRange(min: 0.1, max: 0.9))
      var jumpKeys: [ExtraStyleKeyframe] = []
      var frame = 0
      var jumpRandom = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(band * 29 + 97))
      while frame <= input.durationFrames {
        let value: Double = jumpRandom.nextDouble() < 0.65
          ? 0
          : jumpRandom.nextRange(min: -140, max: 140) * trackingAmount
        jumpKeys.append(ExtraStyleKeyframe(frame: frame, value: value, easing: .linear))
        frame += 9
      }
      builder.add(extraStyleShapeNode(
        id: "vhs-band-\(band)",
        shape: extraStyleRectShape(width: canvas.width, height: bandHeight),
        fill: (band % 2 == 0 ? warmWhite : cyan).withAlpha(0.1),
        position: CGPoint(x: canvas.width / 2, y: bandY),
        zIndex: 2,
        blendMode: .screen,
        tracks: [
          ExtraStyleTrack(property: .positionY, kind: .keyframes(keys: jumpKeys), startFrame: 0),
          extraStyleFlickerTrack(
            start: 0, end: input.durationFrames, base: 0.6, amplitude: 0.4,
            seed: input.seed ^ UInt64(band * 13 + 151), stepFrames: 5),
        ]
      ))
    }

    // Scanlines: thin full-width bars, intensity via paramScale.
    for row in 0..<12 {
      let y = canvas.height * CGFloat(row + 1) / 13
      builder.add(ExtraStyleNode(
        id: "vhs-scanline-\(row)", kind: .shape,
        position: CGPoint(x: canvas.width / 2, y: y),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 1,
        shape: ExtraStyleShapeContent(
          shape: extraStyleRectShape(width: canvas.width, height: 3),
          fill: warmWhite.withAlpha(0.05),
          stroke: nil, strokeWidth: 0
        ),
        tracks: [
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [ExtraStyleKeyframe(frame: 0, value: 1, easing: .linear)]),
            startFrame: 0,
            paramScale: "scanlines"
          ),
        ]
      ))
    }

    // VHS chrome: PLAY marker (top-left), flashing TRACKING
    // warning (top-right), tape timestamp (bottom-left, ticking
    // once per second via prebuilt counter nodes).
    builder.add(extraStyleTextNode(
      id: "vhs-play",
      text: "▶ PLAY", font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.032,
      color: warmWhite,
      position: CGPoint(x: canvas.width * 0.12, y: canvas.height * 0.055),
      zIndex: 20
    ))
    builder.add(extraStyleTextNode(
      id: "vhs-tracking",
      text: "TRACKING", font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.028,
      color: cyan,
      position: CGPoint(x: canvas.width * 0.84, y: canvas.height * 0.055),
      zIndex: 20,
      tracks: [
        extraStyleFlickerTrack(
          start: 0, end: input.durationFrames, base: 0.7, amplitude: 0.3,
          seed: input.seed ^ 0x5648_5300_0001, stepFrames: 6),
      ]
    ))
    if extraStyleParamBool(input.params, "showTimestamp", true) {
      let steps = max(1, min(180, Int(durationSeconds.rounded())))
      for stamp in extraStyleCounterNodes(
        idPrefix: "vhs-timestamp", from: 0, to: durationSeconds, steps: steps,
        startFrame: 0, endFrame: input.durationFrames,
        position: CGPoint(x: canvas.width * 0.18, y: canvas.height * 0.94),
        sizePoints: canvas.width * 0.03, color: warmWhite,
        font: ExtraStyleFonts.mono, zIndex: 20,
        format: { "\(tapeSpeed) " + experimentalTapeTimecode($0) }
      ) { builder.add(stamp) }
    }

    // Retro type: the line in mono with a cyan ghost copy offset
    // (chromatic aberration); both wobble on a sine loop whose
    // amplitude follows the distortion param.
    let wobble = 3 + 5 * distortion
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let centerY = canvas.height * 0.5
      let wobbleTrack = ExtraStyleTrack(
        property: .positionX,
        kind: .loop(periodFrames: 120, periodParamId: nil, keys: [
          ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: 30, value: wobble, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: 60, value: 0, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: 90, value: -wobble, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: 120, value: 0, easing: .easeInOutSine),
        ]),
        startFrame: lineStartFrame
      )
      builder.add(ExtraStyleNode(
        id: "vhs-ghost-\(lineIndex)", kind: .text,
        position: CGPoint(x: canvas.width / 2 + 4, y: centerY + 2),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 9,
        blendMode: .screen,
        visibleRange: lineStartFrame...lineEndFrame,
        text: ExtraStyleTextContent(
          text: line.text,
          fontPostScriptName: ExtraStyleFonts.mono,
          sizePoints: canvas.width * 0.06,
          color: cyan.withAlpha(0.5),
          strokeColor: nil,
          strokeWidthPoints: 0,
          alignment: .center,
          maxWidthPoints: canvas.width * 0.88
        ),
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          wobbleTrack,
        ]
      ))
      builder.add(extraStyleTextNode(
        id: "vhs-line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.06,
        color: warmWhite,
        position: CGPoint(x: canvas.width / 2, y: centerY),
        zIndex: 10, visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          wobbleTrack,
        ]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Style 35: Optical Illusion (experimental)

final class OpticalIllusionExtraStyle: ExtraStyleDefinition {
  let id = "optical-illusion"
  let version = 1
  let name = "Optical Illusion"
  let tagline = "Patterns that turn — and the words turn with them."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "patternSpeed", label: "Pattern speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleSegmentedParam(
        id: "patternStyle", label: "Pattern",
        options: [
          ("rings", "Rings"), ("checker", "Checker"),
          ("spiral", "Spiral"), ("waves", "Waves"),
        ],
        default: "rings", affects: "layout"
      ),
      extraStyleSliderParam(
        id: "illusionIntensity", label: "Illusion strength", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "motion"
      ),
      extraStyleColorParam(id: "accent", label: "Accent colour", default: "#C9F36B", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "hypnotic", "label": "Hypnotic", "values": ["patternStyle": "spiral", "patternSpeed": 0.6, "illusionIntensity": 1]],
      ["id": "subtle", "label": "Subtle", "values": ["patternStyle": "rings", "patternSpeed": 1, "illusionIntensity": 0.4]],
    ]
  }

  var inputs: [String] { ["lines"] }

  var rebuildParamIds: [String] { ["patternStyle", "illusionIntensity"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let patternStyle = extraStyleParamString(input.params, "patternStyle", "rings")
    let intensity = extraStyleParamDouble(input.params, "illusionIntensity", 0.7)
    let accent = extraStyleColor(extraStyleParamString(input.params, "accent", "#C9F36B"))
    let warmWhite = ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1)
    let center = CGPoint(x: canvas.width / 2, y: canvas.height * 0.42)
    // The shared loop period (240 frames at speed 1): every
    // pattern group AND the text read this same period, so the
    // text moves in phase with the pattern.
    let period = 240
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "opt-background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.06, g: 0.07, b: 0.07, a: 1),
        ExtraStyleRGBA(r: 0.01, g: 0.01, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Outer rotating ring group: concentric stroked ellipses.
    var outerMembers: [String] = []
    for ring in 0..<6 {
      let diameter = canvas.width * (0.85 - CGFloat(ring) * 0.12)
      let ringColor = ring % 2 == 0 ? accent : warmWhite.withAlpha(0.7)
      let ringId = "opt-ring-\(ring)"
      builder.addChild(extraStyleShapeNode(
        id: ringId,
        shape: extraStyleEllipseShape(width: diameter, height: diameter),
        fill: nil,
        stroke: ringColor, strokeWidth: 3,
        position: .zero, zIndex: 0
      ))
      outerMembers.append(ringId)
    }
    // Dots riding the outermost ring.
    for dot in 0..<4 {
      let angle = Double(dot) * .pi / 2
      let radius = canvas.width * 0.425
      let dotId = "opt-ring-dot-\(dot)"
      builder.addChild(extraStyleShapeNode(
        id: dotId,
        shape: extraStyleEllipseShape(width: 22, height: 22),
        fill: accent,
        position: CGPoint(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius),
        zIndex: 1
      ))
      outerMembers.append(dotId)
    }
    builder.add(ExtraStyleNode(
      id: "opt-outer", kind: .group,
      children: outerMembers,
      position: center, anchor: .zero,
      zIndex: 1,
      tracks: [
        ExtraStyleTrack(
          property: .rotationDeg,
          kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: period, value: 360, easing: .linear),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // Inner counter-rotating group: squares turned 45°, shrinking.
    var innerMembers: [String] = []
    for square in 0..<4 {
      let side = canvas.width * (0.5 - CGFloat(square) * 0.1)
      let squareId = "opt-square-\(square)"
      builder.addChild(ExtraStyleNode(
        id: squareId, kind: .shape,
        position: .zero, anchor: CGPoint(x: 0.5, y: 0.5),
        rotationDeg: 45,
        zIndex: 0,
        shape: ExtraStyleShapeContent(
          shape: extraStyleRectShape(width: side, height: side),
          fill: nil,
          stroke: square % 2 == 0 ? warmWhite.withAlpha(0.6) : accent.withAlpha(0.8),
          strokeWidth: 2
        )
      ))
      innerMembers.append(squareId)
    }
    builder.add(ExtraStyleNode(
      id: "opt-inner", kind: .group,
      children: innerMembers,
      position: center, anchor: .zero,
      zIndex: 2,
      tracks: [
        ExtraStyleTrack(
          property: .rotationDeg,
          kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: period, value: -360, easing: .linear),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // Pattern-style group (the distinguishing geometry).
    switch patternStyle {
    case "checker":
      // 6 × 8 alternating grid, slowly rotating as one.
      var checkerMembers: [String] = []
      let cell = canvas.width * 0.13
      for row in 0..<8 {
        for column in 0..<6 {
          let cellId = "opt-checker-\(row)-\(column)"
          let isAccent = (row + column) % 2 == 0
          builder.addChild(extraStyleShapeNode(
            id: cellId,
            shape: extraStyleRectShape(width: cell, height: cell),
            fill: isAccent ? accent.withAlpha(0.85) : warmWhite.withAlpha(0.12),
            position: CGPoint(
              x: CGFloat(column - 2) * cell - cell / 2,
              y: CGFloat(row - 4) * cell - cell / 2),
            zIndex: 0
          ))
          checkerMembers.append(cellId)
        }
      }
      builder.add(ExtraStyleNode(
        id: "opt-checker", kind: .group,
        children: checkerMembers,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.42),
        anchor: .zero,
        zIndex: 1,
        tracks: [
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .loop(periodFrames: period * 2, periodParamId: "patternSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: period * 2, value: 360, easing: .linear),
            ]),
            startFrame: 0
          ),
        ]
      ))
    case "spiral":
      // Offset shrinking ellipses along a diagonal — a spiral
      // implied by the outer group's rotation.
      var spiralMembers: [String] = []
      for step in 0..<7 {
        let diameter = canvas.width * (0.7 - CGFloat(step) * 0.08)
        let offset = CGFloat(step) * 16
        let spiralId = "opt-spiral-\(step)"
        builder.addChild(extraStyleShapeNode(
          id: spiralId,
          shape: extraStyleEllipseShape(width: diameter, height: diameter),
          fill: nil,
          stroke: step % 2 == 0 ? accent : warmWhite.withAlpha(0.7),
          strokeWidth: 3,
          position: CGPoint(x: offset, y: offset),
          zIndex: 0
        ))
        spiralMembers.append(spiralId)
      }
      builder.add(ExtraStyleNode(
        id: "opt-spiral", kind: .group,
        children: spiralMembers,
        position: center, anchor: .zero,
        zIndex: 1,
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 1, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: period / 2, value: 1 + 0.08 * intensity, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: period, value: 1, easing: .easeInOutSine),
            ]),
            startFrame: 0
          ),
        ]
      ))
    case "waves":
      // Five sine paths, each phase-shifted on the shared period.
      for wave in 0..<5 {
        let phase = Double(wave) * .pi / 2.5
        let amplitude = 24 + Double(wave) * 8
        let wavePath = CGMutablePath()
        var x: CGFloat = 0
        var first = true
        while x <= canvas.width {
          let y = sin(Double(x) / Double(canvas.width) * .pi * 4 + phase) * CGFloat(amplitude)
          if first { wavePath.move(to: CGPoint(x: x, y: y)); first = false }
          else { wavePath.addLine(to: CGPoint(x: x, y: y)) }
          x += 40
        }
        builder.add(ExtraStyleNode(
          id: "opt-wave-\(wave)", kind: .path,
          position: CGPoint(x: 0, y: canvas.height * (0.3 + CGFloat(wave) * 0.06)),
          anchor: .zero, zIndex: 1,
          path: ExtraStylePathContent(
            path: wavePath,
            strokeColor: wave % 2 == 0 ? accent.withAlpha(0.8) : warmWhite.withAlpha(0.5),
            strokeWidth: 3, dash: nil),
          tracks: [
            ExtraStyleTrack(
              property: .positionY,
              kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
                ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: period / 2, value: -14 * intensity, easing: .easeInOutSine),
                ExtraStyleKeyframe(frame: period, value: 0, easing: .easeInOutSine),
              ]),
              startFrame: 0
            ),
          ]
        ))
      }
    default: // "rings"
      // A breathing ring group on the shared period.
      var breathMembers: [String] = []
      for ring in 0..<3 {
        let diameter = canvas.width * (0.6 - CGFloat(ring) * 0.14)
        let breathId = "opt-breath-\(ring)"
        builder.addChild(extraStyleShapeNode(
          id: breathId,
          shape: extraStyleEllipseShape(width: diameter, height: diameter),
          fill: nil,
          stroke: accent.withAlpha(0.5 + CGFloat(ring) * 0.15),
          strokeWidth: 2,
          position: .zero, zIndex: 0
        ))
        breathMembers.append(breathId)
      }
      builder.add(ExtraStyleNode(
        id: "opt-breath", kind: .group,
        children: breathMembers,
        position: center, anchor: .zero,
        zIndex: 1,
        tracks: [
          ExtraStyleTrack(
            property: .scale,
            kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 1, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: period / 2, value: 1 + 0.1 * intensity, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: period, value: 1, easing: .easeInOutSine),
            ]),
            startFrame: 0
          ),
        ]
      ))
    }

    // Impossible shape: a Penrose-style triangle — three thick
    // strokes that meet with small offsets, slowly rotating.
    let triCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.2)
    let triHalf = canvas.width * 0.22
    func triPath(from: CGPoint, to: CGPoint) -> CGPath {
      let path = CGMutablePath()
      path.move(to: from)
      path.addLine(to: to)
      return path
    }
    var triMembers: [String] = []
    let triSegments: [(String, CGPoint, CGPoint)] = [
      ("base", CGPoint(x: -triHalf, y: triHalf * 0.6), CGPoint(x: triHalf, y: triHalf * 0.6)),
      ("right", CGPoint(x: triHalf, y: triHalf * 0.6), CGPoint(x: 12, y: -triHalf * 0.7)),
      ("left", CGPoint(x: -12, y: -triHalf * 0.7), CGPoint(x: -triHalf + 18, y: triHalf * 0.6)),
    ]
    for (segmentName, from, to) in triSegments {
      let segmentId = "opt-tri-\(segmentName)"
      builder.addChild(ExtraStyleNode(
        id: segmentId, kind: .path,
        position: .zero, anchor: .zero, zIndex: 0,
        path: ExtraStylePathContent(
          path: triPath(from: from, to: to),
          strokeColor: warmWhite, strokeWidth: 16, dash: nil)
      ))
      triMembers.append(segmentId)
    }
    builder.add(ExtraStyleNode(
      id: "opt-triangle", kind: .group,
      children: triMembers,
      position: triCenter, anchor: .zero,
      zIndex: 2,
      tracks: [
        ExtraStyleTrack(
          property: .rotationDeg,
          kind: .loop(periodFrames: period * 2, periodParamId: "patternSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
            ExtraStyleKeyframe(frame: period * 2, value: 360, easing: .linear),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // Perspective text: each line sits in a trapezoid-warped
    // group (CIPerspectiveTransform on the rasterized subtree)
    // and drifts on the SAME 240-frame period as the pattern, so
    // the words move in phase with the rings.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      let textCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.62)
      let phaseX = ExtraStyleTrack(
        property: .positionX,
        kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
          ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: period / 4, value: 18 * intensity, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: period / 2, value: 0, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: period * 3 / 4, value: -18 * intensity, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: period, value: 0, easing: .easeInOutSine),
        ]),
        startFrame: lineStartFrame
      )
      let phaseY = ExtraStyleTrack(
        property: .positionY,
        kind: .loop(periodFrames: period, periodParamId: "patternSpeed", keys: [
          ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: period / 4, value: -12 * intensity, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: period / 2, value: 0, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: period * 3 / 4, value: 12 * intensity, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: period, value: 0, easing: .easeInOutSine),
        ]),
        startFrame: lineStartFrame
      )
      builder.addChild(extraStyleTextNode(
        id: "opt-line-ghost-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.black, sizePoints: canvas.width * 0.07,
        color: accent.withAlpha(0.5),
        position: CGPoint(x: 8, y: 8),
        zIndex: 0,
        maxWidthPoints: canvas.width * 0.8,
        colorParamId: "accent",
        tracks: [phaseX, phaseY]
      ))
      builder.addChild(extraStyleTextNode(
        id: "opt-line-\(lineIndex)",
        text: line.text, font: ExtraStyleFonts.black, sizePoints: canvas.width * 0.07,
        color: warmWhite,
        position: .zero,
        zIndex: 1,
        maxWidthPoints: canvas.width * 0.8,
        tracks: [
          extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame),
          phaseX, phaseY,
        ]
      ))
      builder.add(ExtraStyleNode(
        id: "opt-persp-\(lineIndex)", kind: .group,
        children: ["opt-line-ghost-\(lineIndex)", "opt-line-\(lineIndex)"],
        position: textCenter, anchor: .zero,
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        perspectiveCorners: [
          CGPoint(x: textCenter.x - canvas.width * 0.4, y: textCenter.y - canvas.height * 0.08),
          CGPoint(x: textCenter.x + canvas.width * 0.4, y: textCenter.y - canvas.height * 0.08),
          CGPoint(x: textCenter.x + canvas.width * 0.46, y: textCenter.y + canvas.height * 0.08),
          CGPoint(x: textCenter.x - canvas.width * 0.46, y: textCenter.y + canvas.height * 0.08),
        ]
      ))
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Phase 3 registration (Experimental A)

extension ExtraStylesPhase3 {
  static func registerExperimentalA(into registry: ExtraStyleRegistry) {
    registry.register(GlitchRealityExtraStyle())
    registry.register(SurveillanceSystemExtraStyle())
    registry.register(NewspaperExplosionExtraStyle())
    registry.register(VHSDreamExtraStyle())
    registry.register(OpticalIllusionExtraStyle())
  }
}
