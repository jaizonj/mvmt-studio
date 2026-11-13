import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import ExpoModulesCore
import Foundation
import UniformTypeIdentifiers

// MARK: - Extra Styles 2.0 — core engine (Phase 2)
//
// The independent native motion-graphics & animated lyric engine
// (docs/EXTRA-STYLES-2.0.md). ONE renderer for preview AND export:
// ExtraStylesCompositor (custom AVVideoCompositing, Core Image +
// Core Text + Core Animation), extending the LookVideoCompositor
// pattern — NOT Metal first, NOT the animation-tool path.
//
// The file is organised:
//   1. Helpers (errors, exception guard, FNV-1a, JSON)
//   2. Bridge records (the scene-build input)
//   3. Scene graph types (§4)
//   4. Animation engine (§5) — the TS spec in
//      src/lib/extra-styles/animation.ts, ported exactly
//   5. Style definitions + registry + harness style (§3)
//   6. Prepared scenes, the compositor store, the profiler
//   7. Evaluator (§5.1) + scene renderer (§6.2)
//   8. ExtraStylesCompositor (§6)
//   9. Engine entry points (prepare / update / render / catalog)
//
// FAILURE DISCIPLINE (docs §2.5): a broken scene degrades to the
// video WITHOUT the scene — never a failed export, never a crashed
// preview, never lost lyrics. The compositor never throws inside
// startRequest; scene preparation returns nil instead of throwing
// where a fallback exists. No force unwraps on paths that can see
// user data.
//
// Swift is never compiled locally — CI is the Swift gate. This
// file is written to the same patterns as MvmtCompositorModule.swift
// (same guards, same store discipline, same cache-key hashing) so
// it reads like the module it joins.

// MARK: - 1. Helpers

/// The bridge contract version — mirrors TS
/// EXTRA_STYLES_BRIDGE_VERSION (src/lib/extra-styles/types.ts).
/// The TS side refuses a catalog whose bridgeVersion is NEWER
/// than its own; bump both sides together, never one alone.
let EXTRA_STYLES_BRIDGE_VERSION = 1
/// The engine version (per-style `version` is separate).
let EXTRA_STYLES_ENGINE_VERSION = 1
/// The canonical timeline grid (30 fps integer frames, §5).
let EXTRA_STYLES_FPS = 30.0

/// An ordinary Extra Styles error (same shape as compositorError,
/// which is file-private to MvmtCompositorModule.swift).
func extraStyleError(_ message: String) -> NSError {
  NSError(
    domain: "MVMTExtraStyles",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: message]
  )
}

/// Runs `block` inside an ObjC @try/@catch (same as avTry, which
/// is file-private to MvmtCompositorModule.swift).
@discardableResult
func extraStyleAvTry(_ block: @escaping () -> Void) -> NSException? {
  MvmtExceptionGuard.catching(block)
}

/// FNV-1a 64-bit hash, hex — the cache-key hash (same algorithm
/// eqCacheFileURL uses). Stable across launches.
func extraStyleFnv1aHex(_ input: String) -> String {
  var hash: UInt64 = 0xcbf2_9ce4_8422_2325
  for byte in input.utf8 {
    hash ^= UInt64(byte)
    hash = hash &* 0x0000_0100_0000_01b3
  }
  return String(format: "%016llx", hash)
}

/// Decode a JSON object string into a dictionary. Returns [:] on
/// any failure — params must never fail a scene over bad JSON.
func extraStyleJSONDictionary(_ json: String?) -> [String: Any] {
  guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return [:] }
  guard let value = try? JSONSerialization.jsonObject(with: data),
    let dict = value as? [String: Any]
  else { return [:] }
  return dict
}

/// Encode a JSON-safe value into a string. Returns "{}" on failure.
func extraStyleJSONString(_ value: Any) -> String {
  guard JSONSerialization.isValidJSONObject(value),
    let data = try? JSONSerialization.data(withJSONObject: value),
    let text = String(data: data, encoding: .utf8)
  else { return "{}" }
  return text
}

/// Structural equality for JSON-safe param values (nil == nil;
/// numbers by value; dictionaries by sorted-key serialization —
/// the TS side compares with JSON.stringify the same way).
func extraStyleJSONValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil):
    return true
  case (nil, _), (_, nil):
    return false
  default:
    break
  }
  if let l = lhs as? NSNumber, let r = rhs as? NSNumber {
    // Booleans are NSNumbers too — compare type first so
    // `true` never equals `1`.
    if (l is Bool) != (r is Bool) { return false }
    return l == r
  }
  if let l = lhs as? String, let r = rhs as? String { return l == r }
  guard let l = lhs, let r = rhs,
    JSONSerialization.isValidJSONObject(l),
    JSONSerialization.isValidJSONObject(r),
    let lData = try? JSONSerialization.data(
      withJSONObject: l, options: [.sortedKeys]),
    let rData = try? JSONSerialization.data(
      withJSONObject: r, options: [.sortedKeys])
  else { return false }
  return lData == rData
}

func extraStyleParamDouble(_ params: [String: Any], _ key: String, _ fallback: Double) -> Double {
  if let v = params[key] as? Double, v.isFinite { return v }
  if let v = params[key] as? Int { return Double(v) }
  return fallback
}

func extraStyleParamBool(_ params: [String: Any], _ key: String, _ fallback: Bool) -> Bool {
  if let v = params[key] as? Bool { return v }
  return fallback
}

func extraStyleParamString(_ params: [String: Any], _ key: String, _ fallback: String) -> String {
  if let v = params[key] as? String, !v.isEmpty { return v }
  return fallback
}

/// Parse "#RRGGBB" into RGBA (0...1). Falls back to warm white on
/// any bad value — a bad colour never fails a scene.
func extraStyleColor(_ hex: String, alpha: Double = 1) -> ExtraStyleRGBA {
  var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
  if cleaned.hasPrefix("#") { cleaned.removeFirst() }
  guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
    return ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: CGFloat(alpha))
  }
  return ExtraStyleRGBA(
    r: CGFloat((value >> 16) & 0xff) / 255,
    g: CGFloat((value >> 8) & 0xff) / 255,
    b: CGFloat(value & 0xff) / 255,
    a: CGFloat(alpha)
  )
}

// MARK: - 2. Bridge records

/// One timed word inside a scene-build line (composition seconds).
struct ExtraStyleSceneWordRecord: Record {
  @Field
  var text: String

  @Field
  var startSeconds: Double

  @Field
  var endSeconds: Double
}

/// One lyric line for the scene builder (composition seconds).
/// The stored intelligence rides here UNCONDITIONALLY — no
/// activation gate: the v1 Emoji Story failure (Jaizon never saw
/// one emoji, because the v1 payload carried the emoji only when a
/// template was active) must not recur. A line with an emoji
/// ALWAYS arrives with that emoji.
struct ExtraStyleSceneLineRecord: Record {
  @Field
  var text: String

  @Field
  var startSeconds: Double

  @Field
  var endSeconds: Double

  @Field
  var words: [ExtraStyleSceneWordRecord]? = nil

  @Field
  var emoji: String? = nil

  @Field
  var tone: String? = nil

  @Field
  var emphasisWordIndices: [Int]? = nil

  @Field
  var semanticTags: [String]? = nil
}

/// The scene-build input (docs §3.2). Lines are in COMPOSITION
/// seconds; params are one JSON string (open map); the seed is the
/// TS side's FNV-1a of (styleId + projectId).
struct ExtraStyleSceneBuildInputRecord: Record {
  @Field
  var styleId: String

  @Field
  var paramsJson: String

  @Field
  var layersJson: String? = nil

  @Field
  var lines: [ExtraStyleSceneLineRecord]

  @Field
  var seed: Double

  @Field
  var canvasWidth: Double

  @Field
  var canvasHeight: Double

  @Field
  var durationFrames: Int

  @Field
  var fps: Double? = nil

  @Field
  var automationJson: String? = nil

  @Field
  var maskRefJson: String? = nil
}

// MARK: - 3. Scene graph (docs §4)

/// RGBA colour, components 0...1.
struct ExtraStyleRGBA: Equatable {
  var r: CGFloat
  var g: CGFloat
  var b: CGFloat
  var a: CGFloat

  var cgColor: CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
  }

  func withAlpha(_ alpha: CGFloat) -> ExtraStyleRGBA {
    ExtraStyleRGBA(r: r, g: g, b: b, a: a * alpha)
  }
}

enum ExtraStyleBlendMode: String {
  case normal
  case screen
  case multiply
  case overlay
  case lighten
  case darken

  var cgBlendMode: CGBlendMode {
    switch self {
    case .normal: return .normal
    case .screen: return .screen
    case .multiply: return .multiply
    case .overlay: return .overlay
    case .lighten: return .lighten
    case .darken: return .darken
    }
  }
}

/// A mask on a node (docs §4.1): another node's alpha, the subject
/// mask, or a shape. Masks are NOT nodes.
enum ExtraStyleMask {
  case node(id: String)
  case subject(invert: Bool)
  case shape(path: CGPath)
}

enum ExtraStyleNodeKind {
  case group
  case text
  case shape
  case image
  case emoji
  case particles
  case gradient
  case path
  case displacement
}

struct ExtraStyleTextContent {
  var text: String
  var fontPostScriptName: String
  /// Resolved at build time (points on the canvas).
  var sizePoints: CGFloat
  var color: ExtraStyleRGBA
  /// When set, the colour is re-resolved from the current params
  /// at evaluation time (§8.2 — colour changes swap values with
  /// no rebuild). The glyphs are colour-free, so the layout cache
  /// never goes stale on a colour change.
  var colorParamId: String? = nil
  var strokeColor: ExtraStyleRGBA?
  var strokeWidthPoints: CGFloat
  var alignment: NSTextAlignment
  /// Wrap width in points; nil = a single line.
  var maxWidthPoints: CGFloat?
}

enum ExtraStyleShapeKind {
  case rect(CGRect)
  case ellipse(CGRect)
  case path(CGPath)
  /// A starburst: centre, outer/inner radius, spike count.
  case star(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat, spikes: Int)
}

struct ExtraStyleShapeContent {
  var shape: ExtraStyleShapeKind
  var fill: ExtraStyleRGBA?
  /// When set, the fill is re-resolved from the current params
  /// at evaluation time (§8.2).
  var fillColorParamId: String? = nil
  var stroke: ExtraStyleRGBA?
  var strokeWidth: CGFloat
}

enum ExtraStyleGradientKind {
  case linear(start: CGPoint, end: CGPoint)
  case radial(center: CGPoint, radius: CGFloat)
}

struct ExtraStyleGradientContent {
  var kind: ExtraStyleGradientKind
  var colors: [ExtraStyleRGBA]
  /// Per-colour param ids (parallel to `colors`, nil entries =
  /// baked). When set, the colour is re-resolved from the current
  /// params at evaluation time (§8.2).
  var colorParamIds: [String?]? = nil
  var locations: [CGFloat]?
  /// The area the gradient fills (canvas points).
  var rect: CGRect
}

struct ExtraStylePathContent {
  var path: CGPath
  var strokeColor: ExtraStyleRGBA
  var strokeWidth: CGFloat
  var dash: [CGFloat]?
}

/// A particle emitter (docs §4.2) — an emitter, not a sprite list.
/// The evaluator expands it deterministically per frame (§5.4);
/// no style stores a particle list.
struct ExtraStyleEmitterContent {
  var rate: Double
  /// When set, the rate is re-read from the current params at
  /// evaluation time as (param × rateParamMultiplier) (§8.2 —
  /// density changes swap values; the particle COUNT changes,
  /// never the node count, so no rebuild is needed).
  var rateParamId: String? = nil
  var rateParamMultiplier: Double = 1
  var lifetimeSeconds: Double
  /// Canvas fractions.
  var origin: CGPoint
  var velocity: CGVector
  var spread: CGVector
  var gravity: Double
  var size: Double
  var sizeSpread: Double
  var opacityFrom: Double
  var opacityTo: Double
  var color: ExtraStyleRGBA
  /// When set, the sprite colour is re-resolved from the current
  /// params at evaluation time (§8.2).
  var colorParamId: String? = nil
  /// .softCircle (radial gradient blob) or .square.
  var spriteKind: ExtraStyleSpriteKind
}

enum ExtraStyleSpriteKind {
  case softCircle
  case square
}

/// A full-frame displacement wave (docs §17 #31/#40): the
/// compositor applies CIDisplacementDistortion to the composed
/// frame at this node's scale. The displacement map is a
/// procedural sine pattern, generated once per prepared scene.
struct ExtraStyleDisplacementContent {
  var baseScale: Double
  var frequency: Double
}

/// One node of the scene graph. Position is in canvas points,
/// anchor-relative; the evaluator composes parent transforms.
struct ExtraStyleNode {
  var id: String
  var kind: ExtraStyleNodeKind
  var children: [String] = []
  var position: CGPoint = .zero
  var anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
  var scale: CGFloat = 1
  var rotationDeg: CGFloat = 0
  var opacity: CGFloat = 1
  var zIndex: Int = 0
  var blendMode: ExtraStyleBlendMode = .normal
  var mask: ExtraStyleMask? = nil
  /// Frames the node exists in (nil = the whole scene).
  var visibleRange: ClosedRange<Int>? = nil
  var text: ExtraStyleTextContent? = nil
  var shape: ExtraStyleShapeContent? = nil
  var gradient: ExtraStyleGradientContent? = nil
  var path: ExtraStylePathContent? = nil
  var emitter: ExtraStyleEmitterContent? = nil
  var displacement: ExtraStyleDisplacementContent? = nil
  var imageAssetId: String? = nil
  /// Four corners (canvas points) for a 2.5D perspective warp
  /// (CIPerspectiveTransform on the rasterized subtree). Groups only.
  var perspectiveCorners: [CGPoint]? = nil
  var tracks: [ExtraStyleTrack] = []

  /// Static when it has no tracks and no emitter (emitters are
  /// inherently time-varying): its raster is cacheable (§4.2).
  var isStatic: Bool { tracks.isEmpty && emitter == nil && kind != .displacement }
}

/// A scene: a flat node list + a root group (docs §4.1).
struct ExtraStyleScene {
  var rootId: String
  var nodes: [String: ExtraStyleNode]
  var canvas: CGSize
  var durationFrames: Int
}

