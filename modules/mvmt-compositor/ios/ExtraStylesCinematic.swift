import CoreGraphics
import Foundation

// MARK: - Extra Styles 2.0 — Phase 3, Cinematic family (rest)
//
// Four styles (docs/EXTRA-STYLES-2.0.md §17 rows 2–5):
//   - Memory Fragments — procedural photo-frame groups, slide-in,
//     cross-dissolve between memories, staggered entrances.
//   - Floating Universe — particle star field, planet shapes, orbit
//     paths, depth-scaled text.
//   - Film Credits Reimagined — large tracked type (per-character
//     letter-spacing, faked — the engine has no tracking knob),
//     letterbox bars, gradient vignette, slow push-in.
//   - Parallel Worlds — mirrored text groups, split-screen divider,
//     distortion overlay, world switch on the downbeat
//     (needsAudioAutomation = true; see the TS catalog map).
//
// Flags match src/lib/extra-styles/catalog.ts (STYLE_CAPABILITY_MAP):
// memory-fragments, floating-universe and film-credits-reimagined
// are FALSE/FALSE; parallel-worlds is TRUE/FALSE.

// MARK: - Memory Fragments (cinematic, §17 #2)

final class MemoryFragmentsExtraStyle: ExtraStyleDefinition {
  let id = "memory-fragments"
  let version = 1
  let name = "Memory Fragments"
  let tagline = "Old photographs, surfacing one memory at a time."
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
      extraStyleColorParam(id: "frameTint", label: "Frame tint", default: "#F4F1E9", affects: "appearance"),
      extraStyleToggleParam(id: "showCaptions", label: "Captions", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "warm-album", "label": "Warm album", "values": ["layout": "scattered", "frameTint": "#F5E6C8", "dissolve": 0.8]],
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
    let frameTint = extraStyleColor(extraStyleParamString(input.params, "frameTint", "#F4F1E9"))
    let darkInk = ExtraStyleRGBA(r: 0.16, g: 0.13, b: 0.10, a: 1)
    var builder = ExtraStyleSceneBuilder()