// MARK: - 4. Animation engine (docs §5)
//
// Ports src/lib/extra-styles/animation.ts exactly — same seed →
// same scatter, same spring constants → same trajectory. The TS
// tests are the determinism proof for this math.

/// splitmix64 (docs §5.4). The generator is a value type: copy
/// it to fork a stream (per node / per particle).
struct ExtraStyleSeededRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func nextUInt64() -> UInt64 {
    state = state &+ 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }

  mutating func nextDouble() -> Double {
    Double(nextUInt64() >> 11) / Double(1 << 53)
  }

  mutating func nextRange(min: Double, max: Double) -> Double {
    min + nextDouble() * (max - min)
  }
}

enum ExtraStyleEasing {
  case linear
  case easeInCubic
  case easeOutCubic
  case easeInOutCubic
  case easeOutSine
  case easeInOutSine
  case easeOutBack
  case cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double)

  func apply(_ t: Double) -> Double {
    let x = max(0, min(1, t))
    // Exact endpoints (see the TS spec — easeOutBack's closed
    // form lands a float-dust epsilon from 0 at t = 0).
    if x == 0 { return 0 }
    if x == 1 { return 1 }
    switch self {
    case .linear:
      return x
    case .easeInCubic:
      return x * x * x
    case .easeOutCubic:
      let u = 1 - x
      return 1 - u * u * u
    case .easeInOutCubic:
      return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    case .easeOutSine:
      return sin((x * Double.pi) / 2)
    case .easeInOutSine:
      return -(cos(Double.pi * x) - 1) / 2
    case .easeOutBack: {
      let c1 = 1.70158
      let c3 = c1 + 1
      let u = x - 1
      return 1 + c3 * u * u * u + c1 * u * u
    }
    case .cubicBezier(let x1, let y1, let x2, let y2):
      return ExtraStyleEasing.cubicBezierValue(x1: x1, y1: y1, x2: x2, y2: y2, t: x)
    }
  }

  /// Cubic-bezier solve: Newton iteration + bisection fallback,
  /// fixed iteration count — deterministic (TS spec).
  static func cubicBezierValue(x1: Double, y1: Double, x2: Double, y2: Double, t: Double) -> Double {
    let cx = 3 * x1
    let bx = 3 * (x2 - x1) - cx
    let ax = 1 - cx - bx
    let cy = 3 * y1
    let by = 3 * (y2 - y1) - cy
    let ay = 1 - cy - by
    func sampleX(_ u: Double) -> Double { ((ax * u + bx) * u + cx) * u }
    func sampleY(_ u: Double) -> Double { ((ay * u + by) * u + cy) * u }
    func sampleDerivativeX(_ u: Double) -> Double { (3 * ax * u + 2 * bx) * u + cx }
    var u = t
    for _ in 0..<8 {
      let err = sampleX(u) - t
      if abs(err) < 1e-6 { return sampleY(u) }
      let d = sampleDerivativeX(u)
      if abs(d) < 1e-6 { break }
      u -= err / d
    }
    var lo = 0.0
    var hi = 1.0
    u = t
    while hi - lo > 1e-6 {
      if sampleX(u) < t { lo = u } else { hi = u }
      u = (lo + hi) / 2
    }
    return sampleY(u)
  }
}

struct ExtraStyleKeyframe {
  var frame: Int
  var value: Double
  var easing: ExtraStyleEasing
}

func extraStyleInterpolateKeyframes(_ keys: [ExtraStyleKeyframe], frame: Int) -> Double {
  guard !keys.isEmpty else { return 0 }
  let sorted = keys.sorted { $0.frame < $1.frame }
  if frame <= sorted[0].frame { return sorted[0].value }
  let last = sorted[sorted.count - 1]
  if frame >= last.frame { return last.value }
  for i in 0..<(sorted.count - 1) {
    let a = sorted[i]
    let b = sorted[i + 1]
    if frame >= a.frame && frame <= b.frame {
      let span = b.frame - a.frame
      let f = span > 0 ? Double(frame - a.frame) / Double(span) : 0
      return a.value + (b.value - a.value) * b.easing.apply(f)
    }
  }
  return last.value
}

/// Analytic spring (docs §5.2): the damped harmonic oscillator
/// closed form — never numerical integration. Same three regimes
/// as the TS spec.
func extraStyleSpringPosition(
  from: Double, to: Double, stiffness: Double, damping: Double, mass: Double,
  initialVelocity: Double, tSeconds: Double
) -> Double {
  let t = max(0, tSeconds)
  if t == 0 { return from }
  let w0 = sqrt(stiffness / mass)
  let zeta = damping / (2 * sqrt(stiffness * mass))
  let x0 = from - to
  if zeta < 1 {
    let wd = w0 * sqrt(1 - zeta * zeta)
    let a = x0
    let b = (initialVelocity + zeta * w0 * x0) / wd
    return to + exp(-zeta * w0 * t) * (a * cos(wd * t) + b * sin(wd * t))
  }
  if abs(zeta - 1) < 1e-9 {
    let a = x0
    let b = initialVelocity + w0 * x0
    return to + exp(-w0 * t) * (a + b * t)
  }
  let root = w0 * sqrt(zeta * zeta - 1)
  let r1 = -zeta * w0 + root
  let r2 = -zeta * w0 - root
  let a = (initialVelocity - r2 * x0) / (r1 - r2)
  let b = x0 - a
  return to + a * exp(r1 * t) + b * exp(r2 * t)
}

/// One particle's closed-form state (TS spec §5.2): a pure
/// function of (emitter, index, frame, seed).
struct ExtraStyleParticleState {
  var alive: Bool
  var x: Double
  var y: Double
  var size: Double
  var opacity: Double
}

func extraStyleParticleState(
  emitter: ExtraStyleEmitterContent,
  index: Int,
  frame: Int,
  emitterSeed: UInt64,
  fps: Double
) -> ExtraStyleParticleState {
  let dead = ExtraStyleParticleState(alive: false, x: 0, y: 0, size: 0, opacity: 0)
  guard emitter.rate > 0, emitter.lifetimeSeconds > 0 else { return dead }
  var random = ExtraStyleSeededRandom(seed: emitterSeed ^ (UInt64(index + 1) &* 0x9e37_79b9_7f4a_7c15))
  let phase = random.nextDouble()
  let birthIntervalFrames = max(1, Int((fps / emitter.rate).rounded()))
  let birthFrame = index * birthIntervalFrames - Int(phase * Double(birthIntervalFrames))
  let ageFrames = frame - birthFrame
  let lifetimeFrames = max(1, Int((emitter.lifetimeSeconds * fps).rounded()))
  guard ageFrames >= 0, ageFrames < lifetimeFrames else { return dead }
  let ageSeconds = Double(ageFrames) / fps
  let lifeFrac = Double(ageFrames) / Double(lifetimeFrames)
  let vx = Double(emitter.velocity.dx) + (random.nextDouble() - 0.5) * 2 * Double(emitter.spread.dx)
  let vy = Double(emitter.velocity.dy) + (random.nextDouble() - 0.5) * 2 * Double(emitter.spread.dy)
  let sizeFrac = emitter.size + (random.nextDouble() - 0.5) * 2 * emitter.sizeSpread
  let fadeIn = min(1, lifeFrac / 0.1)
  let fadeOut = lifeFrac > 0.7 ? 1 - (lifeFrac - 0.7) / 0.3 : 1
  let opacity = max(0, min(1, emitter.opacityFrom + (emitter.opacityTo - emitter.opacityFrom) * lifeFrac))
    * fadeIn * fadeOut
  return ExtraStyleParticleState(
    alive: true,
    x: Double(emitter.origin.x) + vx * ageSeconds,
    y: Double(emitter.origin.y) + vy * ageSeconds + 0.5 * emitter.gravity * ageSeconds * ageSeconds,
    size: max(0, sizeFrac),
    opacity: opacity
  )
}

/// Arc-length path sampling (TS spec §5.2): position at progress
/// p is a pure function of p.
func extraStyleSamplePath(_ points: [CGPoint], progress: Double) -> CGPoint {
  guard !points.isEmpty else { return .zero }
  if points.count == 1 || progress <= 0 { return points[0] }
  if progress >= 1 { return points[points.count - 1] }
  var lengths: [Double] = [0]
  for i in 1..<points.count {
    let dx = Double(points[i].x - points[i - 1].x)
    let dy = Double(points[i].y - points[i - 1].y)
    lengths.append(lengths[i - 1] + (dx * dx + dy * dy).squareRoot())
  }
  let total = lengths[lengths.count - 1]
  guard total > 0 else { return points[0] }
  let target = progress * total
  for i in 1..<lengths.count where target <= lengths[i] {
    let span = lengths[i] - lengths[i - 1]
    let f = span > 0 ? (target - lengths[i - 1]) / span : 0
    return CGPoint(
      x: points[i - 1].x + (points[i].x - points[i - 1].x) * CGFloat(f),
      y: points[i - 1].y + (points[i].y - points[i - 1].y) * CGFloat(f)
    )
  }
  return points[points.count - 1]
}

// MARK: - Animation tracks (docs §5.2)
//
// A track animates ONE property of ONE node. Phases (entrance /
// continuous / reaction / transformation / exit) are not separate
// systems — they are tracks on the same timeline, distinguished by
// which frames they cover and which input drives them.

enum ExtraStyleTrackProperty {
  case positionX
  case positionY
  case scale
  case rotationDeg
  case opacity
  case red
  case green
  case blue
  case alpha
}

/// What a reaction track reads (docs §5.3, §9.3). Reaction tracks
/// declare their input so the scene builder can verify it exists:
/// a Beat Reactor style without beat data is a build error, caught
/// at scene-build time — never a silent no-op at render time.
enum ExtraStyleReactionInput {
  case onset
  case loudness
  case band(index: Int)
  case beatPhase
  case beatStrength
}

enum ExtraStyleTrackKind {
  case keyframes(keys: [ExtraStyleKeyframe])
  case spring(from: Double, to: Double, stiffness: Double, damping: Double, initialVelocity: Double)
  /// A looping keyframe track. Keys are written against the
  /// NOMINAL period (periodFrames at speed 1); when periodParamId
  /// names a speed param, the period becomes
  /// periodFrames / param and the keys scale with it, so the
  /// shape stays correct at any speed.
  case loop(periodFrames: Int, periodParamId: String?, keys: [ExtraStyleKeyframe])
  case reaction(input: ExtraStyleReactionInput, base: Double, gain: Double)
  /// Path animation: drives positionX + positionY together along
  /// the polyline over [startFrame, startFrame + durationFrames).
  case path(points: [CGPoint], durationFrames: Int, easing: ExtraStyleEasing)
}

struct ExtraStyleTrack {
  var property: ExtraStyleTrackProperty
  var kind: ExtraStyleTrackKind
  var startFrame: Int
  /// Nil = the rest of the scene after startFrame.
  var durationFrames: Int?
  /// When set, the evaluated value is multiplied by the current
  /// numeric param (§8.2 — motion/appearance without rebuild).
  var paramScale: String? = nil
  /// When set, the track is inert while the named Bool param is
  /// false (its end value is used instead).
  var enabledParamId: String? = nil
}

// MARK: - Build input (parsed from the bridge record)

struct ExtraStyleInputWord {
  var text: String
  var startSeconds: Double
  var endSeconds: Double

  init(record: ExtraStyleSceneWordRecord) {
    text = record.text
    startSeconds = record.startSeconds
    endSeconds = record.endSeconds
  }
}

struct ExtraStyleInputLine {
  var text: String
  var startSeconds: Double
  var endSeconds: Double
  var words: [ExtraStyleInputWord]
  var emoji: String?
  var tone: String?
  var emphasisWordIndices: [Int]
  var semanticTags: [String]

  /// Bridge record → parsed input. The stored intelligence rides
  /// through UNCONDITIONALLY — no template gate (the v1 Emoji
  /// Story failure: the payload carried the emoji only when a
  /// template was active, so Jaizon never saw one).
  init(record: ExtraStyleSceneLineRecord) {
    text = record.text
    startSeconds = record.startSeconds
    endSeconds = record.endSeconds
    words = (record.words ?? []).map { ExtraStyleInputWord(record: $0) }
    emoji = record.emoji
    tone = record.tone
    emphasisWordIndices = record.emphasisWordIndices ?? []
    semanticTags = record.semanticTags ?? []
  }
}

/// The parsed scene-build input (docs §3.2): lyric lines + words
/// (composition-frame times), stored intelligence, params, audio
/// automation, subject masks, canvas, seed.
struct ExtraStyleBuildInput {
  var styleId: String
  var params: [String: Any]
  var layers: [String: [String: Any]]
  var lines: [ExtraStyleInputLine]
  var seed: UInt64
  var canvas: CGSize
  var durationFrames: Int
  var fps: Double
  var automation: ExtraStyleAutomationData?
  var maskIndex: ExtraStyleSubjectMaskIndex?
  /// The line active at a composition time (seconds), if any.
  func line(at seconds: Double) -> ExtraStyleInputLine? {
    lines.first { seconds >= $0.startSeconds && seconds < $0.endSeconds }
  }
}

// MARK: - Audio automation data (docs §9.2, parsed once at prep)

struct ExtraStyleAutomationData {
  var tempoBpm: Double
  var beats: [(timeSeconds: Double, isDownbeat: Bool, strength: Double)]
  var beatConfidence: Double
  var onsetHopSeconds: Double
  var onsetValues: [Double]
  var bandHopSeconds: Double
  var bandCentersHz: [Double]
  /// values[hop][band], normalised 0...1.
  var bandValues: [[Double]]
  var loudnessHopSeconds: Double
  var loudnessValues: [Double]