    // Warm dark-room background.
    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.13, g: 0.11, b: 0.09, a: 1),
        ExtraStyleRGBA(r: 0.05, g: 0.04, b: 0.04, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Frame geometry (all relative to the frame group's origin,
    // which is the frame centre).
    let frameWidth = canvas.width * 0.6
    let photoSize = CGSize(width: frameWidth * 0.86, height: frameWidth * 0.6)
    let margin = frameWidth * 0.07
    let captionHeight = canvas.width * 0.11
    let frameHeight = margin + photoSize.height + canvas.width * 0.03 + captionHeight + margin
    let photoCentre = CGPoint(x: 0, y: -frameHeight / 2 + margin + photoSize.height / 2)
    let captionCentre = CGPoint(x: 0, y: frameHeight / 2 - margin - captionHeight / 2)

    // Optional face avoidance: when a mask index was supplied AND
    // the designed frame would overlap a face box, push the frame
    // vertically clear of the face. No masks → designed position.
    func avoidedCentre(_ centre: CGPoint, at seconds: Double) -> CGPoint {
      guard let maskIndex = input.maskIndex, !maskIndex.faces.isEmpty else { return centre }
      let boxes = maskIndex.faceBoxes(at: seconds)
      guard let box = boxes.first else { return centre }
      let faceRect = CGRect(
        x: box.origin.x * canvas.width, y: box.origin.y * canvas.height,
        width: box.size.width * canvas.width, height: box.size.height * canvas.height
      )
      let frameRect = CGRect(
        x: centre.x - frameWidth / 2, y: centre.y - frameHeight / 2,
        width: frameWidth, height: frameHeight
      )
      guard frameRect.intersects(faceRect.insetBy(dx: -24, dy: -24)) else { return centre }
      let faceCY = faceRect.origin.y + faceRect.size.height / 2
      var cy = centre.y
      if faceCY < centre.y {
        cy = faceRect.maxY + frameHeight / 2 + 16
      } else {
        cy = faceRect.minY - frameHeight / 2 - 16
      }
      cy = min(max(cy, frameHeight / 2 + 12), canvas.height - frameHeight / 2 - 12)
      return CGPoint(x: centre.x, y: cy)
    }

    // A small decorative frame behind the main one (layered
    // composition, staggered entrance).
    func addBackFrame(
      _ builder: inout ExtraStyleSceneBuilder,
      suffix: String, centre: CGPoint, rotation: CGFloat, scale: CGFloat,
      baseOpacity: CGFloat, delay: Int, range: ClosedRange<Int>
    ) {
      let paperId = "memory-back-paper-\(suffix)"
      let borderId = "memory-back-border-\(suffix)"
      builder.addChild(ExtraStyleNode(
        id: paperId, kind: .image,
        position: .zero, anchor: CGPoint(x: 0.5, y: 0.5),
        scale: frameWidth / 256, zIndex: 0,
        visibleRange: range,
        imageAssetId: "paper-texture"
      ))
      builder.addChild(extraStyleShapeNode(
        id: borderId,
        shape: extraStyleRectShape(width: frameWidth, height: frameHeight),
        fill: frameTint, stroke: darkInk, strokeWidth: 3,
        position: .zero, zIndex: 1,
        visibleRange: range,
        fillColorParamId: "frameTint"
      ))
      builder.add(ExtraStyleNode(
        id: "memory-back-\(suffix)", kind: .group,
        children: [paperId, borderId],
        position: centre, anchor: .zero,
        scale: scale, rotationDeg: rotation, opacity: baseOpacity,
        zIndex: 5,
        visibleRange: range,
        tracks: [
          ExtraStyleTrack(
            property: .positionX,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: range.lowerBound + delay, value: Double(canvas.width) * 0.25, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: min(range.upperBound, range.lowerBound + delay + 14), value: 0, easing: .easeOutCubic),
            ]),
            startFrame: range.lowerBound + delay
          ),
          extraStyleEnterExitOpacityTrack(start: range.lowerBound, end: range.upperBound, enterFrames: 12, exitFrames: 12),
        ]
      ))
    }

    // One memory: paper frame + sepia "photo" + caption + the
    // line's stored emoji as a stamp on the photo corner.
    func addMemory(
      _ builder: inout ExtraStyleSceneBuilder,
      index: Int, centre: CGPoint, rotation: CGFloat,
      caption: String?, line: ExtraStyleInputLine?, range: ClosedRange<Int>
    ) {
      let paperId = "memory-paper-\(index)"
      let borderId = "memory-border-\(index)"
      let photoId = "memory-photo-\(index)"
      let captionId = "memory-caption-\(index)"
      let emojiId = "memory-emoji-\(index)"
      var members: [String] = []
      builder.addChild(ExtraStyleNode(
        id: paperId, kind: .image,
        position: .zero, anchor: CGPoint(x: 0.5, y: 0.5),
        scale: frameWidth / 256, zIndex: 0,
        visibleRange: range,
        imageAssetId: "paper-texture"
      ))
      members.append(paperId)
      builder.addChild(extraStyleShapeNode(
        id: borderId,
        shape: extraStyleRectShape(width: frameWidth, height: frameHeight),
        fill: frameTint, stroke: darkInk, strokeWidth: 3,
        position: .zero, zIndex: 1,
        visibleRange: range,
        fillColorParamId: "frameTint"
      ))
      members.append(borderId)
      // The "photo": a sepia gradient stand-in (user photos are
      // out of scope for Phase 3 — the frame is procedural).
      let tone = line.map { extraStyleToneColor($0.tone) } ?? extraStyleToneColor(nil)
      builder.addChild(ExtraStyleNode(
        id: photoId, kind: .gradient,
        position: photoCentre, anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 2,
        visibleRange: range,
        gradient: ExtraStyleGradientContent(
          kind: .linear(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: photoSize.height)),
          colors: [
            ExtraStyleRGBA(r: 0.85, g: 0.72, b: 0.52, a: 1),
            tone.withAlpha(0.55),
            ExtraStyleRGBA(r: 0.45, g: 0.32, b: 0.20, a: 1),
          ],
          locations: [0, 0.5, 1],
          rect: CGRect(origin: .zero, size: photoSize)
        )
      ))
      members.append(photoId)
      if let caption, !caption.isEmpty {
        // The envelope ends at 0, so the track's end value hides
        // the caption while the showCaptions toggle is off
        // (enabledParamId returns the end value when disabled).
        builder.addChild(extraStyleTextNode(
          id: captionId,
          text: caption, font: ExtraStyleFonts.serifRegular, sizePoints: canvas.width * 0.036,
          color: darkInk,
          position: captionCentre, zIndex: 3,
          visibleRange: range,
          maxWidthPoints: frameWidth * 0.88,
          tracks: [ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: range.lowerBound, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(range.upperBound, range.lowerBound + dissolveFrames), value: 1, easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(range.lowerBound, range.upperBound - dissolveFrames), value: 1, easing: .linear),
              ExtraStyleKeyframe(frame: range.upperBound, value: 0, easing: .easeInCubic),
            ]),
            startFrame: range.lowerBound,
            enabledParamId: "showCaptions"
          )]
        ))
        members.append(captionId)
      }
      if let line, var stamp = extraStyleEmojiNode(
        id: emojiId, line: line,
        position: CGPoint(x: photoSize.width * 0.36, y: photoCentre.y - photoSize.height * 0.32),
        sizePoints: canvas.width * 0.07, zIndex: 4,
        visibleRange: range
      ) {
        // Stamp sits on the photo corner; keep the pop, drop the
        // default float (none is attached by the helper).
        stamp.tracks = [extraStyleSpringInTrack(start: range.lowerBound + 4, from: 0.2)]
        builder.addChild(stamp)
        members.append(emojiId)
      }
      // Slide-in: from the side (scattered/grid) or from below
      // (stack), then the cross-dissolve envelope on the group.
      let slideTrack: ExtraStyleTrack
      if layout == "stack" {
        slideTrack = ExtraStyleTrack(
          property: .positionY,
          kind: .keyframes(keys: [
            ExtraStyleKeyframe(frame: range.lowerBound, value: Double(canvas.height) * 0.2, easing: .easeOutCubic),
            ExtraStyleKeyframe(frame: min(range.upperBound, range.lowerBound + 14), value: 0, easing: .easeOutCubic),
          ]),
          startFrame: range.lowerBound
        )
      } else {
        let side: Double = index % 2 == 0 ? 1 : -1
        slideTrack = ExtraStyleTrack(
          property: .positionX,
          kind: .keyframes(keys: [
            ExtraStyleKeyframe(frame: range.lowerBound, value: Double(canvas.width) * 0.3 * side, easing: .easeOutCubic),
            ExtraStyleKeyframe(frame: min(range.upperBound, range.lowerBound + 14), value: 0, easing: .easeOutCubic),
          ]),
          startFrame: range.lowerBound
        )
      }
      builder.add(ExtraStyleNode(
        id: "memory-\(index)", kind: .group,
        children: members,
        position: centre, anchor: .zero,
        rotationDeg: rotation,
        zIndex: 10 + index,
        visibleRange: range,
        tracks: [
          slideTrack,
          ExtraStyleTrack(
            property: .scale,
            kind: .spring(from: 0.94, to: 1, stiffness: 140, damping: 12, initialVelocity: 0),
            startFrame: range.lowerBound
          ),
          extraStyleEnterExitOpacityTrack(
            start: range.lowerBound, end: range.upperBound,
            enterFrames: dissolveFrames, exitFrames: dissolveFrames
          ),
        ]
      ))
    }

    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    if sortedLines.isEmpty {
      // No lyrics yet: one quiet empty frame, so the style still
      // previews as a photograph album rather than a blank.
      let centre = CGPoint(x: canvas.width / 2, y: canvas.height * 0.5)
      addMemory(
        &builder, index: 0, centre: centre, rotation: -2,
        caption: nil, line: nil,
        range: 0...max(1, input.durationFrames)
      )
      return builder.build(canvas: canvas, durationFrames: input.durationFrames)
    }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: input.durationFrames) else { continue }
      var random = ExtraStyleSeededRandom(seed: input.seed ^ UInt64(lineIndex + 1))
      let rotation: CGFloat
      let centre: CGPoint
      switch layout {
      case "stack":
        rotation = 0
        centre = CGPoint(x: canvas.width / 2, y: canvas.height * 0.5)
      case "grid":
        rotation = lineIndex % 2 == 0 ? -1.5 : 1.5
        centre = CGPoint(
          x: canvas.width / 2 + (lineIndex % 2 == 0 ? -1 : 1) * canvas.width * 0.05,
          y: canvas.height * 0.48
        )
      default: // scattered
        rotation = CGFloat(random.nextRange(min: -5, max: 5))
        centre = CGPoint(
          x: canvas.width / 2 + CGFloat(random.nextRange(min: -0.06, max: 0.06)) * canvas.width,
          y: canvas.height * (lineIndex % 2 == 0 ? 0.47 : 0.53)
        )
      }
      let placed = avoidedCentre(centre, at: (line.startSeconds + line.endSeconds) / 2)
      let range = lineStartFrame...lineEndFrame
      // Layered composition: two smaller frames behind, entering
      // on a stagger before the main frame settles.
      addBackFrame(
        &builder, suffix: "\(lineIndex)-0",
        centre: CGPoint(x: placed.x - frameWidth * 0.28, y: placed.y - frameHeight * 0.22),
        rotation: rotation - 8, scale: 0.72, baseOpacity: 0.5, delay: 0, range: range
      )
      addBackFrame(
        &builder, suffix: "\(lineIndex)-1",
        centre: CGPoint(x: placed.x + frameWidth * 0.3, y: placed.y + frameHeight * 0.24),
        rotation: rotation + 7, scale: 0.66, baseOpacity: 0.4, delay: 5, range: range
      )
      addMemory(
        &builder, index: lineIndex, centre: placed, rotation: rotation,
        caption: line.text, line: line, range: range
      )
    }
    return builder.build(canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - Floating Universe (cinematic, §17 #3)

final class FloatingUniverseExtraStyle: ExtraStyleDefinition {
  let id = "floating-universe"
  let version = 1
  let name = "Floating Universe"
  let tagline = "Lyrics adrift among stars, planets, and slow orbits."
  let category = "cinematic"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = false

  var parameters: [[String: Any]] {
    [
      extraStyleSliderParam(
        id: "starDensity", label: "Star density", min: 0, max: 100, step: 1,
        default: 45, affects: "density"
      ),
      extraStyleSliderParam(
        id: "orbitSpeed", label: "Orbit speed", min: 0.25, max: 2, step: 0.05,
        default: 1, affects: "motion"
      ),
      extraStyleColorParam(id: "planetHue", label: "Planet colour", default: "#8FA8FF", affects: "appearance"),
      extraStyleToggleParam(id: "showOrbits", label: "Orbit paths", default: true, affects: "layout"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "deep-field", "label": "Deep field", "values": ["starDensity": 70, "orbitSpeed": 0.6]],
      ["id": "sparse-drift", "label": "Sparse drift", "values": ["starDensity": 20, "orbitSpeed": 1.4, "showOrbits": false]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let durationFrames = input.durationFrames
    let planetHue = extraStyleColor(extraStyleParamString(input.params, "planetHue", "#8FA8FF"))
    var builder = ExtraStyleSceneBuilder()

    // Deep-space background.
    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.06, g: 0.08, b: 0.18, a: 1),
        ExtraStyleRGBA(r: 0.01, g: 0.01, b: 0.03, a: 1),
      ],
      locations: [0, 1], zIndex: 0, radial: true
    ))

    // Star field: two emitters (far dust + near stars) whose rates
    // follow the density slider with no rebuild.
    builder.add(ExtraStyleNode(
      id: "stars-far", kind: .particles,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      zIndex: 1,
      emitter: ExtraStyleEmitterContent(
        rate: 10, rateParamId: "starDensity", rateParamMultiplier: 0.15,
        lifetimeSeconds: 9,
        origin: CGPoint(x: 0.5, y: 0.5),
        velocity: CGVector(dx: 0, dy: -0.004),
        spread: CGVector(dx: 0.5, dy: 0.45),
        gravity: 0,
        size: 0.008, sizeSpread: 0.004,
        opacityFrom: 0.9, opacityTo: 0,
        color: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1),
        colorParamId: nil,
        spriteKind: .softCircle
      )
    ))
    builder.add(ExtraStyleNode(
      id: "stars-near", kind: .particles,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      zIndex: 1,
      emitter: ExtraStyleEmitterContent(
        rate: 5, rateParamId: "starDensity", rateParamMultiplier: 0.07,
        lifetimeSeconds: 7,
        origin: CGPoint(x: 0.5, y: 0.5),
        velocity: CGVector(dx: 0.002, dy: -0.002),
        spread: CGVector(dx: 0.5, dy: 0.45),
        gravity: 0,
        size: 0.016, sizeSpread: 0.008,
        opacityFrom: 1, opacityTo: 0,
        color: planetHue,
        colorParamId: "planetHue",
        spriteKind: .softCircle
      )
    ))

    // A planet: body (+ optional ring + craters) in a group that
    // tumbles slowly and bobs — depth comes from size + opacity.
    func addPlanet(
      _ builder: inout ExtraStyleSceneBuilder,
      id: String, centre: CGPoint, size: CGSize,
      fill: ExtraStyleRGBA, opacity: CGFloat, ring: Bool, seed: UInt64
    ) {
      var members: [String] = []
      builder.addChild(extraStyleShapeNode(
        id: "\(id)-body",
        shape: extraStyleEllipseShape(width: size.width, height: size.height),
        fill: fill,
        stroke: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.25), strokeWidth: 2,
        position: .zero, zIndex: 0
      ))
      members.append("\(id)-body")
      if ring {
        let rx = size.width * 0.72
        let ry = size.height * 0.3
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: CGRect(x: 0, y: 0, width: rx * 2, height: ry * 2))
        builder.addChild(ExtraStyleNode(
          id: "\(id)-ring", kind: .path,
          position: CGPoint(x: -rx, y: -ry), anchor: .zero, zIndex: 1,
          path: ExtraStylePathContent(
            path: ringPath,
            strokeColor: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.5),
            strokeWidth: 3,
            dash: nil
          )
        ))
        members.append("\(id)-ring")
      }
      var craterRandom = ExtraStyleSeededRandom(seed: seed)
      for crater in 0..<2 {
        let craterSize = size.width * CGFloat(craterRandom.nextRange(min: 0.1, max: 0.16))
        builder.addChild(extraStyleShapeNode(
          id: "\(id)-crater-\(crater)",
          shape: extraStyleEllipseShape(width: craterSize, height: craterSize * 0.8),
          fill: ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 0.18),
          position: CGPoint(
            x: CGFloat(craterRandom.nextRange(min: -0.22, max: 0.22)) * size.width,
            y: CGFloat(craterRandom.nextRange(min: -0.18, max: 0.18)) * size.height
          ),
          zIndex: 1
        ))
        members.append("\(id)-crater-\(crater)")
      }
      builder.add(ExtraStyleNode(
        id: id, kind: .group,
        children: members,
        position: centre, anchor: .zero,
        rotationDeg: CGFloat(craterRandom.nextRange(min: -12, max: 12)),
        opacity: opacity,
        zIndex: 4,
        tracks: [
          ExtraStyleTrack(
            property: .rotationDeg,
            kind: .loop(periodFrames: 1800, periodParamId: "orbitSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: 1800, value: 360, easing: .linear),
            ]),
            startFrame: 0
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 300, periodParamId: "orbitSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: -10, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 300, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: 0
          ),
        ]
      ))
    }

    let planetBCentre = CGPoint(x: canvas.width * 0.68, y: canvas.height * 0.3)
    addPlanet(
      &builder, id: "planet-far",
      centre: CGPoint(x: canvas.width * 0.2, y: canvas.height * 0.16),
      size: CGSize(width: canvas.width * 0.14, height: canvas.width * 0.12),
      fill: planetHue.withAlpha(0.75), opacity: 0.8, ring: false,
      seed: input.seed ^ 0xF10A_0001
    )
    addPlanet(
      &builder, id: "planet-mid",
      centre: planetBCentre,
      size: CGSize(width: canvas.width * 0.22, height: canvas.width * 0.2),
      fill: planetHue, opacity: 1, ring: true,
      seed: input.seed ^ 0xF10A_0002
    )
    addPlanet(
      &builder, id: "planet-near",
      centre: CGPoint(x: canvas.width * -0.02, y: canvas.height * 0.94),
      size: CGSize(width: canvas.width * 0.34, height: canvas.width * 0.3),
      fill: ExtraStyleRGBA(r: 0.05, g: 0.06, b: 0.14, a: 1), opacity: 0.9, ring: false,
      seed: input.seed ^ 0xF10A_0003
    )

    // Orbit paths: faint ellipses around the mid planet. The
    // opacity envelope ends at 0 at the last frame, so the
    // showOrbits toggle's end value hides them when off.
    func addOrbitPath(_ builder: inout ExtraStyleSceneBuilder, id: String, centre: CGPoint, radiusX: CGFloat, radiusY: CGFloat) {
      let path = CGMutablePath()
      path.addEllipse(in: CGRect(x: centre.x - radiusX, y: centre.y - radiusY, width: radiusX * 2, height: radiusY * 2))
      builder.add(ExtraStyleNode(
        id: id, kind: .path,
        position: .zero, anchor: .zero, zIndex: 3,
        path: ExtraStylePathContent(
          path: path,
          strokeColor: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.18),
          strokeWidth: 2,
          dash: [2, 8]
        ),
        tracks: [ExtraStyleTrack(
          property: .opacity,
          kind: .keyframes(keys: [
            ExtraStyleKeyframe(frame: 0, value: 1, easing: .linear),
            ExtraStyleKeyframe(frame: max(0, durationFrames - 1), value: 1, easing: .linear),
            ExtraStyleKeyframe(frame: durationFrames, value: 0, easing: .linear),
          ]),
          startFrame: 0,
          enabledParamId: "showOrbits"
        )]
      ))
    }
    addOrbitPath(&builder, id: "orbit-1", centre: planetBCentre, radiusX: canvas.width * 0.3, radiusY: canvas.height * 0.12)
    addOrbitPath(&builder, id: "orbit-2", centre: planetBCentre, radiusX: canvas.width * 0.38, radiusY: canvas.height * 0.17)

    // Ellipse points (absolute canvas points) for the path-driven moon.
    func ellipsePoints(centre: CGPoint, radiusX: CGFloat, radiusY: CGFloat, count: Int) -> [CGPoint] {
      guard count > 1 else { return [centre] }
      return (0...count).map { i in
        let angle = -Double.pi / 2 + Double(i) * 2 * Double.pi / Double(count)
        return CGPoint(x: centre.x + CGFloat(cos(angle)) * radiusX, y: centre.y + CGFloat(sin(angle)) * radiusY)
      }
    }
    // Moon 1: a true .path track — one slow orbit over the scene.
    let moon1Points = ellipsePoints(centre: planetBCentre, radiusX: canvas.width * 0.3, radiusY: canvas.height * 0.12, count: 48)
    builder.add(extraStyleShapeNode(
      id: "moon-path",
      shape: extraStyleEllipseShape(width: 16, height: 16),
      fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.9),
      position: moon1Points[0], zIndex: 7,
      tracks: [ExtraStyleTrack(
        property: .positionX,
        kind: .path(points: moon1Points, durationFrames: max(1, durationFrames), easing: .linear),
        startFrame: 0
      )]
    ))
    // Moon 2: continuous orbit from looped sine/cosine offsets.
    let moon2RX = Double(canvas.width) * 0.38
    let moon2RY = Double(canvas.height) * 0.17
    builder.add(extraStyleShapeNode(
      id: "moon-loop",
      shape: extraStyleEllipseShape(width: 10, height: 10),
      fill: planetHue,
      position: planetBCentre, zIndex: 7,
      tracks: [
        ExtraStyleTrack(
          property: .positionX,
          kind: .loop(periodFrames: 360, periodParamId: "orbitSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: moon2RX, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 90, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 180, value: -moon2RX, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 270, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 360, value: moon2RX, easing: .easeInOutSine),
          ]),
          startFrame: 0
        ),
        ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 360, periodParamId: "orbitSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 90, value: moon2RY, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 180, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 270, value: -moon2RY, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 360, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: 0
        ),
      ]
    ))

    // A slowly rotating constellation in the upper frame.
    var constellationMembers: [String] = []
    var starRandom = ExtraStyleSeededRandom(seed: input.seed ^ 0xF10A_0009)
    for star in 0..<5 {
      let radius = CGFloat(starRandom.nextRange(min: 6, max: 14))
      let starId = "constellation-star-\(star)"
      builder.addChild(extraStyleShapeNode(
        id: starId,
        shape: extraStyleStarShape(outerRadius: radius, innerRadius: radius * 0.45, spikes: 4),
        fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.85),
        position: CGPoint(
          x: CGFloat(starRandom.nextRange(min: -0.3, max: 0.3)) * canvas.width,
          y: CGFloat(starRandom.nextRange(min: -0.08, max: 0.08)) * canvas.height
        ),
        zIndex: 0
      ))
      constellationMembers.append(starId)
    }
    builder.add(ExtraStyleNode(
      id: "constellation", kind: .group,
      children: constellationMembers,
      position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.22),
      anchor: .zero, zIndex: 2,
      tracks: [ExtraStyleTrack(
        property: .rotationDeg,
        kind: .loop(periodFrames: 2400, periodParamId: nil, keys: [
          ExtraStyleKeyframe(frame: 0, value: 0, easing: .linear),
          ExtraStyleKeyframe(frame: 2400, value: 360, easing: .linear),
        ]),
        startFrame: 0
      )]
    ))

    // Depth-scaled text: far / mid / near layers by line index —
    // size, base opacity and parallax amplitude all grow with depth.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: durationFrames) else { continue }
      let depth = lineIndex % 3
      let (sizePoints, baseOpacity, parallax, yFraction): (CGFloat, CGFloat, Double, CGFloat) = {
        switch depth {
        case 0: return (canvas.width * 0.042, 0.55, 5, 0.44)
        case 2: return (canvas.width * 0.075, 1, 15, 0.56)
        default: return (canvas.width * 0.058, 0.8, 9, 0.5)
        }
      }()
      let centreY = canvas.height * yFraction
      let font = depth == 2 ? ExtraStyleFonts.avenirHeavy : ExtraStyleFonts.avenir
      builder.add(extraStyleTextNode(
        id: "line-\(lineIndex)",
        text: line.text, font: font, sizePoints: sizePoints,
        color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
        position: CGPoint(x: canvas.width / 2, y: centreY),
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        maxWidthPoints: canvas.width * 0.88,
        tracks: [
          // Enter/exit envelope capped at the depth layer's base
          // opacity (the text helper exposes no base opacity).
          ExtraStyleTrack(
            property: .opacity,
            kind: .keyframes(keys: [
              ExtraStyleKeyframe(frame: lineStartFrame, value: 0, easing: .linear),
              ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 12), value: Double(baseOpacity), easing: .easeOutCubic),
              ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 12), value: Double(baseOpacity), easing: .linear),
              ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .positionY,
            kind: .loop(periodFrames: 240, periodParamId: "orbitSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 120, value: -parallax, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
          ExtraStyleTrack(
            property: .positionX,
            kind: .loop(periodFrames: 300, periodParamId: "orbitSpeed", keys: [
              ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 150, value: parallax * 0.6, easing: .easeInOutSine),
              ExtraStyleKeyframe(frame: 300, value: 0, easing: .easeInOutSine),
            ]),
            startFrame: lineStartFrame
          ),
        ]
      ))
      // The line's emoji as a tiny satellite orbiting its text.
      if var satellite = extraStyleEmojiNode(
        id: "emoji-\(lineIndex)", line: line,
        position: CGPoint(x: canvas.width / 2 + canvas.width * 0.3, y: centreY - canvas.height * 0.08),
        sizePoints: canvas.width * 0.06, zIndex: 12,
        visibleRange: lineStartFrame...lineEndFrame
      ) {
        satellite.tracks.append(ExtraStyleTrack(
          property: .positionX,
          kind: .loop(periodFrames: 240, periodParamId: "orbitSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 60, value: -Double(canvas.width) * 0.06, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 120, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 180, value: Double(canvas.width) * 0.06, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: lineStartFrame
        ))
        satellite.tracks.append(ExtraStyleTrack(
          property: .positionY,
          kind: .loop(periodFrames: 240, periodParamId: "orbitSpeed", keys: [
            ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 60, value: -12, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 120, value: 0, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 180, value: 12, easing: .easeInOutSine),
            ExtraStyleKeyframe(frame: 240, value: 0, easing: .easeInOutSine),
          ]),
          startFrame: lineStartFrame
        ))
        builder.add(satellite)
      }
    }
    return builder.build(canvas: canvas, durationFrames: durationFrames)
  }
}