  static func from(json: String?) -> ExtraStyleAutomationData? {
    guard let json, !json.isEmpty, let data = json.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data),
      let dict = value as? [String: Any]
    else { return nil }
    func doubles(_ any: Any?) -> [Double] {
      guard let array = any as? [Any] else { return [] }
      return array.compactMap { ($0 as? NSNumber)?.doubleValue }
    }
    let onset = (dict["onsetEnvelope"] as? [String: Any]) ?? [:]
    let bands = (dict["bandEnergies"] as? [String: Any]) ?? [:]
    let loudness = (dict["loudnessCurve"] as? [String: Any]) ?? [:]
    let beatsArray = (dict["beats"] as? [[String: Any]]) ?? []
    let beats: [(Double, Bool, Double)] = beatsArray.compactMap { beat in
      guard let time = (beat["timeSeconds"] as? NSNumber)?.doubleValue else { return nil }
      return (
        time,
        (beat["isDownbeat"] as? Bool) ?? false,
        (beat["strength"] as? NSNumber)?.doubleValue ?? 0
      )
    }
    let bandValuesRaw = (bands["values"] as? [[Any]]) ?? []
    let bandValues: [[Double]] = bandValuesRaw.map { row in
      row.compactMap { ($0 as? NSNumber)?.doubleValue }
    }
    return ExtraStyleAutomationData(
      tempoBpm: (dict["tempoBpm"] as? NSNumber)?.doubleValue ?? 0,
      beats: beats,
      beatConfidence: (dict["beatConfidence"] as? NSNumber)?.doubleValue ?? 0,
      onsetHopSeconds: (onset["hopSeconds"] as? NSNumber)?.doubleValue ?? 0.1,
      onsetValues: doubles(onset["values"]),
      bandHopSeconds: (bands["hopSeconds"] as? NSNumber)?.doubleValue ?? 0.1,
      bandCentersHz: doubles(bands["bandsHz"]),
      bandValues: bandValues,
      loudnessHopSeconds: (loudness["hopSeconds"] as? NSNumber)?.doubleValue ?? 0.1,
      loudnessValues: doubles(loudness["values"])
    )
  }

  /// Linear interpolation of a hop-sampled curve at a time.
  private func sampleCurve(_ values: [Double], hopSeconds: Double, timeSeconds: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    if values.count == 1 { return values[0] }
    let hop = hopSeconds > 0 ? hopSeconds : 0.1
    let pos = timeSeconds / hop
    let i = Int(floor(pos))
    if i <= 0 { return values[0] }
    if i >= values.count - 1 { return values[values.count - 1] }
    let f = pos - Double(i)
    return values[i] + (values[i + 1] - values[i]) * f
  }

  func onset(at seconds: Double) -> Double {
    sampleCurve(onsetValues, hopSeconds: onsetHopSeconds, timeSeconds: seconds)
  }

  func loudness(at seconds: Double) -> Double {
    sampleCurve(loudnessValues, hopSeconds: loudnessHopSeconds, timeSeconds: seconds)
  }

  func bandEnergies(at seconds: Double) -> [Double] {
    guard !bandValues.isEmpty else { return [] }
    let hop = bandHopSeconds > 0 ? bandHopSeconds : 0.1
    let pos = seconds / hop
    let i = Int(floor(pos))
    func row(_ index: Int) -> [Double] {
      bandValues[max(0, min(bandValues.count - 1, index))]
    }
    if i <= 0 { return row(0) }
    if i >= bandValues.count - 1 { return row(bandValues.count - 1) }
    let f = pos - Double(i)
    let a = row(i)
    let b = row(i + 1)
    return a.enumerated().map { band, v in
      v + ((band < b.count ? b[band] : v) - v) * f
    }
  }

  /// Beat phase at a time — confidence-gated (docs §9.2): below
  /// 0.5 the grid is reported absent and callers fall back to the
  /// onset envelope. A style never renders a wrong beat as if it
  /// were confident.
  func beatPhase(at seconds: Double) -> (framesSinceBeat: Double?, phase: Double?, isDownbeat: Bool, strength: Double)? {
    guard beatConfidence >= 0.5, !beats.isEmpty else { return nil }
    var prevIndex = -1
    var lo = 0
    var hi = beats.count - 1
    while lo <= hi {
      let mid = (lo + hi) / 2
      if beats[mid].timeSeconds <= seconds {
        prevIndex = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    guard prevIndex >= 0 else { return nil }
    let prev = beats[prevIndex]
    let next = prevIndex + 1 < beats.count ? beats[prevIndex + 1] : nil
    var phase: Double? = nil
    if let next {
      let interval = next.timeSeconds - prev.timeSeconds
      if interval > 0 { phase = (seconds - prev.timeSeconds) / interval }
    }
    return (seconds - prev.timeSeconds, phase, prev.isDownbeat, prev.strength)
  }

  /// The reaction value a track reads at a time.
  func reactionValue(_ input: ExtraStyleReactionInput, at seconds: Double) -> Double {
    switch input {
    case .onset:
      return onset(at: seconds)
    case .loudness:
      // Loudness is LUFS-like dB (~-60..0); map to 0...1.
      return max(0, min(1, (loudness(at: seconds) + 60) / 60))
    case .band(let index):
      let energies = bandEnergies(at: seconds)
      guard index >= 0, index < energies.count else { return 0 }
      return energies[index]
    case .beatPhase:
      guard let beat = beatPhase(at: seconds), let phase = beat.phase else { return 0 }
      return 1 - phase
    case .beatStrength:
      return beatPhase(at: seconds)?.strength ?? 0
    }
  }
}

// MARK: - Subject-mask index (docs §10.2, parsed once at prep)

struct ExtraStyleSubjectMaskIndex {
  var version: Int
  var takeKey: String
  var sampleTimesSeconds: [Double]
  var maskUris: [String]
  /// Per sample: face boxes as [x, y, w, h] in 0...1 canvas
  /// fractions (y-down).
  var faces: [(timeSeconds: Double, boxes: [CGRect])]

  static func from(json: String?) -> ExtraStyleSubjectMaskIndex? {
    guard let json, !json.isEmpty, let data = json.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data),
      let dict = value as? [String: Any],
      let takeKey = dict["takeKey"] as? String
    else { return nil }
    func doubles(_ any: Any?) -> [Double] {
      guard let array = any as? [Any] else { return [] }
      return array.compactMap { ($0 as? NSNumber)?.doubleValue }
    }
    let times = doubles(dict["sampleTimesSeconds"])
    let uris = (dict["maskUris"] as? [String]) ?? []
    var faces: [(Double, [CGRect])] = []
    if let facesArray = dict["faces"] as? [[String: Any]] {
      for entry in facesArray {
        guard let time = (entry["timeSeconds"] as? NSNumber)?.doubleValue else { continue }
        let boxesRaw = (entry["boxes"] as? [[Any]]) ?? []
        let boxes: [CGRect] = boxesRaw.compactMap { raw in
          let nums = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
          guard nums.count == 4 else { return nil }
          return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
        }
        faces.append((time, boxes))
      }
    }
    return ExtraStyleSubjectMaskIndex(
      version: (dict["version"] as? NSNumber)?.intValue ?? 1,
      takeKey: takeKey,
      sampleTimesSeconds: times,
      maskUris: uris,
      faces: faces
    )
  }

  /// Face boxes at a time (nearest sample — boxes are small and
  /// change slowly at 2 fps).
  func faceBoxes(at seconds: Double) -> [CGRect] {
    guard !faces.isEmpty else { return [] }
    var best = faces[0]
    var bestDistance = abs(faces[0].timeSeconds - seconds)
    for entry in faces {
      let distance = abs(entry.timeSeconds - seconds)
      if distance < bestDistance {
        best = entry
        bestDistance = distance
      }
    }
    return best.boxes
  }
}

// MARK: - 5. Style definitions + registry (§3)

// NOTE on the v1 templates (Jaizon, 2026-11-13 ~01:25 MST):
// RETIRE all 30 v1 templates when 2.0 ships. There is no legacy
// "Classic Extra Styles" section in this engine and no v1
// rendering path is preserved as a supported mode — the 2.0
// registry holds only 2.0 styles. The TS-side migration
// (migrateV1Template) maps a stored v1 templateId to its 2.0
// successor where one exists, otherwise to classic lyrics.

/// A 2.0 style definition (docs §3.2). `buildScene` is pure:
/// same inputs → same scene. It runs ahead of time, not per frame.
protocol ExtraStyleDefinition {
  var id: String { get }
  var version: Int { get }
  var name: String { get }
  var tagline: String { get }
  var category: String { get }
  var parameters: [[String: Any]] { get }
  var presets: [[String: Any]] { get }
  var inputs: [String] { get }
  var needsAudioAutomation: Bool { get }
  var needsSubjectMasks: Bool { get }
  /// Internal / harness styles never appear in the UI catalog.
  var internalStyle: Bool { get }
  /// Param ids whose change re-runs buildScene (structural params
  /// — layout changes that alter node count or geometry). Every
  /// other param is handled by the evaluator's bindings
  /// (paramScale / enabledParamId / periodParamId / rateParamId /
  /// colorParamId) with NO rebuild (§8.2).
  var rebuildParamIds: [String] { get }
  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene
}

extension ExtraStyleDefinition {
  var rebuildParamIds: [String] { [] }
}

/// The registry is Swift-native (docs §3.1): the scene builders
/// are Swift, and a registry next to its builders cannot drift
/// from them the way the v1 LYRIC_DECOR_KINDS / SWIFT_DECOR_KINDS
/// hand-maintained mirror could.
final class ExtraStyleRegistry {
  static let shared = ExtraStyleRegistry()

  /// The whole catalog's version (separate from per-style versions;
  /// only matters for the metadata cache).
  let registryVersion = 1

  private var definitions: [String: any ExtraStyleDefinition] = [:]

  private init() {
    register(HarnessExtraStyle())
  }

  func register(_ definition: any ExtraStyleDefinition) {
    definitions[definition.id] = definition
  }

  func definition(id: String) -> (any ExtraStyleDefinition)? {
    definitions[id]
  }

  var allDefinitions: [any ExtraStyleDefinition] {
    definitions.values.sorted { $0.id < $1.id }
  }

  /// Catalog metadata JSON (docs §3.1): id, name, tagline,
  /// category, version, parameter schema, preview descriptor, and
  /// whether the style needs audio automation / subject masks.
  /// Small JSON, crossed once per launch, never per frame.
  func catalogJSON() -> String {
    let styles: [[String: Any]] = allDefinitions.map { def in
      var entry: [String: Any] = [
        "id": def.id,
        "version": def.version,
        "name": def.name,
        "tagline": def.tagline,
        "category": def.category,
        "parameters": def.parameters,
        "inputs": def.inputs,
        "needsAudioAutomation": def.needsAudioAutomation,
        "needsSubjectMasks": def.needsSubjectMasks,
      ]
      if !def.presets.isEmpty { entry["presets"] = def.presets }
      if def.internalStyle { entry["internal"] = true }
      return entry
    }
    return extraStyleJSONString([
      "bridgeVersion": EXTRA_STYLES_BRIDGE_VERSION,
      "registryVersion": registryVersion,
      "styles": styles,
    ])
  }
}

/// The harness style (Phase 2 only — NOT one of the 40): a
/// throwaway internal style that proves the pipeline end to end.
/// It exercises text + emoji + gradient + particles + keyframes +
/// springs + stagger + seeded randomness + params, over real lyric
/// lines, through the SAME evaluator the 40 styles will use.
///
/// THE EMOJI CHECK: the harness renders the active line's stored
/// emoji as an emoji node whenever the payload line has one —
/// unconditionally, no gate. If the emoji is missing from the
/// payload, no emoji node is built; the Phase 3 Emoji Storytelling
/// acceptance (emoji visible end-to-end in preview AND export)
/// builds on this path, and the TS test pins the payload side.
final class HarnessExtraStyle: ExtraStyleDefinition {
  let id = "__harness"
  let version = 1
  let name = "Harness"
  let tagline = "Internal pipeline test style — never shown in the UI."
  let category = "experimental"
  let needsAudioAutomation = false
  let needsSubjectMasks = false
  let internalStyle = true

  var parameters: [[String: Any]] {
    [
      [
        "id": "hue", "label": "Hue", "kind": "color",
        "default": "#C9F36B", "affects": "appearance",
      ],
      [
        "id": "density", "label": "Particle density", "kind": "slider",
        "min": 0, "max": 100, "step": 1, "default": 40, "affects": "density",
      ],
      [
        "id": "bounce", "label": "Bounce the line", "kind": "toggle",
        "default": true, "affects": "motion",
      ],
      [
        "id": "speed", "label": "Motion speed", "kind": "slider",
        "min": 0.25, "max": 2, "step": 0.05, "default": 1, "affects": "motion",
      ],
    ]
  }

  var presets: [[String: Any]] { [] }
  var inputs: [String] { ["lines", "words", "intelligence"] }

  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene {
    let canvas = input.canvas
    let hue = extraStyleColor(extraStyleParamString(input.params, "hue", "#C9F36B"))
    let density = extraStyleParamDouble(input.params, "density", 40)
    let fps = input.fps > 0 ? input.fps : 30
    var nodes: [String: ExtraStyleNode] = [:]
    var rootChildren: [String] = []

    func add(_ node: ExtraStyleNode) {
      nodes[node.id] = node
      rootChildren.append(node.id)
    }

    // Background gradient (static — raster-cached). The second
    // colour follows the hue param with no rebuild (§8.2).
    add(ExtraStyleNode(
      id: "background",
      kind: .gradient,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      anchor: CGPoint(x: 0.5, y: 0.5),
      zIndex: 0,
      gradient: ExtraStyleGradientContent(
        kind: .linear(
          start: CGPoint(x: 0, y: 0),
          end: CGPoint(x: canvas.width, y: canvas.height)
        ),
        colors: [
          ExtraStyleRGBA(r: 0.063, g: 0.067, b: 0.071, a: 1),
          hue.withAlpha(0.25),
        ],
        colorParamIds: [nil, "hue"],
        locations: [0, 1],
        rect: CGRect(origin: .zero, size: canvas)
      )
    ))

    // Particle field. Density re-times the emitter rate with no
    // rebuild (rate = density × 0.6); the hue follows the param.
    // The node is ALWAYS added — at rate 0 the evaluator expands
    // no particles, so a project saved at density 0 still regains
    // its field when the user raises the slider.
    add(ExtraStyleNode(
      id: "particles",
      kind: .particles,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      zIndex: 1,
      emitter: ExtraStyleEmitterContent(
        rate: max(0, min(60, density * 0.6)),
        rateParamId: "density",
        rateParamMultiplier: 0.6,
        lifetimeSeconds: 4,
        origin: CGPoint(x: 0.5, y: 0.9),
        velocity: CGVector(dx: 0, dy: -0.08),
        spread: CGVector(dx: 0.12, dy: 0.03),
        gravity: -0.01,
        size: 0.012,
        sizeSpread: 0.006,
        opacityFrom: 0.9,
        opacityTo: 0,
        color: hue,
        colorParamId: "hue",
        spriteKind: .softCircle
      )
    ))

    // One text node per lyric line, with a spring scale-in at the
    // line's start and a slow loop bob while it is up. Word nodes
    // stagger in when the line has timed words.
    let sortedLines = input.lines.sorted { $0.startSeconds < $1.startSeconds }
    for (lineIndex, line) in sortedLines.enumerated() {
      let lineStartFrame = max(0, Int((line.startSeconds * fps).rounded()))
      let lineEndFrame = min(input.durationFrames, Int((line.endSeconds * fps).rounded()))
      guard lineEndFrame > lineStartFrame else { continue }
      let textId = "line-\(lineIndex)"
      let sizePoints = canvas.width * 0.075
      // The spring is always present but inert while the bounce
      // toggle is off (enabledParamId — no rebuild on toggle).
      var tracks: [ExtraStyleTrack] = [
        ExtraStyleTrack(
          property: .scale,
          kind: .spring(from: 0.6, to: 1, stiffness: 140, damping: 11, initialVelocity: 0),
          startFrame: lineStartFrame,
          durationFrames: nil,
          enabledParamId: "bounce"
        ),
      ]
      tracks.append(ExtraStyleTrack(
        property: .opacity,
        kind: .keyframes(keys: [
          ExtraStyleKeyframe(frame: lineStartFrame, value: 0, easing: .linear),
          ExtraStyleKeyframe(frame: min(lineEndFrame, lineStartFrame + 9), value: 1, easing: .easeOutCubic),
          ExtraStyleKeyframe(frame: max(lineStartFrame, lineEndFrame - 9), value: 1, easing: .linear),
          ExtraStyleKeyframe(frame: lineEndFrame, value: 0, easing: .easeInCubic),
        ]),
        startFrame: lineStartFrame,
        durationFrames: nil
      ))
      // Slow loop bob while the line is up. The speed param
      // re-times it with no rebuild (period = 90 / speed).
      tracks.append(ExtraStyleTrack(
        property: .positionY,
        kind: .loop(periodFrames: 90, periodParamId: "speed", keys: [
          ExtraStyleKeyframe(frame: 0, value: 0, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: 45, value: -14, easing: .easeInOutSine),
          ExtraStyleKeyframe(frame: 90, value: 0, easing: .easeInOutSine),
        ]),
        startFrame: lineStartFrame,
        durationFrames: nil
      ))
      add(ExtraStyleNode(
        id: textId,
        kind: .text,
        position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.62),
        zIndex: 10,
        visibleRange: lineStartFrame...lineEndFrame,
        text: ExtraStyleTextContent(
          text: line.text,
          fontPostScriptName: "Helvetica-Bold",
          sizePoints: sizePoints,
          color: ExtraStyleRGBA(r: 0.957, g: 0.945, b: 0.914, a: 1),
          strokeColor: ExtraStyleRGBA(r: 0.063, g: 0.067, b: 0.071, a: 1),
          strokeWidthPoints: max(1, sizePoints * 0.04),
          alignment: .center,
          maxWidthPoints: canvas.width * 0.88
        ),
        tracks: tracks
      ))

      // THE EMOJI NODE: the line's stored emoji, rendered as an
      // emoji glyph above the text with a spring pop — whenever
      // the payload line HAS one. No gate, no template check: the
      // payload is the only source, and the TS test pins that the
      // payload always carries it.
      if let emoji = line.emoji, !emoji.isEmpty {
        add(ExtraStyleNode(
          id: "emoji-\(lineIndex)",
          kind: .emoji,
          position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.62 - sizePoints * 1.6),
          zIndex: 11,
          visibleRange: lineStartFrame...lineEndFrame,
          text: ExtraStyleTextContent(
            text: emoji,
            fontPostScriptName: "AppleColorEmoji",
            sizePoints: sizePoints * 1.1,
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
              startFrame: lineStartFrame,
              durationFrames: nil,
              enabledParamId: "bounce"
            ),
          ]
        ))
      }

      // Word stagger: each timed word gets its own small node
      // that pops in at the word's sung start (docs §5.2).
      for (wordIndex, word) in line.words.enumerated() {
        let wordStartFrame = max(lineStartFrame, Int((word.startSeconds * fps).rounded()))
        let wordEndFrame = min(lineEndFrame, Int((word.endSeconds * fps).rounded()))
        guard wordEndFrame > wordStartFrame else { continue }
        add(ExtraStyleNode(
          id: "word-\(lineIndex)-\(wordIndex)",
          kind: .text,
          position: CGPoint(x: canvas.width / 2, y: canvas.height * 0.62 + sizePoints * 1.4),
          zIndex: 12,
          visibleRange: wordStartFrame...wordEndFrame,
          text: ExtraStyleTextContent(
            text: word.text,
            fontPostScriptName: "Helvetica",
            sizePoints: sizePoints * 0.55,
            color: hue,
            strokeColor: nil,
            strokeWidthPoints: 0,
            alignment: .center,
            maxWidthPoints: canvas.width * 0.88
          ),
          tracks: [
            ExtraStyleTrack(
              property: .opacity,
              kind: .keyframes(keys: [
                ExtraStyleKeyframe(frame: wordStartFrame, value: 0, easing: .linear),
                ExtraStyleKeyframe(frame: min(wordEndFrame, wordStartFrame + 4), value: 1, easing: .easeOutCubic),
                ExtraStyleKeyframe(frame: wordEndFrame, value: 0, easing: .linear),
              ]),
              startFrame: wordStartFrame,
              durationFrames: nil
            ),
          ]
        ))
      }
    }

    let root = ExtraStyleNode(
      id: "root",
      kind: .group,
      children: rootChildren,
      position: .zero,
      anchor: .zero
    )
    nodes["root"] = root
    return ExtraStyleScene(rootId: "root", nodes: nodes, canvas: canvas, durationFrames: input.durationFrames)
  }
}

// MARK: - 6. Prepared scenes, stores, profiler

/// The maximum particles any one emitter may expand per frame
/// (docs §13.1 — fixed-size buffers, never unbounded).
let extraStyleMaxParticlesPerEmitter = 2000

/// A prepared scene: everything the evaluator and renderer need,
/// built ONCE at preparation (docs §6.7). Glyph runs are laid out
/// here (per font/size/text) and reused across frames — the
/// evaluator never re-lays-out text per frame. Particle sprites
/// are rendered lazily by the renderer, keyed by resolved colour
/// and kind, so a colour-param change just mints a new sprite.
final class PreparedExtraStyleScene {
  let handle: String
  let styleId: String
  let styleVersion: Int
  let seed: UInt64
  let fps: Double
  let canvas: CGSize
  let durationFrames: Int
  let automation: ExtraStyleAutomationData?
  let maskIndex: ExtraStyleSubjectMaskIndex?
  /// Lazy mask provider (loads mask files on demand, two-slot cache).
  let maskProvider: ExtraStyleMaskProvider?
  /// The scene graph. Rebuilt only when a structural param changes
  /// (§8.2); motion/appearance/density params swap in `params`
  /// and the evaluator reads them per frame.
  var scene: ExtraStyleScene
  /// Current parameter values (swapped by updateExtraStyleParams
  /// with no rebuild — the evaluator reads them per frame).
  var params: [String: Any]
  /// Bumped on every params swap; the renderer uses it to know a
  /// cached raster may be stale (glyphs are colour-free, so they
  /// never go stale on a colour change).
  var paramsGeneration: Int = 0
  /// Laid-out text per node id: (lines, total height). Built at
  /// preparation; rebuilt when the scene rebuilds.
  var textLayouts: [String: ExtraStyleTextLayout] = [:]
  /// Procedural displacement map (only when a displacement node exists).
  var displacementMap: CIImage? = nil
  /// The lyric lines the scene was built from (for the active-line
  /// lookup at evaluation time).
  let lines: [ExtraStyleInputLine]

  private let lock = NSLock()

  init(
    handle: String,
    styleId: String,
    styleVersion: Int,
    seed: UInt64,
    fps: Double,
    canvas: CGSize,
    durationFrames: Int,
    automation: ExtraStyleAutomationData?,
    maskIndex: ExtraStyleSubjectMaskIndex?,
    scene: ExtraStyleScene,
    params: [String: Any],
    lines: [ExtraStyleInputLine]
  ) {
    self.handle = handle
    self.styleId = styleId
    self.styleVersion = styleVersion
    self.seed = seed
    self.fps = fps
    self.canvas = canvas
    self.durationFrames = durationFrames
    self.automation = automation
    self.maskIndex = maskIndex
    self.maskProvider = maskIndex.map { ExtraStyleMaskProvider(index: $0) }
    self.scene = scene
    self.params = params
    self.lines = lines
  }

  func withParams(_ update: (inout [String: Any]) -> Void) {
    lock.lock()
    update(&params)
    paramsGeneration += 1
    lock.unlock()
  }

  func currentParams() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return params
  }

  func paramDouble(_ key: String, _ fallback: Double) -> Double {
    extraStyleParamDouble(currentParams(), key, fallback)
  }

  func paramBool(_ key: String, _ fallback: Bool) -> Bool {
    extraStyleParamBool(currentParams(), key, fallback)
  }

  func paramColor(_ key: String, fallback: ExtraStyleRGBA) -> ExtraStyleRGBA {
    let params = currentParams()
    guard let hex = params[key] as? String else { return fallback }
    return extraStyleColor(hex)
  }

  /// Param colour with the BAKED alpha kept (a gradient stop at
  /// 0.25 alpha stays at 0.25 when its hue param changes — the
  /// hex carries no alpha of its own).
  func paramColorPreservingAlpha(_ key: String, fallback: ExtraStyleRGBA) -> ExtraStyleRGBA {
    let resolved = paramColor(key, fallback: fallback)
    return ExtraStyleRGBA(r: resolved.r, g: resolved.g, b: resolved.b, a: fallback.a)
  }
}

/// Laid-out text for one node: word-wrapped lines + metrics.
/// Layout is manual (greedy word fill) so the renderer draws in
/// its own y-down space without CTFramesetter coordinate work.
struct ExtraStyleTextLayout {
  var lines: [CTLine]
  /// Per line: width, ascent, descent (points).
  var metrics: [(width: CGFloat, ascent: CGFloat, descent: CGFloat)]
  var totalHeight: CGFloat
  var lineHeight: CGFloat
}

/// Prepared scenes by handle (docs §6.6). A handle lives for the
/// editing session; switching away from a style releases it.
final class ExtraStyleSceneStore {
  static let shared = ExtraStyleSceneStore()
  private let lock = NSLock()
  private var scenes: [String: PreparedExtraStyleScene] = [:]

  func get(_ handle: String) -> PreparedExtraStyleScene? {
    lock.lock()
    defer { lock.unlock() }
    return scenes[handle]
  }

  func put(_ scene: PreparedExtraStyleScene) {
    lock.lock()
    scenes[scene.handle] = scene
    lock.unlock()
  }

  func release(_ handle: String) {
    lock.lock()
    scenes.removeValue(forKey: handle)
    lock.unlock()
  }
}

/// The compositor's static slot (docs §6.3 — the same discipline
/// as LookCompositorStore): the prepared scene + the look the
/// scene compositor folds in. Installed before the player starts,
/// cleared on release. Lock-guarded: owners write from their
/// queues while requests read on AVFoundation's compositor queue.
struct ExtraStyleCompositorSlot {
  var scene: PreparedExtraStyleScene
  var look: LookParamsRecord?
}

enum ExtraStyleCompositorStore {
  private static let lock = NSLock()
  private static var stored: ExtraStyleCompositorSlot?

  static var current: ExtraStyleCompositorSlot? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }
}

/// Render-time profiler (docs §13.1): ms/frame per style, in an
/// in-memory log, surfaced in a debug view and export diagnostics.
/// Device numbers — not simulator numbers — are the verdict.
final class ExtraStyleProfiler {
  static let shared = ExtraStyleProfiler()
  private let lock = NSLock()
  private var evalMs: [String: Double] = [:]
  private var renderMs: [String: Double] = [:]
  private var frames: [String: Int] = [:]

  func record(styleId: String, evalMs: Double, renderMs: Double) {
    lock.lock()
    self.evalMs[styleId, default: 0] += evalMs
    self.renderMs[styleId, default: 0] += renderMs
    frames[styleId, default: 0] += 1
    lock.unlock()
  }

  func snapshotJSON() -> String {
    lock.lock()
    defer { lock.unlock() }
    var styles: [[String: Any]] = []
    for styleId in frames.keys.sorted() {
      let count = max(1, frames[styleId] ?? 1)
      styles.append([
        "styleId": styleId,
        "frames": frames[styleId] ?? 0,
        "avgEvalMs": (evalMs[styleId] ?? 0) / Double(count),
        "avgRenderMs": (renderMs[styleId] ?? 0) / Double(count),
      ])
    }
    return extraStyleJSONString(["styles": styles])
  }
}

// MARK: - 7a. Evaluator (docs §5.1)
//
// Pure: same (scene, frame, inputs) → same output, every time.
// The evaluator's only clock is the frame number it is handed.
// No wall-clock timers, no display refresh, no playback callbacks.

/// One evaluated leaf, fully resolved for the renderer.
struct ExtraStyleEvaluatedNode {
  var node: ExtraStyleNode
  /// Full composed transform (parent chain + own, anchor-aware).
  var transform: CGAffineTransform
  /// Composed opacity (own × parents), 0...1.
  var opacity: CGFloat
  /// Primary colour after colour tracks (text colour / shape fill /
  /// gradient first colour / emitter colour).
  var color: ExtraStyleRGBA
  /// Closed-form particle states for emitter nodes.
  var particles: [ExtraStyleParticleState]
  /// Displacement scale at this frame (displacement nodes only).
  var displacementScale: Double?
}