// MARK: - Film Credits Reimagined (cinematic, §17 #4)

final class FilmCreditsReimaginedExtraStyle: ExtraStyleDefinition {
  let id = "film-credits-reimagined"
  let version = 1
  let name = "Film Credits Reimagined"
  let tagline = "Large tracked type, letterbox bars, and a slow push-in."
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
      extraStyleSliderParam(
        id: "vignette", label: "Vignette", min: 0, max: 1, step: 0.05,
        default: 0.7, affects: "appearance"
      ),
      extraStyleColorParam(id: "textColor", label: "Text colour", default: "#F4F1E9", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "classic", "label": "Classic", "values": ["tracking": 0.35, "pushIn": 0.05, "vignette": 0.8]],
      ["id": "modern-tight", "label": "Modern tight", "values": ["tracking": 0.08, "pushIn": 0.12, "vignette": 0.5]],
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

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.05, g: 0.05, b: 0.06, a: 1),
        ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.02, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // Gradient vignette: clear centre, dark edges. Its opacity is
    // the vignette param (single-key track × paramScale).
    builder.add(ExtraStyleNode(
      id: "vignette", kind: .gradient,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 25,
      gradient: ExtraStyleGradientContent(
        kind: .radial(
          center: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
          radius: max(canvas.width, canvas.height) * 0.75
        ),
        colors: [
          ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 0),
          ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 0.6),
        ],
        locations: [0.5, 1],
        rect: CGRect(origin: .zero, size: canvas)
      ),
      tracks: [ExtraStyleTrack(
        property: .opacity,
        kind: .keyframes(keys: [ExtraStyleKeyframe(frame: 0, value: 1, easing: .linear)]),
        startFrame: 0,
        paramScale: "vignette"
      )]
    ))

    // Letterbox bars, top and bottom.
    let barHeight = canvas.height * 0.09
    builder.add(extraStyleShapeNode(
      id: "bar-top",
      shape: extraStyleRectShape(width: canvas.width, height: barHeight),
      fill: ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 1),
      position: CGPoint(x: canvas.width / 2, y: barHeight / 2), zIndex: 30
    ))
    builder.add(extraStyleShapeNode(
      id: "bar-bottom",
      shape: extraStyleRectShape(width: canvas.width, height: barHeight),
      fill: ExtraStyleRGBA(r: 0, g: 0, b: 0, a: 1),
      position: CGPoint(x: canvas.width / 2, y: canvas.height - barHeight / 2), zIndex: 30
    ))

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