enum ExtraStyleFrameItem {
  case node(ExtraStyleEvaluatedNode)
  /// A perspective group's children, rasterized together and
  /// warped by the renderer (CIPerspectiveTransform).
  case perspectiveGroup(
    children: [ExtraStyleEvaluatedNode],
    corners: [CGPoint],
    opacity: CGFloat,
    blendMode: ExtraStyleBlendMode
  )
}

struct ExtraStyleFrameState {
  var items: [ExtraStyleFrameItem]
  var frame: Int
}

enum ExtraStyleEvaluator {
  /// Evaluate the track's value at a frame, given the prepared
  /// scene's current params. Track semantics (the evaluator's
  /// contract — styles are built against this):
  ///  - positionX/Y: value is an OFFSET added to the base position.
  ///  - scale: value is the absolute scale factor (× base scale).
  ///  - rotationDeg: value is added to the base rotation.
  ///  - opacity: value is the absolute opacity (× base, × parents).
  ///  - red/green/blue/alpha: value is the absolute channel (0...1).
  ///  - path: the value is the absolute position (canvas points).
  ///  - reaction: base + gain × reaction, then the same rule as
  ///    the property it drives.
  ///  - paramScale: the evaluated value is multiplied by the
  ///    current numeric param (motion/appearance without rebuild).
  ///  - enabledParamId: when the named Bool param is false, the
  ///    track is inert (its `to` / end value is used).
  /// Before startFrame → the track's start value; after its window
  /// ends → frozen at the window's end value.
  static func trackValue(
    _ track: ExtraStyleTrack,
    frame: Int,
    prepared: PreparedExtraStyleScene,
    baseValue: Double
  ) -> Double {
    let params = prepared.currentParams()
    if let enabledId = track.enabledParamId,
      let enabled = params[enabledId] as? Bool, !enabled
    {
      return endValue(track, baseValue: baseValue)
    }
    let start = track.startFrame
    let end = track.durationFrames.map { start + $0 } ?? Int.max
    let atFrame = min(max(frame, start), end)
    var value: Double
    switch track.kind {
    case .keyframes(let keys):
      value = extraStyleInterpolateKeyframes(keys, frame: atFrame)
    case .spring(let from, let to, let stiffness, let damping, let initialVelocity):
      if atFrame <= start {
        value = from
      } else {
        value = extraStyleSpringPosition(
          from: from, to: to, stiffness: stiffness, damping: damping,
          mass: 1, initialVelocity: initialVelocity,
          tSeconds: Double(atFrame - start) / prepared.fps
        )
      }
    case .loop(let periodFrames, let periodParamId, let keys):
      var period = max(1, periodFrames)
      if let periodParamId,
        let speed = params[periodParamId] as? Double, speed > 0
      {
        period = max(1, Int((Double(periodFrames) / speed).rounded()))
      }
      let local = (atFrame - start) % period
      // Keys are written against the nominal period; scale them
      // with the period so the shape stays correct at any speed.
      let nominalPeriod = keys.sorted { $0.frame < $1.frame }.last?.frame ?? period
      let nominal = nominalPeriod > 0
        ? Double(local) * Double(nominalPeriod) / Double(period)
        : 0
      value = extraStyleInterpolateKeyframes(keys, frame: Int(nominal.rounded()))
    case .reaction(let input, let base, let gain):
      let seconds = Double(atFrame) / prepared.fps
      let reaction = prepared.automation?.reactionValue(input, at: seconds) ?? 0
      value = base + gain * reaction
    case .path(let points, let durationFrames, let easing):
      // Path tracks don't produce a scalar — the caller handles
      // them (see evaluateNode). This arm is unreachable for a
      // scalar property; return the base.
      _ = points
      _ = durationFrames
      _ = easing
      value = baseValue
    }
    if let scaleId = track.paramScale,
      let scale = params[scaleId] as? Double, scale.isFinite
    {
      value *= scale
    }
    return value
  }

  /// The value a disabled track contributes (its end state).
  static func endValue(_ track: ExtraStyleTrack, baseValue: Double) -> Double {
    switch track.kind {
    case .keyframes(let keys):
      return keys.sorted { $0.frame < $1.frame }.last?.value ?? baseValue
    case .spring(_, let to, _, _, _):
      return to
    case .loop(_, _, let keys):
      return keys.sorted { $0.frame < $1.frame }.last?.value ?? baseValue
    case .reaction(let input, let base, _):
      _ = input
      return base
    case .path:
      return baseValue
    }
  }

  /// The composed local transform of a node at a frame (before
  /// parenting): anchor → scale → rotate → position.
  /// (Kept as documentation of the contract — the actual transform
  /// is built in resolveNode, which is the single place that does
  /// it, so the walk and the renderer can never disagree.)
  static func evaluate(
    prepared: PreparedExtraStyleScene,
    frame: Int
  ) -> ExtraStyleFrameState {
    let scene = prepared.scene
    var items: [ExtraStyleFrameItem] = []
    guard let root = scene.nodes[scene.rootId] else {
      return ExtraStyleFrameState(items: [], frame: frame)
    }
    // Depth-first walk; children sorted by zIndex within each parent.
    func walk(_ nodeId: String, parentTransform: CGAffineTransform, parentOpacity: CGFloat) {
      guard let node = scene.nodes[nodeId] else { return }
      if let range = node.visibleRange, !range.contains(frame) { return }
      let resolved = resolveNode(node, frame: frame, prepared: prepared)
      let opacity = parentOpacity * resolved.opacity
      guard opacity > 0.001 else { return }
      let transform = parentTransform.concatenating(resolved.localTransform)
      if node.kind == .group {
        if let corners = node.perspectiveCorners, corners.count == 4 {
          // Perspective groups rasterize together: evaluate the
          // children into a sub-list for the renderer to warp.
          var children: [ExtraStyleEvaluatedNode] = []
          for childId in node.children.sorted(by: { zIndex(of: $0, in: scene) < zIndex(of: $1, in: scene) }) {
            collectLeaf(childId, parentTransform: transform, parentOpacity: opacity, into: &children)
          }
          if !children.isEmpty {
            items.append(.perspectiveGroup(
              children: children, corners: corners, opacity: opacity, blendMode: node.blendMode
            ))
          }
          return
        }
        for childId in node.children.sorted(by: { zIndex(of: $0, in: scene) < zIndex(of: $1, in: scene) }) {
          walk(childId, parentTransform: transform, parentOpacity: opacity)
        }
        return
      }
      items.append(.node(ExtraStyleEvaluatedNode(
        node: node,
        transform: transform,
        opacity: opacity,
        color: resolved.color,
        particles: resolved.particles,
        displacementScale: resolved.displacementScale
      )))
    }
    func collectLeaf(
      _ nodeId: String,
      parentTransform: CGAffineTransform,
      parentOpacity: CGFloat,
      into list: inout [ExtraStyleEvaluatedNode]
    ) {
      guard let node = scene.nodes[nodeId] else { return }
      if let range = node.visibleRange, !range.contains(frame) { return }
      let resolved = resolveNode(node, frame: frame, prepared: prepared)
      let opacity = parentOpacity * resolved.opacity
      guard opacity > 0.001 else { return }
      let transform = parentTransform.concatenating(resolved.localTransform)
      if node.kind == .group {
        for childId in node.children.sorted(by: { zIndex(of: $0, in: scene) < zIndex(of: $1, in: scene) }) {
          collectLeaf(childId, parentTransform: transform, parentOpacity: opacity, into: &list)
        }
        return
      }
      list.append(ExtraStyleEvaluatedNode(
        node: node,
        transform: transform,
        opacity: opacity,
        color: resolved.color,
        particles: resolved.particles,
        displacementScale: resolved.displacementScale
      ))
    }
    func zIndex(of nodeId: String, in scene: ExtraStyleScene) -> Int {
      scene.nodes[nodeId]?.zIndex ?? 0
    }
    walk(root.id, parentTransform: .identity, parentOpacity: 1)
    return ExtraStyleFrameState(items: items, frame: frame)
  }

  /// Resolve one node's animated values at a frame: position
  /// offset, scale, rotation, opacity, colour, particles, and the
  /// local transform (anchor-aware). Parenting is the walk's job.
  static func resolveNode(
    _ node: ExtraStyleNode,
    frame: Int,
    prepared: PreparedExtraStyleScene
  ) -> (localTransform: CGAffineTransform, opacity: CGFloat, color: ExtraStyleRGBA, particles: [ExtraStyleParticleState], displacementScale: Double?) {
    // Base values.
    var positionOffset = CGPoint.zero
    var pathPosition: CGPoint? = nil
    var scale = Double(node.scale)
    var rotationDeg = Double(node.rotationDeg)
    var opacity = Double(node.opacity)
    var color = baseColor(of: node, prepared: prepared)
    var displacementScale: Double? = nil

    for track in node.tracks {
      switch track.property {
      case .positionX:
        if case .path(let points, let durationFrames, let easing) = track.kind {
          let start = track.startFrame
          let end = track.durationFrames ?? durationFrames
          let atFrame = min(max(frame, start), start + end)
          let progress = end > 0 ? Double(atFrame - start) / Double(end) : 0
          pathPosition = extraStyleSamplePath(points, progress: easing.apply(progress))
        } else {
          positionOffset.x += CGFloat(trackValue(track, frame: frame, prepared: prepared, baseValue: 0))
        }
      case .positionY:
        positionOffset.y += CGFloat(trackValue(track, frame: frame, prepared: prepared, baseValue: 0))
      case .scale:
        scale *= trackValue(track, frame: frame, prepared: prepared, baseValue: 1)
      case .rotationDeg:
        rotationDeg += trackValue(track, frame: frame, prepared: prepared, baseValue: 0)
      case .opacity:
        opacity *= trackValue(track, frame: frame, prepared: prepared, baseValue: 1)
      case .red:
        color.r = CGFloat(trackValue(track, frame: frame, prepared: prepared, baseValue: Double(color.r)))
      case .green:
        color.g = CGFloat(trackValue(track, frame: frame, prepared: prepared, baseValue: Double(color.g)))
      case .blue:
        color.b = CGFloat(trackValue(track, frame: frame, prepared: prepared, baseValue: Double(color.b)))
      case .alpha:
        color.a = CGFloat(trackValue(track, frame: frame, prepared: prepared, baseValue: Double(color.a)))
      }
    }

    // Node size (for the anchor): from the prepared layout / shape
    // bounds. Emitters and displacement nodes are origin-anchored.
    let size = nodeSize(node, prepared: prepared)
    let position = pathPosition ?? CGPoint(
      x: node.position.x + positionOffset.x,
      y: node.position.y + positionOffset.y
    )
    let local = CGAffineTransform.identity
      .translatedBy(x: position.x, y: position.y)
      .rotated(by: CGFloat(rotationDeg) * .pi / 180)
      .scaledBy(x: CGFloat(scale), y: CGFloat(scale))
      .translatedBy(x: -node.anchor.x * size.width, y: -node.anchor.y * size.height)

    // Particles: closed-form expansion, capped (§13.1). The state
    // function derives birth frames from the emitter's rate, so it
    // gets a copy with the PARAM-RESOLVED rate — otherwise the
    // evaluator's index range (resolved rate) and the state's birth
    // frames (baked rate) disagree when density changes.
    var particles: [ExtraStyleParticleState] = []
    if let emitter = node.emitter {
      let rate = emitterRate(emitter, prepared: prepared)
      if rate > 0 {
        var resolvedEmitter = emitter
        resolvedEmitter.rate = rate
        let birthInterval = max(1, Int((prepared.fps / rate).rounded()))
        let lifetimeFrames = max(1, Int((emitter.lifetimeSeconds * prepared.fps).rounded()))
        let firstIndex = max(0, (frame - lifetimeFrames) / birthInterval)
        let lastIndex = frame / birthInterval
        var count = 0
        for index in firstIndex...lastIndex {
          guard count < extraStyleMaxParticlesPerEmitter else { break }
          let state = extraStyleParticleState(
            emitter: resolvedEmitter, index: index, frame: frame,
            emitterSeed: prepared.seed ^ UInt64(truncatingIfNeeded: node.id.hashValue),
            fps: prepared.fps
          )
          if state.alive {
            particles.append(state)
            count += 1
          }
        }
      }
    }

    if let displacement = node.displacement {
      displacementScale = displacement.baseScale
      // A scale track on a displacement node re-times the wave.
      for track in node.tracks where track.property == .scale {
        displacementScale = trackValue(track, frame: frame, prepared: prepared, baseValue: displacement.baseScale)
      }
    }

    return (
      localTransform: local,
      opacity: CGFloat(max(0, min(1, opacity))),
      color: color,
      particles: particles,
      displacementScale: displacementScale
    )
  }

  /// The node's base primary colour, re-resolved from the current
  /// params when the content names a colour param (§8.2 — colour
  /// changes swap values with no rebuild).
  static func baseColor(of node: ExtraStyleNode, prepared: PreparedExtraStyleScene) -> ExtraStyleRGBA {
    switch node.kind {
    case .text, .emoji:
      guard let text = node.text else { return ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1) }
      if let paramId = text.colorParamId {
        return prepared.paramColor(paramId, fallback: text.color)
      }
      return text.color
    case .shape:
      guard let shape = node.shape else { return ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1) }
      if let paramId = shape.fillColorParamId, let fill = shape.fill {
        return prepared.paramColor(paramId, fallback: fill)
      }
      return shape.fill ?? ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1)
    case .gradient:
      guard let gradient = node.gradient, let first = gradient.colors.first else {
        return ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1)
      }
      if let paramIds = gradient.colorParamIds, let firstId = paramIds.first, let firstId {
        return prepared.paramColor(firstId, fallback: first)
      }
      return first
    case .particles:
      guard let emitter = node.emitter else { return ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1) }
      if let paramId = emitter.colorParamId {
        return prepared.paramColor(paramId, fallback: emitter.color)
      }
      return emitter.color
    default:
      return ExtraStyleRGBA(r: 1, g: 1, b: 1, a: 1)
    }
  }

  /// The emitter's current rate — re-read from params when the
  /// emitter names a rate param (§8.2 — density changes swap
  /// values; the particle COUNT changes, never the node count).
  static func emitterRate(_ emitter: ExtraStyleEmitterContent, prepared: PreparedExtraStyleScene) -> Double {
    if let paramId = emitter.rateParamId {
      return max(0, prepared.paramDouble(paramId, emitter.rate) * emitter.rateParamMultiplier)
    }
    return emitter.rate
  }

  /// A node's local size (for anchor math). Text uses the laid-out
  /// lines; shapes/paths use their bounds; gradients use their
  /// rect; images use the asset size; emitters/displacement are
  /// origin-anchored (zero size).
  static func nodeSize(_ node: ExtraStyleNode, prepared: PreparedExtraStyleScene) -> CGSize {
    switch node.kind {
    case .text, .emoji:
      guard let layout = prepared.textLayouts[node.id] else { return .zero }
      let width = layout.metrics.map { $0.width }.max() ?? 0
      return CGSize(width: width, height: layout.totalHeight)
    case .shape:
      guard let shape = node.shape else { return .zero }
      switch shape.shape {
      case .rect(let rect), .ellipse(let rect):
        return rect.size
      case .path(let path):
        return path.boundingBox.size
      case .star(_, let outerRadius, _, _):
        return CGSize(width: outerRadius * 2, height: outerRadius * 2)
      }
    case .gradient:
      return node.gradient?.rect.size ?? .zero
    case .path:
      return node.path?.path.boundingBox.size ?? .zero
    case .image:
      guard let assetId = node.imageAssetId,
        let size = ExtraStyleAssetRegistry.size(of: assetId)
      else { return .zero }
      return size
    default:
      return .zero
    }
  }
}

// MARK: - 7b. Scene renderer (§6.2)
//
// Draws the evaluated frame state over the graded base and
// returns one CIImage. The scene is drawn into a reusable
// CGBitmapContext in a y-down space (top-left origin, like AV
// space and the JS overlay), then wrapped as a CIImage and
// composited over the base — grade first, scene over it (§6.2:
// scene graphics are designed colours; grading them would shift
// the style's own palette).
//
// Text is laid out ONCE at preparation (manual word wrap —
// greedy fill measured with CTLineGetTypographicBounds), so the
// renderer never re-lays-out text per frame (§6.7). The CTLines
// carry no colour: the fill colour is set in the context at draw
// time, so a colour-param change never invalidates the layout.

/// One laid-out text line (built at preparation).
struct ExtraStyleLaidOutLine {
  var line: CTLine
  var width: CGFloat
  var ascent: CGFloat
  var descent: CGFloat
}

enum ExtraStyleAssetRegistry {
  private static let lock = NSLock()
  private static var cached: [String: CGImage] = [:]

  /// Procedural assets (§11 — procedural-first, no generic
  /// stock). Bundled PNGs ship with the styles that need them in
  /// Phase 3; the registry is id-addressed either way, so a
  /// bundled asset is a data change, not an engine change.
  static func size(of id: String) -> CGSize? {
    switch id {
    case "paper-texture", "halftone-dots":
      return CGSize(width: 256, height: 256)
    case "comic-burst":
      return CGSize(width: 512, height: 512)
    default:
      return nil
    }
  }

  static func image(id: String) -> CGImage? {
    lock.lock()
    if let cachedImage = cached[id] {
      lock.unlock()
      return cachedImage
    }
    lock.unlock()
    guard let size = size(of: id) else { return nil }
    let made: CGImage?
    switch id {
    case "paper-texture":
      made = makePaperTexture(size: size)
    case "halftone-dots":
      made = makeHalftoneDots(size: size)
    case "comic-burst":
      made = makeComicBurst(size: size)
    default:
      made = nil
    }
    if let made {
      lock.lock()
      cached[id] = made
      lock.unlock()
    }
    return made
  }

  private static func bitmapContext(size: CGSize) -> CGContext? {
    let width = max(1, Int(size.width))
    let height = max(1, Int(size.height))
    return CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  }

  /// Warm paper grain: a warm-white field with seeded speckle.
  private static func makePaperTexture(size: CGSize) -> CGImage? {
    guard let context = bitmapContext(size: size) else { return nil }
    context.setFillColor(CGColor(red: 0.957, green: 0.945, blue: 0.914, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    var random = ExtraStyleSeededRandom(seed: 0x5041_5045_5200_0001)
    for _ in 0..<2500 {
      let x = CGFloat(random.nextDouble()) * size.width
      let y = CGFloat(random.nextDouble()) * size.height
      let shade = CGFloat(random.nextDouble()) * 0.08
      context.setFillColor(CGColor(red: 0.5 + shade, green: 0.48 + shade, blue: 0.42 + shade, alpha: 0.5))
      context.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
    }
    return context.makeImage()
  }

  /// Halftone dots: a regular grid of dark dots, fading by row.
  private static func makeHalftoneDots(size: CGSize) -> CGImage? {
    guard let context = bitmapContext(size: size) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0))
    context.fill(CGRect(origin: .zero, size: size))
    let step: CGFloat = 16
    var row = 0
    var y: CGFloat = step / 2
    while y < size.height {
      var x: CGFloat = step / 2
      while x < size.width {
        let radius = max(1, 4 - CGFloat(row) * 0.12)
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        x += step
      }
      row += 1
      y += step
    }
    return context.makeImage()
  }

  /// A 12-spike comic starburst (the v1 JS overlay drew the same
  /// shape with react-native-svg; here it is procedural Core
  /// Graphics, one texture for every style that wants it).
  private static func makeComicBurst(size: CGSize) -> CGImage? {
    guard let context = bitmapContext(size: size) else { return nil }
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let outer = min(size.width, size.height) / 2
    let inner = outer * 0.55
    let path = CGMutablePath()
    for spike in 0..<24 {
      let angle = CGFloat(spike) * .pi / 12 - .pi / 2
      let radius = spike % 2 == 0 ? outer : inner
      let point = CGPoint(
        x: center.x + cos(angle) * radius,
        y: center.y + sin(angle) * radius
      )
      if spike == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1))
    context.setStrokeColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
    context.setLineWidth(6)
    context.addPath(path)
    context.drawPath(using: .fillStroke)
    return context.makeImage()
  }
}

final class ExtraStyleSceneRenderer {
  let canvas: CGSize
  private let ciContext: CIContext
  private var bitmapContext: CGContext?
  private var maskContext: CGContext?
  private var perspectiveContext: CGContext?
  private var spriteCache: [String: CGImage] = [:]
  private let spriteLock = NSLock()

  init(canvas: CGSize) {
    self.canvas = canvas
    self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
  }

  // -- Contexts (reused across requests; recreated on size change) --

  private func mainContext() -> CGContext? {
    let width = max(1, Int(canvas.width))
    let height = max(1, Int(canvas.height))
    if let context = bitmapContext,
      context.width == width, context.height == height
    {
      return context
    }
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    // y-down space (top-left origin), like AV space and the JS
    // overlay — all scene coordinates are addressed that way.
    context.translateBy(x: 0, y: canvas.height)
    context.scaleBy(x: 1, y: -1)
    bitmapContext = context
    return context
  }

  private func tempContext(_ slot: inout CGContext?) -> CGContext? {
    let width = max(1, Int(canvas.width))
    let height = max(1, Int(canvas.height))
    if let context = slot, context.width == width, context.height == height {
      return context
    }
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.translateBy(x: 0, y: canvas.height)
    context.scaleBy(x: 1, y: -1)
    slot = context
    return context
  }

  // -- Text layout (preparation time; the renderer never lays out) --