final class ParallelWorldsExtraStyle: ExtraStyleDefinition {
  let id = "parallel-worlds"
  let version = 1
  let name = "Parallel Worlds"
  let tagline = "Two mirrored worlds, switching on the downbeat."
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
      extraStyleSliderParam(
        id: "distortion", label: "Distortion", min: 0, max: 1, step: 0.05,
        default: 0.5, affects: "motion"
      ),
      extraStyleColorParam(id: "worldAColor", label: "World A colour", default: "#FFD9A0", affects: "appearance"),
      extraStyleColorParam(id: "worldBColor", label: "World B colour", default: "#8FB8FF", affects: "appearance"),
    ]
  }

  var presets: [[String: Any]] {
    [
      ["id": "warm-cool", "label": "Warm / Cool", "values": ["switchMode": "downbeat", "distortion": 0.5]],
      ["id": "neon-split", "label": "Neon split", "values": ["worldAColor": "#FF5C8A", "worldBColor": "#35F2D8", "distortion": 0.8]],
    ]
  }

  var inputs: [String] { ["lines", "words", "intelligence", "audio"] }

  var rebuildParamIds: [String] { ["switchMode", "distortion"] }

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

  // Opacity envelope for one world across the switch list: 1 while
  // the world is active, 0 while the other is, with a 4-frame
  // crossfade either side of each switch.
  private func worldOpacityKeys(switches: [Int], durationFrames: Int, startsActive: Bool) -> [ExtraStyleKeyframe] {
    var keys: [ExtraStyleKeyframe] = []
    var active = startsActive
    func append(frame: Int, value: Double, easing: ExtraStyleEasing) {
      let clamped = max(0, min(durationFrames, frame))
      if let last = keys.last, clamped <= last.frame { return }
      keys.append(ExtraStyleKeyframe(frame: clamped, value: value, easing: easing))
    }
    append(frame: 0, value: active ? 1 : 0, easing: .linear)
    for f in switches {
      append(frame: f - 4, value: active ? 1 : 0, easing: .linear)
      active.toggle()
      append(frame: f + 4, value: active ? 1 : 0, easing: .easeInOutSine)
    }
    append(frame: durationFrames, value: active ? 1 : 0, easing: .linear)
    return keys
  }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let fps = input.fps > 0 ? input.fps : 30
    let durationFrames = input.durationFrames
    let switchMode = extraStyleParamString(input.params, "switchMode", "downbeat")
    let distortion = extraStyleParamDouble(input.params, "distortion", 0.5)
    let worldAColor = extraStyleColor(extraStyleParamString(input.params, "worldAColor", "#FFD9A0"))
    let worldBColor = extraStyleColor(extraStyleParamString(input.params, "worldBColor", "#8FB8FF"))
    let switches = switchFrames(input: input, mode: switchMode)
    var builder = ExtraStyleSceneBuilder()

    builder.add(extraStyleBackgroundGradientNode(
      id: "background", canvas: canvas,
      colors: [
        ExtraStyleRGBA(r: 0.07, g: 0.07, b: 0.09, a: 1),
        ExtraStyleRGBA(r: 0.02, g: 0.02, b: 0.03, a: 1),
      ],
      locations: [0, 1], zIndex: 0
    ))

    // One world group per world. Groups sit at the canvas origin
    // (anchor .zero) so children use absolute canvas coordinates;
    // the group opacity envelope is the world switch. World A is
    // the upper half (text at 0.42H, warm), World B mirrors it
    // across the centre line (text at 0.58H, cool, mirror-written:
    // the engine's scale is uniform, so a true horizontal glyph
    // flip is not expressible — the mirror world renders the line
    // reversed, i.e. mirror-writing).
    func addWorld(
      _ builder: inout ExtraStyleSceneBuilder,
      id: String, tint: ExtraStyleRGBA, colorParamId: String,
      textYFraction: CGFloat, washYFraction: CGFloat,
      mirrored: Bool, startsActive: Bool, label: String, labelPosition: CGPoint
    ) {
      var members: [String] = []
      // Tint wash behind the world's text.
      let washId = "\(id)-wash"
      builder.addChild(ExtraStyleNode(
        id: washId, kind: .gradient,
        position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
        anchor: CGPoint(x: 0.5, y: 0.5),
        zIndex: 0,
        gradient: ExtraStyleGradientContent(
          kind: .radial(
            center: CGPoint(x: canvas.width / 2, y: canvas.height * washYFraction),
            radius: max(canvas.width, canvas.height) * 0.6
          ),
          colors: [tint.withAlpha(0.22), tint.withAlpha(0)],
          colorParamIds: [colorParamId, colorParamId],
          locations: [0, 1],
          rect: CGRect(origin: .zero, size: canvas)
        )
      ))
      members.append(washId)
      // World label.
      let labelId = "\(id)-label"
      builder.addChild(extraStyleTextNode(
        id: labelId,
        text: label, font: ExtraStyleFonts.mono, sizePoints: canvas.width * 0.03,
        color: tint,
        position: labelPosition, zIndex: 1,
        colorParamId: colorParamId
      ))
      members.append(labelId)
      // Per-line text (+ the line's emoji, mirrored in position).
      let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
      for (lineIndex, line) in sortedLines.enumerated() {
        guard let (lineStartFrame, lineEndFrame) = extraStyleLineFrames(line, fps: fps, durationFrames: durationFrames) else { continue }
        let text = mirrored ? String(line.text.reversed()) : line.text
        let textId = "\(id)-line-\(lineIndex)"
        builder.addChild(extraStyleTextNode(
          id: textId,
          text: text, font: ExtraStyleFonts.black, sizePoints: canvas.width * 0.06,
          color: tint,
          position: CGPoint(x: canvas.width / 2, y: canvas.height * textYFraction),
          zIndex: 2,
          visibleRange: lineStartFrame...lineEndFrame,
          maxWidthPoints: canvas.width * 0.88,
          colorParamId: colorParamId,
          tracks: [extraStyleEnterExitOpacityTrack(start: lineStartFrame, end: lineEndFrame)]
        ))
        members.append(textId)
        let emojiYFraction: CGFloat = mirrored ? 0.72 : 0.28
        if let emoji = extraStyleEmojiNode(
          id: "\(id)-emoji-\(lineIndex)", line: line,
          position: CGPoint(x: canvas.width / 2, y: canvas.height * emojiYFraction),
          sizePoints: canvas.width * 0.11, zIndex: 3,
          visibleRange: lineStartFrame...lineEndFrame
        ) {
          builder.addChild(emoji)
          members.append(emoji.id)
        }
      }
      builder.add(ExtraStyleNode(
        id: id, kind: .group,
        children: members,
        position: .zero, anchor: .zero,
        zIndex: 10,
        tracks: [ExtraStyleTrack(
          property: .opacity,
          kind: .keyframes(keys: worldOpacityKeys(switches: switches, durationFrames: durationFrames, startsActive: startsActive)),
          startFrame: 0
        )]
      ))
    }
    addWorld(
      &builder, id: "world-a", tint: worldAColor, colorParamId: "worldAColor",
      textYFraction: 0.42, washYFraction: 0.42, mirrored: false, startsActive: true,
      label: "WORLD A", labelPosition: CGPoint(x: canvas.width * 0.14, y: canvas.height * 0.06)
    )
    addWorld(
      &builder, id: "world-b", tint: worldBColor, colorParamId: "worldBColor",
      textYFraction: 0.58, washYFraction: 0.58, mirrored: true, startsActive: false,
      label: "WORLD B", labelPosition: CGPoint(x: canvas.width * 0.86, y: canvas.height * 0.06)
    )

    // Split-screen divider: a horizontal bar on the centre line,
    // pulsing with the onset envelope.
    builder.add(extraStyleShapeNode(
      id: "divider",
      shape: extraStyleRectShape(width: canvas.width, height: 6),
      fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.85),
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2), zIndex: 30,
      tracks: [ExtraStyleTrack(
        property: .opacity,
        kind: .reaction(input: .onset, base: 0.55, gain: 0.45),
        startFrame: 0
      )]
    ))

    // Split wipe: a bright vertical bar sweeping across at each
    // switch (position keys are offsets from a zero base x, so the
    // values read as absolute canvas x). Between switches it sits
    // off-screen left; it snaps back in one frame after a sweep.
    // A mask-keyframed wipe is not expressible — masks are static
    // on a node and no track property animates them — so the wipe
    // bar + the worlds' opacity crossfade carry the transition.
    var wipeKeys: [ExtraStyleKeyframe] = [ExtraStyleKeyframe(frame: 0, value: -30, easing: .linear)]
    func appendWipe(frame: Int, value: Double, easing: ExtraStyleEasing) {
      let clamped = max(0, min(durationFrames, frame))
      if let last = wipeKeys.last, clamped <= last.frame { return }
      wipeKeys.append(ExtraStyleKeyframe(frame: clamped, value: value, easing: easing))
    }
    for f in switches {
      appendWipe(frame: f - 8, value: -30, easing: .linear)
      appendWipe(frame: f + 8, value: Double(canvas.width) + 30, easing: .easeInOutSine)
      appendWipe(frame: f + 9, value: -30, easing: .linear)
    }
    appendWipe(frame: durationFrames, value: -30, easing: .linear)
    builder.add(extraStyleShapeNode(
      id: "wipe",
      shape: extraStyleRectShape(width: 10, height: canvas.height),
      fill: ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 0.9),
      position: CGPoint(x: 0, y: canvas.height / 2), zIndex: 31,
      tracks: [ExtraStyleTrack(
        property: .positionX,
        kind: .keyframes(keys: wipeKeys),
        startFrame: 0
      )]
    ))

    // Distortion overlay: a displacement node whose wave spikes at
    // every world switch and settles between them. Scale-track
    // values are absolute displacement scales.
    let baseScale = 6 + 34 * distortion
    var distortionKeys: [ExtraStyleKeyframe] = [ExtraStyleKeyframe(frame: 0, value: baseScale * 0.3, easing: .linear)]
    func appendDistortion(frame: Int, value: Double, easing: ExtraStyleEasing) {
      let clamped = max(0, min(durationFrames, frame))
      if let last = distortionKeys.last, clamped <= last.frame { return }
      distortionKeys.append(ExtraStyleKeyframe(frame: clamped, value: value, easing: easing))
    }
    for f in switches {
      appendDistortion(frame: f, value: baseScale * 1.6, easing: .easeOutCubic)
      appendDistortion(frame: f + 18, value: baseScale * 0.3, easing: .easeInOutSine)
    }
    appendDistortion(frame: durationFrames, value: baseScale * 0.3, easing: .linear)
    builder.add(ExtraStyleNode(
      id: "distortion", kind: .displacement,
      position: .zero, anchor: .zero,
      zIndex: 40,
      displacement: ExtraStyleDisplacementContent(baseScale: baseScale, frequency: 0.02),
      tracks: [ExtraStyleTrack(
        property: .scale,
        kind: .keyframes(keys: distortionKeys),
        startFrame: 0
      )]
    ))
    return builder.build(canvas: canvas, durationFrames: durationFrames)
  }
}

// MARK: - Phase 3 registration (cinematic rest)

extension ExtraStylesPhase3 {
  static func registerCinematicRest(into registry: ExtraStyleRegistry) {
    registry.register(MemoryFragmentsExtraStyle())
    registry.register(FloatingUniverseExtraStyle())
    registry.register(FilmCreditsExtraStyle())
    registry.register(ParallelWorldsExtraStyle())
  }
}