  /// Greedy word-wrap layout for one text node. Lines carry no
  /// colour (the context supplies it at draw time).
  static func layoutText(_ content: ExtraStyleTextContent) -> ExtraStyleTextLayout {
    guard let font = CTFontCreateWithName(content.fontPostScriptName as CFString, content.sizePoints, nil) else {
      return ExtraStyleTextLayout(lines: [], metrics: [], totalHeight: 0, lineHeight: 0)
    }
    let leading = CTFontGetLeading(font)
    let maxWidth = content.maxWidthPoints ?? .greatestFiniteMagnitude
    // Split into words; a single unbreakable word wider than the
    // max still renders (it is drawn, not shrunk — the width
    // control wraps lines, it never shrinks text to fit).
    let words = content.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    var lineStrings: [String] = []
    if words.isEmpty {
      lineStrings = [content.text]
    } else {
      var current = ""
      for word in words {
        let trial = current.isEmpty ? word : current + " " + word
        if lineWidth(trial, font: font) <= maxWidth || current.isEmpty {
          current = trial
        } else {
          lineStrings.append(current)
          current = word
        }
      }
      if !current.isEmpty { lineStrings.append(current) }
    }
    var lines: [CTLine] = []
    var metrics: [(width: CGFloat, ascent: CGFloat, descent: CGFloat)] = []
    for lineString in lineStrings {
      let attributed = NSAttributedString(
        string: lineString,
        attributes: [NSAttributedString.Key.font: font]
      )
      let line = CTLineCreateWithAttributedString(attributed)
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      var leadingOut: CGFloat = 0
      let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leadingOut))
      lines.append(line)
      metrics.append((width: width, ascent: ascent, descent: descent))
    }
    let lineHeight = metrics.map { $0.ascent + $0.descent }.max() ?? content.sizePoints
    let totalHeight = metrics.reduce(0) { $0 + $1.ascent + $1.descent }
      + leading * CGFloat(max(0, metrics.count - 1))
    return ExtraStyleTextLayout(lines: lines, metrics: metrics, totalHeight: totalHeight, lineHeight: lineHeight)
  }

  private static func lineWidth(_ text: String, font: CTFont) -> CGFloat {
    let attributed = NSAttributedString(
      string: text,
      attributes: [NSAttributedString.Key.font: font]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  // -- Sprites (lazy, keyed by resolved colour + kind) --

  private func sprite(color: ExtraStyleRGBA, kind: ExtraStyleSpriteKind) -> CGImage? {
    let key = "\(kind)-\(Int(color.r * 255))-\(Int(color.g * 255))-\(Int(color.b * 255))"
    spriteLock.lock()
    if let cached = spriteCache[key] {
      spriteLock.unlock()
      return cached
    }
    spriteLock.unlock()
    let size = 64
    guard let context = CGContext(
      data: nil,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    switch kind {
    case .softCircle: {
      let center = CGPoint(x: size / 2, y: size / 2)
      let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
          CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1),
          CGColor(red: color.r, green: color.g, blue: color.b, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
      )
      if let gradient {
        context.drawRadialGradient(
          gradient,
          startCenter: center, startRadius: 0,
          endCenter: center, endRadius: CGFloat(size) / 2,
          options: []
        )
      }
    }
    case .square:
      context.setFillColor(color.cgColor)
      context.fill(CGRect(x: 8, y: 8, width: size - 16, height: size - 16))
    }
    guard let image = context.makeImage() else { return nil }
    spriteLock.lock()
    spriteCache[key] = image
    spriteLock.unlock()
    return image
  }

  // -- Frame render --

  /// Render the scene at a frame over `base` (already graded).
  /// Returns the composite plus timings for the profiler.
  func render(
    prepared: PreparedExtraStyleScene,
    frame: Int,
    base: CIImage
  ) -> (image: CIImage, evalMs: Double, renderMs: Double) {
    let evalStart = CFAbsoluteTimeGetCurrent()
    let state = ExtraStyleEvaluator.evaluate(prepared: prepared, frame: frame)
    let evalMs = (CFAbsoluteTimeGetCurrent() - evalStart) * 1000
    let renderStart = CFAbsoluteTimeGetCurrent()
    guard let context = mainContext() else {
      return (base, evalMs, (CFAbsoluteTimeGetCurrent() - renderStart) * 1000)
    }
    context.clear(CGRect(origin: .zero, size: canvas))
    // Evaluated nodes by id (for node masks).
    var byId: [String: ExtraStyleEvaluatedNode] = [:]
    for item in state.items {
      switch item {
      case .node(let evaluated):
        byId[evaluated.node.id] = evaluated
      case .perspectiveGroup(let children, _, _, _):
        for child in children { byId[child.node.id] = child }
      }
    }
    let seconds = Double(frame) / prepared.fps
    var maxDisplacementScale: Double? = nil
    for item in state.items {
      switch item {
      case .node(let evaluated):
        if let scale = evaluated.displacementScale {
          maxDisplacementScale = max(maxDisplacementScale ?? 0, scale)
          continue
        }
        drawNode(evaluated, in: context, prepared: prepared, byId: byId, seconds: seconds)
      case .perspectiveGroup(let children, let corners, let opacity, let blendMode):
        drawPerspectiveGroup(
          children, corners: corners, opacity: opacity, blendMode: blendMode,
          in: context, prepared: prepared, byId: byId, seconds: seconds
        )
      }
    }
    guard let overlayCG = context.makeImage() else {
      return (base, evalMs, (CFAbsoluteTimeGetCurrent() - renderStart) * 1000)
    }
    var composed = CIImage(cgImage: overlayCG).composited(over: base).cropped(to: base.extent)
    // Displacement waves distort the whole composed frame (§17
    // #31/#40) — the map is procedural, the scale is the node's.
    if let scale = maxDisplacementScale, scale > 0,
      let map = prepared.displacementMap
    {
      if let filter = CIFilter(name: "CIDisplacementDistortion") {
        filter.setValue(composed, forKey: kCIInputImageKey)
        filter.setValue(map, forKey: kCIInputDisplacementImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        if let distorted = filter.outputImage {
          composed = distorted.cropped(to: base.extent)
        }
      }
    }
    let renderMs = (CFAbsoluteTimeGetCurrent() - renderStart) * 1000
    return (composed, evalMs, renderMs)
  }

  // -- Node drawing --

  private func drawNode(
    _ evaluated: ExtraStyleEvaluatedNode,
    in context: CGContext,
    prepared: PreparedExtraStyleScene,
    byId: [String: ExtraStyleEvaluatedNode],
    seconds: Double
  ) {
    let node = evaluated.node
    context.saveGState()
    defer { context.restoreGState() }
    // Canvas-space masks clip BEFORE the node transform (the mask
    // is defined on the canvas, not on the node).
    if let mask = node.mask {
      switch mask {
      case .subject(let invert):
        // The provider hands out the inverted mask pre-computed
        // (Core Graphics has no invert-clip) — see
        // ExtraStyleMaskProvider.
        if let maskImage = prepared.maskProvider?.maskImage(at: seconds, inverted: invert) {
          context.clip(to: CGRect(origin: .zero, size: canvas), mask: maskImage)
        }
      case .node(let maskId):
        if let maskImage = nodeMaskImage(maskId, in: prepared, byId: byId, seconds: seconds) {
          context.clip(to: CGRect(origin: .zero, size: canvas), mask: maskImage)
        }
      case .shape:
        break // Local-space: clipped after the transform, below.
      }
    }
    context.concatenate(evaluated.transform)
    context.setAlpha(evaluated.opacity)
    context.setBlendMode(node.blendMode.cgBlendMode)
    // Local-space mask: the shape path is defined on the node.
    if let mask = node.mask, case .shape(let path) = mask {
      context.addPath(path)
      context.clip()
    }
    switch node.kind {
    case .text, .emoji:
      drawText(evaluated, in: context, prepared: prepared)
    case .shape:
      drawShape(evaluated, in: context, prepared: prepared)
    case .gradient:
      drawGradient(evaluated, in: context, prepared: prepared)
    case .path:
      drawPath(evaluated, in: context, prepared: prepared)
    case .image:
      drawImage(evaluated, in: context, prepared: prepared)
    case .particles:
      drawParticles(evaluated, in: context, prepared: prepared)
    case .group, .displacement:
      break // Groups draw via their children; displacement is a post-effect.
    }
  }

  /// Render a mask node's subtree into the mask temp context and
  /// return it as a CGImage mask (alpha channel). One level only —
  /// a mask node with its own mask is drawn unmasked.
  private func nodeMaskImage(
    _ maskId: String,
    in prepared: PreparedExtraStyleScene,
    byId: [String: ExtraStyleEvaluatedNode],
    seconds: Double
  ) -> CGImage? {
    guard let evaluated = byId[maskId] else { return nil }
    guard var context = tempContext(&maskContext) else { return nil }
    context.clear(CGRect(origin: .zero, size: canvas))
    // Draw the mask node's content at full opacity, normal blend,
    // without its own mask (one level only).
    var plain = evaluated
    plain.opacity = 1
    var nodeCopy = plain.node
    nodeCopy.mask = nil
    nodeCopy.blendMode = .normal
    plain.node = nodeCopy
    context.saveGState()
    context.concatenate(plain.transform)
    switch plain.node.kind {
    case .text, .emoji:
      drawText(plain, in: context, prepared: prepared)
    case .shape:
      drawShape(plain, in: context, prepared: prepared)
    case .gradient:
      drawGradient(plain, in: context, prepared: prepared)
    case .path:
      drawPath(plain, in: context, prepared: prepared)
    case .image:
      drawImage(plain, in: context, prepared: prepared)
    default:
      break
    }
    context.restoreGState()
    return context.makeImage()
  }

  private func drawText(
    _ evaluated: ExtraStyleEvaluatedNode,
    in context: CGContext,
    prepared: PreparedExtraStyleScene
  ) {
    guard let content = evaluated.node.text,
      let layout = prepared.textLayouts[evaluated.node.id],
      !layout.lines.isEmpty
    else { return }
    let color = evaluated.color
    context.setFillColor(color.cgColor)
    if let stroke = content.strokeColor, content.strokeWidthPoints > 0 {
      context.setTextDrawingMode(.fillStroke)
      context.setStrokeColor(stroke.cgColor)
      context.setLineWidth(content.strokeWidthPoints)
    } else {
      context.setTextDrawingMode(.fill)
    }
    let maxWidth = layout.metrics.map { $0.width }.max() ?? 0
    let leading = layout.lines.count > 1
      ? (layout.totalHeight - layout.metrics.reduce(0) { $0 + $1.ascent + $1.descent })
        / CGFloat(layout.lines.count - 1)
      : 0
    var y: CGFloat = 0 // Top of the text block in local space.
    for (index, line) in layout.lines.enumerated() {
      let metric = layout.metrics[index]
      let x: CGFloat
      switch content.alignment {
      case .center:
        x = (maxWidth - metric.width) / 2
      case .right:
        x = maxWidth - metric.width
      default:
        x = 0
      }
      // Baseline: the line's box starts at y; the glyphs sit
      // `ascent` below the top of the box in y-down space.
      let baselineY = y + metric.ascent
      context.textPosition = CGPoint(x: x, y: baselineY)
      CTLineDraw(line, context)
      y += metric.ascent + metric.descent + leading
    }
  }

  private func shapePath(_ shape: ExtraStyleShapeContent) -> CGPath? {
    switch shape.shape {
    case .rect(let rect):
      return CGPath(rect: rect, transform: nil)
    case .ellipse(let rect):
      return CGPath(ellipseIn: rect, transform: nil)
    case .path(let path):
      return path
    case .star(let center, let outerRadius, let innerRadius, let spikes):
      let path = CGMutablePath()
      let total = max(2, spikes) * 2
      for i in 0..<total {
        let angle = CGFloat(i) * .pi / CGFloat(total) - .pi / 2
        let radius = i % 2 == 0 ? outerRadius : innerRadius
        let point = CGPoint(
          x: center.x + cos(angle) * radius,
          y: center.y + sin(angle) * radius
        )
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      path.closeSubpath()
      return path
    }
  }

  private func drawShape(
    _ evaluated: ExtraStyleEvaluatedNode,
    in context: CGContext,
    prepared: PreparedExtraStyleScene
  ) {
    guard let shape = evaluated.node.shape,
      let path = shapePath(shape)
    else { return }
    // Fill comes from evaluated.color (the evaluator already
    // resolved fillColorParamId); the stroke has no param binding.
    if shape.fill != nil {
      context.setFillColor(evaluated.color.cgColor)
      context.addPath(path)
      context.fillPath()
    }
    if let stroke = shape.stroke, shape.strokeWidth > 0 {
      context.setStrokeColor(stroke.cgColor)
      context.setLineWidth(shape.strokeWidth)
      context.addPath(path)
      context.strokePath()
    }
  }

  private func drawGradient(
    _ evaluated: ExtraStyleEvaluatedNode,
    in context: CGContext,
    prepared: PreparedExtraStyleScene
  ) {
    guard let gradient = evaluated.node.gradient else { return }
    // Colours re-resolved per index (alpha-preserving) so a hue
    // param change repaints the gradient with no rebuild (§8.2).
    let colors: [ExtraStyleRGBA] = gradient.colors.enumerated().map { index, baked in
      if let ids = gradient.colorParamIds, index < ids.count, let id = ids[index] {
        return prepared.paramColorPreservingAlpha(id, fallback: baked)
      }
      return baked
    }
    guard let cgGradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: colors.map { $0.cgColor } as CFArray,
      locations: gradient.locations
    ) else { return }
    context.saveGState()
    context.addRect(gradient.rect)
    context.clip()
    switch gradient.kind {
    case .linear(let start, let end):
      context.drawLinearGradient(cgGradient, start: start, end: end, options: [])
    case .radial(let center, let radius):
      context.drawRadialGradient(
        cgGradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius,
        options: []
      )
    }
    context.restoreGState()
  }

  private func drawPath(
    _ evaluated: ExtraStyleEvaluatedNode,
    in context: CGContext,
    prepared: PreparedExtraStyleScene
  ) {
    guard let pathContent = evaluated.node.path else { return }
    // Paths carry their own stroke colour (no param binding on
    // the path content — evaluated.color is white for paths).
    context.setStrokeColor(pathContent.strokeColor.cgColor)
    context.setLineWidth(pathContent.strokeWidth)
    if let dash = pathContent.dash, !dash.isEmpty {
      context.setLineDash(phase: 0, lengths: dash)
    }
    context.addPath(pathContent.path)
    context.strokePath()
  }

  private func drawImage(
    _ evaluated: ExtraStyleEvaluatedNode,
    in context: CGContext,
    prepared: PreparedExtraStyleScene
  ) {
    guard let assetId = evaluated.node.imageAssetId,
      let image = ExtraStyleAssetRegistry.image(id: assetId),
      let size = ExtraStyleAssetRegistry.size(of: assetId)
    else { return }
    context.draw(image, in: CGRect(origin: .zero, size: size))
  }

  private func drawParticles(
    _ evaluated: ExtraStyleEvaluatedNode,
    in context: CGContext,
    prepared: PreparedExtraStyleScene
  ) {
    // Particles live in CANVAS space: the emitter node's
    // transform is ignored (the origin is the emitter's canvas
    // fraction). Only opacity and blend apply.
    guard let emitter = evaluated.node.emitter,
      let sprite = sprite(color: evaluated.color, kind: emitter.spriteKind)
    else { return }
    context.saveGState()
    context.setBlendMode(evaluated.node.blendMode.cgBlendMode)
    for particle in evaluated.particles where particle.alive {
      let sizePoints = CGFloat(particle.size) * canvas.width
      guard sizePoints > 0.5 else { continue }
      let rect = CGRect(
        x: CGFloat(particle.x) * canvas.width - sizePoints / 2,
        y: CGFloat(particle.y) * canvas.height - sizePoints / 2,
        width: sizePoints,
        height: sizePoints
      )
      context.setAlpha(evaluated.opacity * CGFloat(particle.opacity))
      context.draw(sprite, in: rect)
    }
    context.restoreGState()
  }

  private func drawPerspectiveGroup(
    _ children: [ExtraStyleEvaluatedNode],
    corners: [CGPoint],
    opacity: CGFloat,
    blendMode: ExtraStyleBlendMode,
    in context: CGContext,
    prepared: PreparedExtraStyleScene,
    byId: [String: ExtraStyleEvaluatedNode],
    seconds: Double
  ) {
    guard var temp = tempContext(&perspectiveContext) else { return }
    temp.clear(CGRect(origin: .zero, size: canvas))
    for child in children {
      if let scale = child.displacementScale, scale > 0 { continue }
      drawNode(child, in: temp, prepared: prepared, byId: byId, seconds: seconds)
    }
    guard let raster = temp.makeImage() else { return }
    // CIPerspectiveTransform works in CI coordinates (y-up):
    // convert the y-down corners.
    func ciPoint(_ point: CGPoint) -> CIVector {
      CIVector(x: point.x, y: canvas.height - point.y)
    }
    guard corners.count == 4,
      let filter = CIFilter(name: "CIPerspectiveTransform")
    else { return }
    filter.setValue(CIImage(cgImage: raster), forKey: kCIInputImageKey)
    filter.setValue(ciPoint(corners[0]), forKey: "inputTopLeft")
    filter.setValue(ciPoint(corners[1]), forKey: "inputTopRight")
    filter.setValue(ciPoint(corners[2]), forKey: "inputBottomRight")
    filter.setValue(ciPoint(corners[3]), forKey: "inputBottomLeft")
    guard let warped = filter.outputImage,
      let warpedCG = ciContext.createCGImage(warped, from: warped.extent)
    else { return }
    context.saveGState()
    context.setAlpha(opacity)
    context.setBlendMode(blendMode.cgBlendMode)
    context.draw(warpedCG, in: CGRect(origin: .zero, size: canvas))
    context.restoreGState()
  }
}

// MARK: - 8. ExtraStylesCompositor (§6)
//
// A custom AVVideoCompositing implementation on the
// LookVideoCompositor pattern: per request it composites the
// instruction's video layers, applies the Look grade, evaluates
// the scene at the request's frame, and renders the scene over
// the graded base — all through one reused GPU CIContext.
//
// Order is fixed (§6.2): grade the footage first, then composite
// the scene over it. The compositor serves BOTH homes: preview
// compositions (attached by buildComposition) and the transcode's
// single-instruction composition (attached by transcodeAttempt).
// The scene evaluation code is identical in both — only the
// plumbing differs.
//
// FAILURE DISCIPLINE: startRequest runs on AVFoundation's
// compositor queue, where an uncaught exception is a process
// abort. There are no force unwraps and no throwing calls below:
// a missing scene, a failed evaluation, or a failed render
// degrades to the graded composite, and the worst case finishes
// with a plain black frame — never with no finish at all.

final class ExtraStylesCompositor: NSObject, AVVideoCompositing {
  var sourcePixelBufferAttributes: [String: any Sendable]? = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
  ]

  var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
    kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)],
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
  ]

  var supportsHDRSourceFrames: Bool { false }

  private var ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private var renderContext: AVVideoCompositionRenderContext?
  private var renderer: ExtraStyleSceneRenderer?

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    renderContext = newRenderContext
    ciContext = CIContext(options: [.useSoftwareRenderer: false])
    renderer = ExtraStyleSceneRenderer(canvas: newRenderContext.size)
  }

  func cancelAllPendingVideoCompositionRequests() {
    // Requests complete synchronously inside startRequest, so
    // there is never anything pending to cancel.
  }

  private func rampFraction(_ range: CMTimeRange, at time: CMTime) -> Double {
    guard range.duration.isValid, range.start.isValid, time.isValid else { return 0 }
    let duration = range.duration.seconds
    guard duration > 0 else { return 0 }
    return max(0, min(1, (time.seconds - range.start.seconds) / duration))
  }

  private func layerOpacity(
    _ layer: AVVideoCompositionLayerInstruction, at time: CMTime
  ) -> Float {
    var start: Float = 1
    var end: Float = 1
    var range = CMTimeRange(start: .zero, duration: .zero)
    guard
      layer.getOpacityRamp(
        for: time, startOpacity: &start, endOpacity: &end, timeRange: &range)
    else { return 1 }
    if start == end { return start }
    return start + (end - start) * Float(rampFraction(range, at: time))
  }

  private func layerTransform(
    _ layer: AVVideoCompositionLayerInstruction, at time: CMTime
  ) -> CGAffineTransform {
    var start = CGAffineTransform.identity
    var end = CGAffineTransform.identity
    var range = CMTimeRange(start: .zero, duration: .zero)
    guard
      layer.getTransformRamp(
        for: time, start: &start, end: &end, timeRange: &range)
    else { return .identity }
    let f = CGFloat(rampFraction(range, at: time))
    if f <= 0 { return start }
    if f >= 1 { return end }
    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * f }
    return CGAffineTransform(
      a: mix(start.a, end.a), b: mix(start.b, end.b),
      c: mix(start.c, end.c), d: mix(start.d, end.d),
      tx: mix(start.tx, end.tx), ty: mix(start.ty, end.ty)
    )
  }

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    autoreleasepool {
      let renderSize = request.renderContext.size
      guard renderSize.width > 0, renderSize.height > 0,
        let outputBuffer = request.renderContext.newPixelBuffer()
      else {
        request.finish(
          with: NSError(domain: "MVMTExtraStylesCompositor", code: 1, userInfo: nil)
        )
        return
      }
      let renderExtent = CGRect(origin: .zero, size: renderSize)

      // The layer loop is deliberately duplicated from
      // LookVideoCompositor rather than refactored into a shared
      // helper: the proven compositor stays byte-identical, and
      // this class is the only other reader of the pattern.
      var composed = CIImage(color: .black).cropped(to: renderExtent)
      let layerInstructions =
        (request.videoCompositionInstruction as? AVVideoCompositionInstruction)?
        .layerInstructions ?? []
      let time = request.compositionTime
      for layerInstruction in layerInstructions {
        guard
          let sourceBuffer = request.sourceFrame(byTrackID: layerInstruction.trackID)
        else { continue }
        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
        let sourceExtent = sourceImage.extent
        var image = sourceImage
        let opacity = layerOpacity(layerInstruction, at: time)
        if opacity < 0.999 {
          let factor = CGFloat(max(0, min(1, opacity)))
          image = image.applyingFilter(
            "CIColorMatrix",
            parameters: [
              "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
              "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
              "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
              "inputAVector": CIVector(x: 0, y: 0, z: 0, w: factor),
            ]
          )
        }
        let avTransform = layerTransform(layerInstruction, at: time)
        let flipSource = CGAffineTransform(
          a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceExtent.height
        )
        let flipRender = CGAffineTransform(
          a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderSize.height
        )
        let ciTransform =
          flipSource.concatenating(avTransform).concatenating(flipRender)
        image = image.transformed(by: ciTransform)
        composed = image.composited(over: composed)
      }

      // Grade first, then the scene (§6.2).
      var output = composed.cropped(to: renderExtent)
      let slot = ExtraStyleCompositorStore.current
      if let look = slot?.look {
        output = ExtraStyleEngineSupport.gradedImage(output, look: look)
      }

      // Scene: frame-addressable evaluation at the EDL grid, then
      // the scene render. Any failure degrades to the graded
      // composite — the scene never fails a frame.
      if let scene = slot?.scene {
        if renderer == nil || renderer?.canvas != renderSize {
          renderer = ExtraStyleSceneRenderer(canvas: renderSize)
        }
        if let renderer {
          let frame = max(0, Int((time.seconds * scene.fps).rounded()))
          let rendered = renderer.render(prepared: scene, frame: frame, base: output)
          output = rendered.image
          ExtraStyleProfiler.shared.record(
            styleId: scene.styleId, evalMs: rendered.evalMs, renderMs: rendered.renderMs
          )
        }
      }
      ciContext.render(output, to: outputBuffer)
      request.finish(withComposedVideoFrame: outputBuffer)
    }
  }
}

// MARK: - 9. Engine entry points (§6.6)
//
// The bridge-facing surface: catalog, scene preparation, param
// updates, preview frames, release. All of it is synchronous
// CPU work (scene building, text layout, a single frame render);
// the bridge runs it off the main thread, so nothing here blocks
// playback or recording.

enum ExtraStylesEngine {
  // -- Param resolution (Swift mirror of TS resolveExtraStyleParams) --

  /// Resolve bridge values against the schema: unknown ids
  /// dropped, invalid values fall back to the default, numbers
  /// clamped + step-snapped (float dust rounded to 10dp). The
  /// schema here is the definition's `[[String: Any]]` parameter
  /// list — the same JSON shape the catalog hands the UI.
  static func resolveParams(
    schema: [[String: Any]],
    values: [String: Any]
  ) -> [String: Any] {
    var resolved: [String: Any] = [:]
    var byId: [String: [String: Any]] = [:]
    for param in schema {
      guard let id = param["id"] as? String else { continue }
      byId[id] = param
      if let defaultValue = param["default"] { resolved[id] = defaultValue }
    }
    for (id, value) in values {
      guard let param = byId[id] else { continue } // Unknown: dropped.
      guard let kind = param["kind"] as? String,
        isValidValue(value, kind: kind, param: param)
      else { continue } // Invalid: default stands.
      resolved[id] = sanitizeValue(value, param: param)
    }
    return resolved
  }

  private static func isValidValue(
    _ value: Any, kind: String, param: [String: Any]
  ) -> Bool {
    switch kind {
    case "slider", "number":
      return (value as? NSNumber) != nil && !(value is Bool)
    case "toggle":
      return value is Bool
    case "color":
      guard let string = value as? String else { return false }
      return string.range(
        of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    case "segmented", "select", "asset":
      guard let string = value as? String else { return false }
      if let options = param["options"] as? [[String: Any]] {
        return options.contains { ($0["value"] as? String) == string }
      }
      return true
    default:
      return false
    }
  }

  private static func sanitizeValue(_ value: Any, param: [String: Any]) -> Any {
    guard let kind = param["kind"] as? String,
      (kind == "slider" || kind == "number"),
      let number = value as? NSNumber
    else { return value }
    var v = number.doubleValue
    let min = (param["min"] as? NSNumber)?.doubleValue
    let max = (param["max"] as? NSNumber)?.doubleValue
    if let min { v = Swift.max(min, v) }
    if let max { v = Swift.min(max, v) }
    if let step = (param["step"] as? NSNumber)?.doubleValue, step > 0 {
      let base = min ?? 0
      v = base + ((v - base) / step).rounded() * step
      v = (v * 1e10).rounded() / 1e10 // Float dust.
      if let min { v = Swift.max(min, v) }
      if let max { v = Swift.min(max, v) }
    }
    return v
  }

  /// Mirror of TS paramsNeedSceneRebuild (§8.2): rebuild iff a
  /// changed param has `affects: 'layout'` or is listed in the
  /// style's rebuildParamIds. Density/motion/appearance swap
  /// values with no rebuild.
  static func rebuildNeeded(
    schema: [[String: Any]],
    rebuildParamIds: [String],
    oldParams: [String: Any],
    newParams: [String: Any]
  ) -> Bool {
    let listed = Set(rebuildParamIds)
    for param in schema {
      guard let id = param["id"] as? String else { continue }
      let structural =
        (param["affects"] as? String) == "layout" || listed.contains(id)
      guard structural else { continue }
      let oldValue = oldParams[id] ?? param["default"]
      let newValue = newParams[id] ?? param["default"]
      if !extraStyleJSONValuesEqual(oldValue, newValue) { return true }
    }
    return false
  }

  // -- Catalog --

  static func catalogJSON() -> String {
    ExtraStyleRegistry.shared.catalogJSON()
  }

  // -- Scene preparation --

  /// Build + prepare a scene for a style, returning its handle.
  /// Throws on an unknown style, or on a style whose required
  /// inputs (automation / masks) were not supplied — the caller
  /// (bridge.ts) turns that into a notice, never a crash.
  static func prepareScene(_ input: ExtraStyleSceneBuildInputRecord) throws -> String {
    guard let definition = ExtraStyleRegistry.shared.definition(id: input.styleId) else {
      throw extraStyleError(
        "Unknown Extra Style '\(input.styleId)' — no definition in the registry."
      )
    }
    let values = extraStyleJSONDictionary(input.paramsJson)
    let params = resolveParams(schema: definition.parameters, values: values)
    let automation = input.automationJson.flatMap { ExtraStyleAutomationData.from(json: $0) }
    if definition.needsAudioAutomation && automation == nil {
      throw extraStyleError(
        "Style '\(input.styleId)' needs audio automation, but none was prepared."
      )
    }
    let maskIndex = input.maskRefJson.flatMap { ExtraStyleSubjectMaskIndex.from(json: $0) }
    if definition.needsSubjectMasks && maskIndex == nil {
      throw extraStyleError(
        "Style '\(input.styleId)' needs subject masks, but none were prepared."
      )
    }
    var layers: [String: [String: Any]] = [:]
    if let layersJson = input.layersJson {
      for (key, value) in extraStyleJSONDictionary(layersJson) {
        if let dict = value as? [String: Any] { layers[key] = dict }
      }
    }
    let lines = input.lines.map { ExtraStyleInputLine(record: $0) }
    let buildInput = ExtraStyleBuildInput(
      styleId: input.styleId,
      params: params,
      layers: layers,
      lines: lines,
      seed: UInt64(bitPattern: Int64(input.seed)),
      canvas: CGSize(width: input.canvasWidth, height: input.canvasHeight),
      durationFrames: input.durationFrames,
      fps: input.fps ?? EXTRA_STYLES_FPS,
      automation: automation,
      maskIndex: maskIndex
    )
    let scene = definition.buildScene(input: buildInput)
    let prepared = PreparedExtraStyleScene(
      handle: UUID().uuidString,
      styleId: input.styleId,
      styleVersion: definition.version,
      seed: buildInput.seed,
      fps: buildInput.fps,
      canvas: buildInput.canvas,
      durationFrames: input.durationFrames,
      automation: automation,
      maskIndex: maskIndex,
      scene: scene,
      params: params,
      lines: lines
    )
    layoutSceneText(prepared)
    buildDisplacementMapIfNeeded(prepared)
    ExtraStyleSceneStore.shared.put(prepared)
    return prepared.handle
  }

  /// Lay out every text/emoji node in the scene (manual greedy
  /// word wrap). Re-run after a scene rebuild; never per frame.
  static func layoutSceneText(_ prepared: PreparedExtraStyleScene) {
    var layouts: [String: ExtraStyleTextLayout] = [:]
    func walk(_ node: ExtraStyleNode) {
      if let text = node.text {
        layouts[node.id] = ExtraStyleSceneRenderer.layoutText(text)
      }
      for childId in node.children {
        if let child = prepared.scene.nodes[childId] { walk(child) }
      }
    }
    if let root = prepared.scene.nodes[prepared.scene.rootId] { walk(root) }
    prepared.textLayouts = layouts
  }

  /// Generate the procedural displacement map when the scene has
  /// a displacement node (one map per scene, at the first node's
  /// frequency; additional frequencies are rare and reuse it).
  static func buildDisplacementMapIfNeeded(_ prepared: PreparedExtraStyleScene) {
    var frequency: Double? = nil
    func walk(_ node: ExtraStyleNode) {
      if frequency == nil, let displacement = node.displacement {
        frequency = displacement.frequency
      }
      for childId in node.children {
        if let child = prepared.scene.nodes[childId] { walk(child) }
      }
    }
    if let root = prepared.scene.nodes[prepared.scene.rootId] { walk(root) }
    guard let frequency else { return }
    prepared.displacementMap = makeDisplacementMap(frequency: frequency, size: 256)
  }

  /// A seamless displacement map: integer wave counts across the
  /// tile, so it wraps without a seam. Red = x displacement,
  /// green = y displacement (CIDisplacementDistortion's contract).
  static func makeDisplacementMap(frequency: Double, size: Int) -> CIImage? {
    let waves = max(1, Int(frequency.rounded()))
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
      let gy = 128 + 127 * sin(2 * Double.pi * Double(waves) * Double(y) / Double(size))
      for x in 0..<size {
        let gx = 128 + 127 * sin(2 * Double.pi * Double(waves) * Double(x) / Double(size))
        let offset = (y * size + x) * 4
        bytes[offset] = UInt8(max(0, min(255, Int(gx.rounded()))))
        bytes[offset + 1] = UInt8(max(0, min(255, Int(gy.rounded()))))
        bytes[offset + 2] = 128
        bytes[offset + 3] = 255
      }
    }
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: size, height: size,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
      )
    else { return nil }
    return CIImage(cgImage: image)
  }

  // -- Param updates (§8.2) --

  /// Swap params on a prepared scene. Structural changes rebuild
  /// the scene (and re-lay-out text); everything else swaps
  /// values in place — the evaluator reads them per frame.
  static func updateParams(handle: String, paramsJson: String) throws {
    guard let prepared = ExtraStyleSceneStore.shared.get(handle) else {
      throw extraStyleError("Unknown Extra Style scene handle '\(handle)'.")
    }
    guard let definition = ExtraStyleRegistry.shared.definition(id: prepared.styleId) else {
      throw extraStyleError("Style '\(prepared.styleId)' is no longer registered.")
    }
    let values = extraStyleJSONDictionary(paramsJson)
    let newParams = resolveParams(schema: definition.parameters, values: values)
    let oldParams = prepared.currentParams()
    if rebuildNeeded(
      schema: definition.parameters,
      rebuildParamIds: definition.rebuildParamIds,
      oldParams: oldParams,
      newParams: newParams
    ) {
      let buildInput = ExtraStyleBuildInput(
        styleId: prepared.styleId,
        params: newParams,
        layers: [:],
        lines: prepared.lines,
        seed: prepared.seed,
        canvas: prepared.canvas,
        durationFrames: prepared.durationFrames,
        fps: prepared.fps,
        automation: prepared.automation,
        maskIndex: prepared.maskIndex
      )
      prepared.scene = definition.buildScene(input: buildInput)
      layoutSceneText(prepared)
      buildDisplacementMapIfNeeded(prepared)
    }
    prepared.withParams { $0 = newParams }
  }

  // -- Preview frame (§12.3 — card previews; the sample-clip
  //    variant, where the scene renders over a clip frame, is
  //    Phase 3) --

  /// Render one frame of a prepared scene over BLACK at the given
  /// size and return a file:// PNG URI, or nil on failure. The
  /// caller deletes the file when done.
  static func renderPreviewFrame(
    handle: String, frame: Int, width: Double, height: Double
  ) -> String? {
    guard let prepared = ExtraStyleSceneStore.shared.get(handle),
      width > 0, height > 0
    else { return nil }
    let size = CGSize(width: width, height: height)
    let renderer = ExtraStyleSceneRenderer(canvas: size)
    let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
    let rendered = renderer.render(prepared: prepared, frame: max(0, frame), base: black)
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    guard let cgImage = ciContext.createCGImage(rendered.image, from: rendered.image.extent) else {
      return nil
    }
    let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("mvmt-extra-style-frame-\(UUID().uuidString).png")
    guard let url,
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return url.absoluteString
  }

  // -- Release --

  static func releaseScene(handle: String) {
    ExtraStyleSceneStore.shared.release(handle)
  }
}
