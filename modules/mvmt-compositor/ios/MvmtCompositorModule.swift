import AVFoundation
import ExpoModulesCore
import Foundation
import UIKit

// MARK: - JS <-> Swift records (mirror src/index.ts exactly)
//
// NOTE (project history): @Field-wrapped Record properties CANNOT be
// set through the memberwise initializer in this SDK — construct
// records empty and assign each field (see CompositeResultRecord use
// in the engine below).

struct CompositeClipRecord: Record {
  @Field
  var uri: String

  @Field
  var startSeconds: Double

  @Field
  var durationSeconds: Double

  /// Playback rate of the clip's VIDEO (0.25–2, default 1): 0.5 plays
  /// the source at half speed (twice as long on the timeline), 2 at
  /// double speed. The builder re-times the range with
  /// `scaleTimeRange`; the master song is untouched (always 1x).
  @Field
  var speed: Double = 1.0

  /// Transition INTO this clip from the previous one (Edit Modes
  /// Stage 3): 'dip' | 'crossfade'. Nil = hard cut. The first
  /// clip's fields are ignored (no boundary there).
  @Field
  var transitionInKind: String? = nil

  /// Effective half-width of the transition in seconds, computed
  /// by transitionWindows in src/lib/edl.ts (clamped so windows
  /// never overlap and never exceed the neighbouring cuts).
  /// Nil/<=0 = hard cut.
  @Field
  var transitionInHalfSeconds: Double? = nil

  @Field
  var muted: Bool = false

  @Field
  var volume: Double = 1.0
}

struct CompositeRequestRecord: Record {
  @Field
  var clips: [CompositeClipRecord]

  @Field
  var audioUri: String? = nil

  @Field
  var audioStartSeconds: Double = 0

  @Field
  var audioVolume: Double = 1.0

  /// Output canvas width in pixels. Default 1080 (9:16 portrait).
  @Field
  var canvasWidth: Int? = nil

  /// Output canvas height in pixels. Default 1920.
  @Field
  var canvasHeight: Int? = nil

  /// Requested frame rate. Default 30 (the EDL grid); the builder
  /// floors the composition's render grid at 60fps regardless — the
  /// EDL's cut times are CMTime values and stay identical, the finer
  /// grid only keeps every frame of a 60fps capture.
  @Field
  var frameRate: Double? = nil

  /// Caller-chosen id for onExportProgress events + cancelExport.
  @Field
  var exportId: String? = nil

  /// Watermark overlay toggle (logo lockup, corner-flipping).
  /// Nil/false = off.
  @Field
  var watermarkEnabled: Bool? = nil

  /// `file://` URI or path of the transparent watermark PNG. Only
  /// used when watermarkEnabled is true; an unloadable image renders
  /// without the watermark rather than failing the render.
  @Field
  var watermarkImageUri: String? = nil

  /// Timed lyrics to burn into EXPORT renders: line/word timings in
  /// composition seconds plus a fully-resolved style. The JS side
  /// maps its font/animation presets onto these primitives, so the
  /// engine stays catalog-free. Export-only, like the watermark —
  /// previews never carry the animation tool, so the field is inert
  /// there (the JS overlay shows the lyrics instead). Any lyric
  /// problem degrades to rendering without lyrics, never a failure.
  @Field
  var lyrics: LyricsRecord? = nil

  /// A resolved video look (src/lib/looks.ts): ONE numeric param set
  /// the builder maps onto a CI filter chain on the composed frames.
  /// Applies to preview AND export (the grade is part of the
  /// composition). Nil (or the identity set) = no filtering.
  @Field
  var look: LookParamsRecord? = nil

  /// Extra Styles 2.0 (docs/EXTRA-STYLES-2.0.md §6.6): the handle
  /// of a prepared scene (from `prepareExtraStyleScene`). Preview
  /// builds attach ExtraStylesCompositor to the composition
  /// (grade folded in); export builds carry the handle through to
  /// the post-render transcode instead — the transcode's
  /// single-instruction composition is where a custom compositor
  /// and the animation tool already combine freely, while direct
  /// attachment to the export composition is unproven alongside
  /// the animation tool in one AVAssetExportSession pass. The
  /// compositor class is the same either way, so switching to
  /// direct export attachment later is a one-line change in
  /// buildComposition + removing the transcode forcing in render.
  /// Nil = no scene; a stale/unknown handle renders without a
  /// scene, never a failure.
  @Field
  var extraStyleSceneHandle: String? = nil

  /// Export size control — RENDER-ONLY fields (read by `render`,
  /// never by the builder): the export session can't take a bitrate,
  /// so when either is set the finished file is transcoded at an
  /// explicit video bitrate — this one directly…
  @Field
  var exportVideoBitrate: Double? = nil

  /// …or one computed from this target TOTAL file size in MB
  /// (1 MB = 1,000,000 bytes) and the measured duration.
  @Field
  var exportTargetSizeMB: Double? = nil

  /// Codec for the size-control transcode: 'h264' | 'hevc'.
  /// Nil = 'h264'.
  @Field
  var exportCodec: String? = nil

  /// Auto volume: measure the master song and gain it inside the
  /// composition to −14 LUFS (peaks capped at −1 dBFS). Nil/false =
  /// unity gain, the historical behaviour.
  @Field
  var normalizeVolume: Bool? = nil
}

/// The resolved numeric grade of a video look — mirrors
/// src/lib/looks.ts LookParams field-for-field (the bridge converts
/// by name; a mismatch silently empties the field, see the lyric
/// style record's note). Identity = brightness 0, contrast 1,
/// saturation 1, exposureEV 0, temperature 0, vibrance 0, sharpen 0,
/// vignette 0.
struct LookParamsRecord: Record {
  @Field
  var brightness: Double = 0

  @Field
  var contrast: Double = 1

  @Field
  var saturation: Double = 1

  @Field
  var exposureEV: Double = 0

  /// Warmth offset on the 6500K neutral (positive = warmer).
  @Field
  var temperature: Double = 0

  @Field
  var vibrance: Double = 0

  @Field
  var sharpen: Double = 0

  @Field
  var vignette: Double = 0
}

// MARK: - Preview look compositor

/// The resolved look params LookVideoCompositor grades with.
/// The composition builder writes the slot whenever it builds a
/// preview composition with a non-identity look (and points that
/// composition's customVideoCompositorClass at
/// LookVideoCompositor); a graded render transcode writes its
/// pending grade before starting its reader and clears the slot
/// when the attempt finishes. The compositor reads the slot per
/// request. Lock-guarded: owners write from their queues while
/// requests read on AVFoundation's compositor queue. A stale slot
/// is never observable in previews — a preview composition only
/// runs the compositor when the builder just set both the class
/// and the slot for it — and the transcode installs its own grade
/// explicitly rather than relying on whatever a preview left here.
enum LookCompositorStore {
  private static let lock = NSLock()
  private static var stored: LookParamsRecord?

  static var current: LookParamsRecord? {
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

/// Grades frames for the look system by compositing each
/// composition's layer instructions itself and running the shared
/// CI grade chain (MvmtCompositorEngine.gradedImage) over the
/// result. It serves both preview compositions and the single-
/// instruction composition used by a graded render transcode.
///
/// Why a custom compositor at all: the factory CI-filter
/// composition throws on this builder's compositions — previews
/// AND exports crashed on device (2026-11-10) — and produced
/// corrupt transcodes when tried there instead. A custom
/// AVVideoCompositing class is the supported way to post-process
/// an arbitrary composition's frames.
///
/// FAILURE DISCIPLINE IS THE POINT: startRequest runs on
/// AVFoundation's compositor queue, where an uncaught exception is
/// a process abort (the exact SIGABRT this class replaces). There
/// are no force unwraps and no throwing calls below: every failure
/// degrades to the ungraded composite, and the worst case finishes
/// with a plain black frame — never with no finish at all.
final class LookVideoCompositor: NSObject, AVVideoCompositing {
  /// The frames this compositor hands back (via the render
  /// context's buffer pool): BGRA with IOSurface backing, the
  /// shape CIContext renders into most cheaply.
  var sourcePixelBufferAttributes: [String: any Sendable]? = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
  ]

  /// Source frames are accepted as BGRA only — AVFoundation
  /// converts the takes' native formats before handing them over,
  /// so CIImage(cvPixelBuffer:) always sees a layout it reads
  /// directly. (Protocol spelling per the SDK header, learned from
  /// CI 42939378886 + 42941498386: the property is
  /// requiredPixelBufferAttributesForRenderContext — PixelBuffer,
  /// not SourcePixelBuffer — both attribute properties are
  /// Optional, and their values are Sendable-constrained.)
  var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
    kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)],
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
  ]

  /// Sources are SDR camera files; no HDR frame handling.
  var supportsHDRSourceFrames: Bool { false }

  /// GPU-backed context reused across requests (CIContext is
  /// thread-safe and requests arrive serially on the compositor
  /// queue in practice). Recreated when the render context
  /// changes, per the protocol's contract.
  private var ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private var renderContext: AVVideoCompositionRenderContext?

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    renderContext = newRenderContext
    ciContext = CIContext(options: [.useSoftwareRenderer: false])
  }

  func cancelAllPendingVideoCompositionRequests() {
    // Requests complete synchronously inside startRequest, so
    // there is never anything pending to cancel.
  }

  /// A ramp's interpolated fraction at `time` (0 outside/at the
  /// start, 1 at/after the end); nil duration data reads as the
  /// ramp's start value.
  private func rampFraction(_ range: CMTimeRange, at time: CMTime) -> Double {
    guard range.duration.isValid, range.start.isValid, time.isValid else { return 0 }
    let duration = range.duration.seconds
    guard duration > 0 else { return 0 }
    return max(0, min(1, (time.seconds - range.start.seconds) / duration))
  }

  /// Layer opacity at a composition time, via the ramp API —
  /// this SDK's Swift overlay exposes no opacity(at:)
  /// convenience on AVVideoCompositionLayerInstruction
  /// (CI 42943180029). No ramp data = fully opaque; our EDL
  /// sets a static 1.0 per segment anyway.
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

  /// Layer transform at a composition time, via the ramp API
  /// (same reason as layerOpacity). No ramp data = identity;
  /// ramps interpolate component-wise.
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
        // Nowhere to draw: still finish exactly once, with an
        // error — an unfinished request stalls the pipeline.
        request.finish(
          with: NSError(domain: "MVMTLookCompositor", code: 1, userInfo: nil)
        )
        return
      }
      let renderExtent = CGRect(origin: .zero, size: renderSize)

      // Composite the instruction's layers, in array order (later
      // layers over earlier ones), onto a black base — the EDL
      // shape is one full-frame layer at a time (sequential cuts),
      // but the loop is the general one.
      var composed = CIImage(color: .black).cropped(to: renderExtent)
      // videoCompositionInstruction is typed as the protocol in
      // current SDKs; layerInstructions lives on the concrete
      // AVVideoCompositionInstruction class (CI 42939378886). A
      // non-standard instruction type simply yields no layers —
      // a black (or gap) frame, never a crash.
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

        // No crop handling: the EDL builder never sets a crop
        // ramp on its layer instructions (full frames only), and
        // this SDK's Swift overlay exposes no cropRectangle(at:)
        // convenience on AVVideoCompositionLayerInstruction
        // (CI 42941498386) — the ramp API would be dead code for
        // a case that cannot occur in our compositions.

        // Opacity: CI works premultiplied, so scale all four
        // components — the over-composite then blends by exactly
        // the layer's opacity factor.
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

        // Transform: the layer transform is expressed in AV space
        // (top-left origin, y down) over both the source and the
        // render canvas; CI space is bottom-left, y up. Conjugate
        // by the two flips — flip(source) then the AV transform
        // then flip(render) — so framing matches the default
        // compositor's output exactly (identity in, identity out).
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

      // Grade the finished composite with the same chain the
      // export transcode applies. gradedImage pins its output to
      // its input's extent, so hand it exactly the render frame.
      var output = composed.cropped(to: renderExtent)
      if let look = LookCompositorStore.current {
        output = MvmtCompositorEngine.gradedImage(output, look: look)
      }
      ciContext.render(output, to: outputBuffer)
      request.finish(withComposedVideoFrame: outputBuffer)
    }
  }
}

struct LyricWordRecord: Record {
  @Field
  var text: String

  @Field
  var startSeconds: Double

  @Field
  var endSeconds: Double
}

struct LyricLineRecord: Record {
  @Field
  var text: String

  /// Composition seconds.
  @Field
  var startSeconds: Double

  /// Composition seconds.
  @Field
  var endSeconds: Double

  /// Per-word timings for the word-level animation modes
  /// ('stagger' / 'karaoke' / 'typewriter'). Nil/empty = the line
  /// renders and animates as a whole.
  @Field
  var words: [LyricWordRecord]? = nil

  /// Stored lyric intelligence (Extra Styles, Stage 2): the line's
  /// emoji, tone tag, and emphasis word indices. Nil/absent = none.
  /// Renderers read these; they never compute them.
  @Field
  var emoji: String? = nil

  @Field
  var tone: String? = nil

  @Field
  var emphasisWordIndices: [Int]? = nil
}

struct LyricAnimationRecord: Record {
  @Field
  var enterSecs: Double = 0

  @Field
  var exitSecs: Double = 0

  /// Opacity the enter starts from / the exit ends at (0...1).
  @Field
  var fromOpacity: Double = 0

  /// Enter start offset, as a fraction of the line's height.
  @Field
  var fromYOffsetFrac: Double = 0

  /// Enter start offset, as a fraction of the line's width
  /// (horizontal slide presets; the JS catalog resolves it and the
  /// preview overlay applies the same fraction of the same width).
  @Field
  var fromXOffsetFrac: Double = 0

  @Field
  var fromScale: Double = 1

  @Field
  var fromRotateDeg: Double = 0

  /// 'none' | 'stagger' | 'karaoke' | 'typewriter'
  @Field
  var wordMode: String = "none"

  @Field
  var wordStaggerSecs: Double = 0.05

  /// Mid-line scale pulse target; <= 1 = no pulse.
  @Field
  var emphasisScale: Double = 1
}

struct LyricStyleRecord: Record {
  /// PostScript name of the font to render with. Field name must
  /// match the JS payload key exactly (fontPostScriptName) — the
  /// bridge converts by name; a mismatch silently empties the field.
  @Field
  var fontPostScriptName: String

  /// Font size as a fraction of the canvas WIDTH.
  @Field
  var sizeRatio: Double

  @Field
  var color: String

  @Field
  var strokeColor: String? = nil

  /// Stroke thickness as a fraction of the font size.
  @Field
  var strokeWidthRatio: Double? = nil

  /// 'none' | 'pill'
  @Field
  var background: String = "none"

  @Field
  var backgroundColor: String? = nil

  /// 'top' | 'center' | 'bottom'
  @Field
  var position: String = "bottom"

  /// Fine vertical nudge as a fraction of the canvas height,
  /// applied on top of the position anchor (positive = up).
  @Field
  var verticalOffsetRatio: Double? = nil

  /// Maximum line width as a fraction of the canvas width.
  /// Lines wider than this wrap onto more rows.
  @Field
  var maxWidthRatio: Double? = nil

  @Field
  var bold: Bool = false

  @Field
  var animation: LyricAnimationRecord
}

/// An Extra Style template's decor, resolved (Stage 2): every
/// field carries a value (the JS side folds defaults in). The
/// native side applies it generically — one CALayer-subtree builder
/// per `kind` — it has no template catalog.
struct LyricDecorRecord: Record {
  /// 'emoji-row' | 'chat-bubble' | 'comic-burst' | 'sticker-frame'
  /// | 'scanlines' | 'glow' | 'cursor' | 'burst' | 'pill'
  /// | 'rule' | 'spray' | 'shadow' | 'duet' | 'ghost-trail'
  /// | 'rain' | 'bounce' | 'wave-path' | 'typing-dots'
  /// | 'split-screen' | 'none'
  @Field
  var kind: String = "none"

  @Field
  var color: String = "#FFFFFF"

  @Field
  var secondaryColor: String = "#101114"

  @Field
  var opacity: Double = 1

  @Field
  var scale: Double = 1

  @Field
  var text: String = ""

  /// Static rotation of the whole line, degrees (Graffiti).
  /// Applied to the gate layer, outside the line's enter/exit
  /// animation, so it never fights the animation transform.
  @Field
  var rotationDeg: Double = 0

  /// Letter-spacing as a fraction of the font size (Minimal Mono).
  @Field
  var tracking: Double = 0

  /// Horizontal alignment: 'left' | 'center' | 'right'.
  @Field
  var align: String = "center"
}

struct LyricsRecord: Record {
  @Field
  var lines: [LyricLineRecord]

  @Field
  var style: LyricStyleRecord

  /// Extra Style decor for the whole project. Nil = classic style.
  @Field
  var decor: LyricDecorRecord? = nil
}

struct CompositeResultRecord: Record {
  @Field
  var uri: String

  @Field
  var durationSeconds: Double

  @Field
  var width: Int

  @Field
  var height: Int

  /// MEASURED byte size of the delivered file (after any
  /// size-control transcode) — reported from the file system, never
  /// estimated.
  @Field
  var fileSizeBytes: Int = 0

  /// The video bitrate (bps) the size-control transcode applied,
  /// when one ran (a corrective pass reports the final rate).
  /// Nil = the file is the untouched export-session render.
  @Field
  var appliedVideoBitrate: Int? = nil

  /// The loudness gain (dB) auto volume applied to the song inside
  /// the composition. Nil = normalization off, unmeasurable, or the
  /// song counted as silence.
  @Field
  var appliedGainDb: Double? = nil
}

struct AssetInfoRecord: Record {
  @Field
  var durationSeconds: Double

  @Field
  var width: Int

  @Field
  var height: Int

  @Field
  var frameRate: Double

  @Field
  var hasVideo: Bool

  @Field
  var hasAudio: Bool

  /// First video track's timeRange.start (seconds) — where the first
  /// frame sits on the asset timeline. 0 when there is no video track.
  @Field
  var videoStartSeconds: Double = 0

  /// First audio track's timeRange.start (seconds). 0 when no audio track.
  @Field
  var audioStartSeconds: Double = 0

  /// First video track's timeRange.duration (seconds). 0 when none.
  @Field
  var videoDurationSeconds: Double = 0

  /// First audio track's timeRange.duration (seconds). 0 when none.
  @Field
  var audioDurationSeconds: Double = 0
}

struct CaptureStartArgsRecord: Record {
  /// Master song file (`file://` URI or path). Nil = record without a
  /// song clock (video + mic only; no first-frame song position).
  @Field
  var songUri: String? = nil

  /// Where to start inside the master song, in seconds — the internal
  /// player seeks here (zero tolerances) before capture rolls.
  @Field
  var songStartSeconds: Double = 0

  /// Native safety stop: capture finishes itself at this duration so
  /// a hung JS side can never record forever. <= 0 = no limit.
  @Field
  var maxDurationSeconds: Double = 0
}

struct CaptureResultRecord: Record {
  /// `file://` URI of the written mp4 (app caches directory).
  @Field
  var uri: String

  /// MEASURED duration of the written file, in seconds.
  @Field
  var durationSeconds: Double

  /// Measured display size of the written file (rotation applied).
  @Field
  var width: Int

  @Field
  var height: Int

  /// The master song's position (seconds, same timeline as
  /// `songStartSeconds`) at the FIRST captured video frame — measured
  /// natively by anchoring the song player's position to the capture
  /// session's clock (provisional at the first frame, refined at
  /// finish once playback is provably advancing), never estimated.
  /// Nil when no song was supplied or the player never played.
  @Field
  var firstFrameSongPositionSeconds: Double? = nil

  /// Intra-file A/V offset of the written file:
  /// audioTrack.timeRange.start − videoTrack.timeRange.start
  /// (seconds). Nil when the file has no audio track.
  @Field
  var intraFileAvOffsetSeconds: Double? = nil
}

struct TakeSyncMeasurementRecord: Record {
  /// 'measured' | 'noSongInMic' | 'lowConfidence' | 'outOfWindow' | 'error'
  @Field
  var status: String

  /// Song position at the take's first VIDEO frame (seconds into the
  /// master song). Only set when status == 'measured'.
  @Field
  var songPositionAtFirstFrameSeconds: Double? = nil

  /// Intra-file A/V offset: audioTrack.timeRange.start −
  /// videoTrack.timeRange.start (seconds). Set whenever both tracks
  /// exist — a pure file fact, independent of the correlation outcome.
  @Field
  var intraFileAvOffsetSeconds: Double? = nil

  /// Normalised correlation ρ ∈ [0, 1] at the refined peak.
  @Field
  var confidence: Double? = nil

  /// Peak / second-peak ratio (second peak ≥ 50ms from the winner).
  @Field
  var peakRatio: Double? = nil
}

struct WaveformPeaksRecord: Record {
  /// Normalised per-bucket peak amplitudes (0..1, small floor applied
  /// natively so quiet sections still render as tiny bars), evenly
  /// spaced across the track's duration.
  @Field
  var peaks: [Double] = []

  /// The track's duration in seconds — the span the buckets cover.
  @Field
  var durationSeconds: Double = 0
}

// MARK: - Errors

private func compositorError(_ message: String) -> NSError {
  NSError(
    domain: "MvmtCompositor",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: message]
  )
}

// MARK: - NSException guard
//
// Several AVFoundation APIs validate-and-THROW NSExceptions instead
// of returning errors, and Swift cannot catch those — every crash in
// this app's device history was that species (prerollAtRate:, the
// AVAssetWriterInput initialiser validating against a
// sourceFormatHint, -[AVPlayerItem setVideoComposition:] rejecting a
// composition). MvmtExceptionGuard (ObjC, same module) runs a closure
// inside @try/@catch and hands back whatever was raised, so the
// throw-prone calls wrapped with avTry degrade gracefully — a failed
// build, a degraded preview, an aborted take — instead of aborting
// the process. Only genuine validation sites are wrapped; provably
// non-throwing calls (play/pause/seek/startRunning) are NOT, so real
// bugs stay loud.

/// Runs `block` inside an ObjC @try/@catch. Returns the NSException
/// it raised, or nil when it completed normally.
@discardableResult
private func avTry(_ block: @escaping () -> Void) -> NSException? {
  MvmtExceptionGuard.catching(block)
}

/// An ordinary compositor error describing a caught AVFoundation
/// exception — for guarded sites whose failure path is "throw a
/// normal Swift error".
private func exceptionError(_ context: String, _ exception: NSException) -> NSError {
  compositorError("\(context) (\(exception.name.rawValue): \(exception.reason ?? "no reason given"))")
}

/// Guarded `AVMutableCompositionTrack.insertTimeRange`: the bridged
/// Swift error covers most rejections, but out-of-range insertions
/// can also raise an NSException. Both become an ordinary thrown
/// error here, so a take whose metadata lies about its contents
/// fails the build instead of aborting the app.
private func insertTimeRangeGuarded(
  into target: AVMutableCompositionTrack,
  _ range: CMTimeRange,
  of source: AVAssetTrack,
  at start: CMTime,
  _ what: String
) throws {
  var swiftError: Error?
  let exception = avTry {
    do {
      try target.insertTimeRange(range, of: source, at: start)
    } catch {
      swiftError = error
    }
  }
  if let exception {
    throw exceptionError(what, exception)
  }
  if let swiftError {
    throw swiftError
  }
}

/// Guarded `AVMutableCompositionTrack.scaleTimeRange`: the call
/// itself doesn't throw, but an invalid range raises an NSException
/// — it becomes an ordinary thrown error here, like
/// insertTimeRangeGuarded. Used for per-clip speed (Edit Modes
/// Stage 1): re-timing a segment's range on the composition
/// timeline.
private func scaleTimeRangeGuarded(
  _ track: AVMutableCompositionTrack,
  _ range: CMTimeRange,
  toDuration duration: CMTime,
  _ what: String
) throws {
  let exception = avTry {
    track.scaleTimeRange(range, toDuration: duration)
  }
  if let exception {
    throw exceptionError(what, exception)
  }
}

// MARK: - Shared composition builder output

private struct BuiltComposition {
  let composition: AVMutableComposition
  let videoComposition: AVMutableVideoComposition
  let audioMix: AVMutableAudioMix?
  let duration: CMTime
  /// The loudness gain (dB) auto volume applied to the master song
  /// inside this composition, when the request asked for it and a
  /// measurement produced one. Surfaced on the render result; the
  /// preview path ignores it (it just plays the gained mix).
  let appliedGainDb: Double?
  /// EXPORT builds only: the resolved look the render path must
  /// still apply to the finished file (render grades it in the
  /// post-render transcode — see the RULE at the builder's look
  /// application). Always nil for preview builds: their video
  /// composition grades at display time through
  /// LookVideoCompositor instead.
  let pendingGrade: LookParamsRecord?
  /// EXPORT builds only: the Extra Styles 2.0 scene handle the
  /// render path must still apply to the finished file (in the
  /// same post-render transcode as the grade). Always nil for
  /// preview builds: their video composition carries the scene
  /// through ExtraStylesCompositor instead.
  let pendingExtraStyleSceneHandle: String?
}

// MARK: - Loudness measurement support (auto volume)

/// One song region's measured loudness: K-weighted integrated
/// loudness (LUFS) + sample peak (dBFS) — see
/// MvmtCompositorEngine.decodeLoudness.
private struct LoudnessMeasurement {
  let lufs: Double
  let peakDbfs: Double
}

/// Session-scoped loudness cache: compositions rebuild constantly
/// (every look/lyric edit re-previews), and re-decoding the song for
/// each rebuild would stutter the editor. Keys carry the file path +
/// size + mtime + the measured region, so a replaced song file or a
/// different region never reads a stale value.
private final class LoudnessCache {
  static let shared = LoudnessCache()
  private let lock = NSLock()
  private var values: [String: LoudnessMeasurement] = [:]

  func get(_ key: String) -> LoudnessMeasurement? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  func set(_ key: String, _ value: LoudnessMeasurement) {
    lock.lock()
    values[key] = value
    lock.unlock()
  }
}

/// Session-scoped Auto EQ render cache: source key (path + size +
/// mtime + settings version) → the URI compositions should use (the
/// rendered copy, or the original when the song needed no cut).
/// Renders themselves are cached on disk (see eqCacheFileURL), so
/// this only spares the file stat + existence check on rebuilds.
private final class EqRenderCache {
  static let shared = EqRenderCache()
  private let lock = NSLock()
  private var values: [String: String] = [:]

  func get(_ key: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  func set(_ key: String, _ value: String) {
    lock.lock()
    values[key] = value
    lock.unlock()
  }
}

/// RBJ bandpass biquad (constant 0 dB peak gain) for one channel —
/// the analysis filterbank for Auto EQ. Q = 1 keeps each band
/// roughly an octave wide, matching the octave-ish centre spacing,
/// so neighbouring bands overlap gently instead of tiling.
private final class BandpassFilter {
  private let b0: Double
  private let b2: Double
  private let a1: Double
  private let a2: Double
  private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

  init(centerHz: Double, sampleRate: Double) {
    let q = 1.0
    let w0 = 2.0 * Double.pi * centerHz / sampleRate
    let alpha = sin(w0) / (2.0 * q)
    let a0 = 1.0 + alpha
    b0 = alpha / a0
    b2 = -alpha / a0
    a1 = -2.0 * cos(w0) / a0
    a2 = (1.0 - alpha) / a0
  }

  func process(_ x: Double) -> Double {
    let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
    x2 = x1
    x1 = x
    y2 = y1
    y1 = y
    return y
  }
}

/// K-weighting for one channel: the two BS.1770 biquad stages
/// (high-shelf pre-filter, then the RLB high-pass) with the standard
/// 48 kHz coefficients. Applied at the asset's native rate — at
/// 44.1 kHz the shelf's centre shifts slightly, an error well under
/// half a LU for program material; this is a faithful-but-compact
/// measurement, not a broadcast compliance meter.
private final class KWeightingFilter {
  private var shelfX1 = 0.0, shelfX2 = 0.0, shelfY1 = 0.0, shelfY2 = 0.0
  private var rlbX1 = 0.0, rlbX2 = 0.0, rlbY1 = 0.0, rlbY2 = 0.0

  func process(_ x: Double) -> Double {
    let shelf =
      1.53512485958697 * x
      - 2.69169618940638 * shelfX1
      + 1.19839281085285 * shelfX2
      + 1.69065929318241 * shelfY1
      - 0.73248077421585 * shelfY2
    shelfX2 = shelfX1
    shelfX1 = x
    shelfY2 = shelfY1
    shelfY1 = shelf
    let rlb =
      shelf
      - 2.0 * rlbX1
      + rlbX2
      + 1.99004745483398 * rlbY1
      - 0.99007225036621 * rlbY2
    rlbX2 = rlbX1
    rlbX1 = shelf
    rlbY2 = rlbY1
    rlbY1 = rlb
    return rlb
  }
}

// MARK: - Engine (AVFoundation)
//
// ONE builder — buildComposition — powers BOTH export (render) and
// native preview (PreviewStore.create), so what you preview is what
// renders. Nothing else in the app builds compositions. ONE carve-out:
// the CoreAnimation tool (watermark + burned-in lyrics) is attached
// for EXPORT builds only
// (the forExport flag) — assigning a videoComposition that carries an
// animation tool to a preview player item throws on device
// (crash log MVMTStudio-2026-11-09-220942); the app overlays the logo
// in previews at the JS layer instead.

// MARK: - Extra Styles 2.0 support
//
// Narrow internal surface for the Extra Styles engine
// (ExtraStyles*.swift). MvmtCompositorEngine is file-private, so
// the two calls the scene compositor needs — URL resolution and
// the Look grade — are forwarded here rather than widening the
// whole engine's visibility. Nothing else in the engine is
// exposed; the scene compositor never touches compositions,
// export sessions, or capture.
enum ExtraStyleEngineSupport {
  static func resolveURL(_ raw: String) -> URL {
    MvmtCompositorEngine.resolveURL(raw)
  }

  static func gradedImage(_ source: CIImage, look: LookParamsRecord) -> CIImage {
    MvmtCompositorEngine.gradedImage(source, look: look)
  }
}

private enum MvmtCompositorEngine {
  /// File paths may arrive as `file://` URIs or plain paths.
  static func resolveURL(_ raw: String) -> URL {
    if raw.hasPrefix("/") {
      return URL(fileURLWithPath: raw)
    }
    return URL(string: raw) ?? URL(fileURLWithPath: raw)
  }

  // MARK: Shared builder

  static func buildComposition(
    _ request: CompositeRequestRecord,
    forExport: Bool,
    includeAnimationTool: Bool = true,
    includeAudioMix: Bool = true
  ) async throws -> BuiltComposition {
    let clips = request.clips
    guard !clips.isEmpty else {
      throw compositorError("At least one clip is required to build a composition.")
    }
    for (index, clip) in clips.enumerated() where clip.durationSeconds <= 0 {
      throw compositorError("Clip \(index + 1) has a non-positive duration (\(clip.durationSeconds)s).")
    }

    // ---- Project canvas + frame rate (v2: no longer first-clip canvas) ----
    let canvasWidth = request.canvasWidth ?? 1080
    let canvasHeight = request.canvasHeight ?? 1920
    guard canvasWidth > 0, canvasHeight > 0 else {
      throw compositorError("Invalid canvas size \(canvasWidth)x\(canvasHeight).")
    }
    let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

    let frameRate = request.frameRate ?? 30
    guard frameRate >= 1, frameRate <= 240 else {
      throw compositorError("Invalid frame rate \(frameRate).")
    }

    let timescale: CMTimeScale = 600
    let composition = AVMutableComposition()

    guard
      let compositionVideoTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw compositorError("Could not create the composition video track.")
    }

    // Lazily created composition audio track shared by all audible clip
    // segments (they never overlap — the timeline is sequential). The
    // master track gets its own track (it spans everything).
    var compositionClipAudioTrack: AVMutableCompositionTrack?

    // Second video track (Edit Modes Stage 3), created lazily only
    // when a cross-dissolve needs it: the incoming clip's head is
    // inserted here, time-aligned with the main track, so the
    // dissolve can blend the outgoing tail into the incoming head.
    // A composition with no crossfade never creates it.
    var compositionVideoTrack2: AVMutableCompositionTrack?

    func overlayVideoTrack() throws -> AVMutableCompositionTrack {
      if let existing = compositionVideoTrack2 {
        return existing
      }
      guard
        let track = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        throw compositorError("Could not create the composition overlay video track.")
      }
      compositionVideoTrack2 = track
      return track
    }

    func clipAudioTrack() throws -> AVMutableCompositionTrack {
      if let existing = compositionClipAudioTrack {
        return existing
      }
      guard
        let track = composition.addMutableTrack(
          withMediaType: .audio,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        throw compositorError("Could not create the composition audio track.")
      }
      compositionClipAudioTrack = track
      return track
    }

    var cursor = CMTime.zero
    var segmentRanges: [CMTimeRange] = []
    var segmentTransforms: [CGAffineTransform] = []
    var clipAudioMixParameters: AVMutableAudioMixInputParameters?
    /// Per clip, whether its cross-dissolve head was actually
    /// inserted on track 2 (Edit Modes Stage 3). A boundary whose
    /// head insert failed renders as a dip instead — the
    /// instruction builder below reads this, never the request
    /// alone.
    var crossfadeActive = [Bool](repeating: false, count: clips.count)

    // ---- Video (and clip audio), sequentially at the cursor ----
    for (index, clip) in clips.enumerated() {
      let asset = AVURLAsset(url: resolveURL(clip.uri))

      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard let sourceVideoTrack = videoTracks.first else {
        throw compositorError("Clip \(index + 1) has no video track: \(clip.uri)")
      }

      // Clamp the requested range to what the source actually holds —
      // the asset duration and the video track's own time range —
      // never insert past the end of a source track.
      let assetDuration = try await asset.load(.duration)
      let assetDurationSeconds = CMTimeGetSeconds(assetDuration)
      let trackTimeRange = try await sourceVideoTrack.load(.timeRange)
      let trackEndSeconds = CMTimeGetSeconds(trackTimeRange.end)
      var sourceLimitSeconds = trackEndSeconds
      if assetDurationSeconds.isFinite {
        sourceLimitSeconds = min(sourceLimitSeconds, assetDurationSeconds)
      }
      let clampedStart = max(0, clip.startSeconds)
      let clampedDuration = min(clip.durationSeconds, sourceLimitSeconds - clampedStart)
      guard clampedDuration > 0.01 else {
        throw compositorError(
          "Clip \(index + 1) has no usable range: \(clip.startSeconds)s + \(clip.durationSeconds)s falls outside its source (\(clip.uri))."
        )
      }

      let range = CMTimeRange(
        start: CMTime(seconds: clampedStart, preferredTimescale: timescale),
        duration: CMTime(seconds: clampedDuration, preferredTimescale: timescale)
      )

      // Clip speed (Edit Modes Stage 1): the source range is
      // unchanged — it is re-timed on the composition timeline, so
      // the segment occupies duration/speed in the cut (0.5x = twice
      // as long, 2x = half as long). Sanitised here (finite, clamped
      // to 0.25–2) so a stale or out-of-range request can never
      // produce a zero or negative segment. The master song is
      // inserted later at 1x and is untouched by this.
      let speed: Double = {
        let s = clip.speed
        return s.isFinite && s > 0 ? min(max(s, 0.25), 2.0) : 1.0
      }()
      let scaledDuration = CMTime(seconds: clampedDuration / speed, preferredTimescale: timescale)

      try insertTimeRangeGuarded(
        into: compositionVideoTrack, range, of: sourceVideoTrack, at: cursor,
        "Clip \(index + 1)'s video could not be added to the composition"
      )

      if abs(speed - 1.0) > 0.001 {
        try scaleTimeRangeGuarded(
          compositionVideoTrack,
          CMTimeRange(start: cursor, duration: range.duration),
          toDuration: scaledDuration,
          "Clip \(index + 1)'s video could not be retimed"
        )
      }

      // Cross-dissolve head (Edit Modes Stage 3): the incoming
      // clip's head on the second track, time-aligned with the
      // main track — at composition time t it shows the source
      // frame the main track shows at t, so the dissolve blends
      // the outgoing tail into the incoming head and lands exactly
      // on the incoming clip when it ends. Source range
      // [start − h·speed, start + h·speed] over
      // [boundary − h, boundary + h] (cursor is the boundary
      // here), clamped to what the source actually holds: a take
      // with no pre-roll footage starts its head later (the
      // dissolve's early part is dip-like), and a head that cannot
      // be inserted at all degrades this boundary to a dip
      // instead (see crossfadeActive — the failure is caught, it
      // never fails the build).
      if index > 0, clip.transitionInKind == "crossfade",
        let halfSeconds = clip.transitionInHalfSeconds, halfSeconds > 0
      {
        let headSourceStart = clampedStart - halfSeconds * speed
        let headSourceEnd = min(clampedStart + halfSeconds * speed, sourceLimitSeconds)
        let headStart = max(0, headSourceStart)
        let headDurationSeconds = headSourceEnd - headStart
        if headDurationSeconds > 0.01 {
          // Where the clamped head begins on the composition
          // timeline: the head is shifted later by exactly the
          // source frames lost to the clamp, at the clip's rate.
          let headCompStartSeconds =
            CMTimeGetSeconds(cursor) - halfSeconds + (headStart - headSourceStart) / speed
          let headCompEndSeconds = CMTimeGetSeconds(cursor) + halfSeconds
          let headCompDurationSeconds = headCompEndSeconds - headCompStartSeconds
          if headCompDurationSeconds > 0.01 {
            do {
              let track2 = try overlayVideoTrack()
              let headRange = CMTimeRange(
                start: CMTime(seconds: headStart, preferredTimescale: timescale),
                duration: CMTime(seconds: headDurationSeconds, preferredTimescale: timescale)
              )
              try insertTimeRangeGuarded(
                into: track2, headRange, of: sourceVideoTrack,
                at: CMTime(seconds: headCompStartSeconds, preferredTimescale: timescale),
                "Clip \(index + 1)'s dissolve head could not be added to the composition"
              )
              if abs(speed - 1.0) > 0.001 {
                try scaleTimeRangeGuarded(
                  track2,
                  CMTimeRange(
                    start: CMTime(seconds: headCompStartSeconds, preferredTimescale: timescale),
                    duration: CMTime(seconds: headDurationSeconds, preferredTimescale: timescale)
                  ),
                  toDuration: CMTime(seconds: headCompDurationSeconds, preferredTimescale: timescale),
                  "Clip \(index + 1)'s dissolve head could not be retimed"
                )
              }
              crossfadeActive[index] = true
            } catch {
              crossfadeActive[index] = false
            }
          }
        }
      }

      // Normalise this segment into the project canvas: apply the
      // source's preferredTransform, take its display size, then scale
      // ASPECT-FILL (max scale — never stretch) and centre the result.
      let naturalSize = try await sourceVideoTrack.load(.naturalSize)
      let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
      let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
      let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
      guard displaySize.width > 0, displaySize.height > 0 else {
        throw compositorError("Clip \(index + 1) has an empty display size: \(clip.uri)")
      }
      let fillScale = max(canvasSize.width / displaySize.width, canvasSize.height / displaySize.height)
      // Built in steps — the fully chained expression defeats the Swift
      // type-checker ("unable to type-check in reasonable time", CI).
      var transform = preferredTransform
      transform = transform.concatenating(
        CGAffineTransform(translationX: -displayRect.origin.x, y: -displayRect.origin.y)
      )
      transform = transform.concatenating(CGAffineTransform(scaleX: fillScale, y: fillScale))
      let centreX = (canvasSize.width - displaySize.width * fillScale) / 2
      let centreY = (canvasSize.height - displaySize.height * fillScale) / 2
      transform = transform.concatenating(CGAffineTransform(translationX: centreX, y: centreY))
      // The video composition instruction covers the RETIMED range:
      // the segment's span on the composition timeline is the scaled
      // duration, not the source duration.
      segmentRanges.append(CMTimeRange(start: cursor, duration: scaledDuration))
      segmentTransforms.append(transform)

      // Clip's own audio, only when wanted (the app mutes takes by
      // default — song-only is the product default). When the clip
      // is retimed, its audio is retimed by the same factor so A/V
      // stay in sync (pitch follows the rate, as in any slow-mo /
      // fast-mo); muted clips never reach here.
      if !clip.muted, clip.volume > 0 {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let sourceAudioTrack = audioTracks.first {
          let targetTrack = try clipAudioTrack()
          try insertTimeRangeGuarded(
            into: targetTrack, range, of: sourceAudioTrack, at: cursor,
            "Clip \(index + 1)'s audio could not be added to the composition"
          )
          if abs(speed - 1.0) > 0.001 {
            try scaleTimeRangeGuarded(
              targetTrack,
              CMTimeRange(start: cursor, duration: range.duration),
              toDuration: scaledDuration,
              "Clip \(index + 1)'s audio could not be retimed"
            )
          }
          if clipAudioMixParameters == nil {
            clipAudioMixParameters = AVMutableAudioMixInputParameters(track: targetTrack)
          }
          // Volume keyframe at this segment's start; held until the next
          // audible segment sets its own.
          clipAudioMixParameters?.setVolume(Float(max(0, min(1, clip.volume))), at: cursor)
        }
      }

      cursor = CMTimeAdd(cursor, scaledDuration)
    }

    let totalDuration = cursor

    // ---- Master audio track over the whole cut (inserted once) ----
    var audioMixParameters: [AVMutableAudioMixInputParameters] = []
    /// Set when auto volume gains the master track (below).
    var appliedGainDb: Double? = nil
    if let parameters = clipAudioMixParameters {
      audioMixParameters.append(parameters)
    }

    if let audioUri = request.audioUri, !audioUri.isEmpty, request.audioVolume > 0 {
      let masterAsset = AVURLAsset(url: resolveURL(audioUri))
      let masterTracks = try await masterAsset.loadTracks(withMediaType: .audio)
      guard let sourceMasterTrack = masterTracks.first else {
        throw compositorError("The master audio file has no audio track: \(audioUri)")
      }
      let masterDuration = try await masterAsset.load(.duration)
      let start = CMTime(seconds: max(0, request.audioStartSeconds), preferredTimescale: timescale)
      // Trim the master track to the video's total length, clamped to
      // whatever audio actually remains after the start offset.
      let remaining = CMTimeSubtract(masterDuration, start)
      let length = CMTimeMinimum(totalDuration, remaining)
      if length > CMTime.zero {
        guard
          let targetTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          )
        else {
          throw compositorError("Could not create the composition master audio track.")
        }
        try insertTimeRangeGuarded(
          into: targetTrack,
          CMTimeRange(start: start, duration: length),
          of: sourceMasterTrack,
          at: .zero,
          "The master audio could not be added to the composition"
        )
        // Auto volume: measure the region being inserted and gain
        // it to the platform loudness (−14 LUFS, peak-capped) via
        // this track's mix volume, so preview and export hear
        // exactly what ships. Only the composition is gained —
        // record-time playback and the sync correlation never see
        // it. Measurement failure or silence leaves unity gain,
        // silently (see measureLoudness / normalizationGainDb).
        var masterVolume = max(0, min(1, request.audioVolume))
        if request.normalizeVolume == true {
          let attrs = try? FileManager.default.attributesOfItem(atPath: masterAsset.url.path)
          let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? -1
          let fileMtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
          let cacheKey =
            "\(masterAsset.url.path)|\(fileSize)|\(fileMtime)|\(CMTimeGetSeconds(start))|\(CMTimeGetSeconds(length))"
          if let measurement = await measureLoudness(
            asset: masterAsset,
            track: sourceMasterTrack,
            range: CMTimeRange(start: start, duration: length),
            cacheKey: cacheKey
          ),
            let gainDb = normalizationGainDb(
              measuredLufs: measurement.lufs,
              peakDbfs: measurement.peakDbfs
            )
          {
            masterVolume *= pow(10.0, gainDb / 20.0)
            appliedGainDb = gainDb
          }
        }
        let parameters = AVMutableAudioMixInputParameters(track: targetTrack)
        parameters.setVolume(Float(masterVolume), at: .zero)
        audioMixParameters.append(parameters)
      }
    }

    // ---- Video composition: per-segment layer instructions carrying
    // the normalised canvas transforms, plus Edit Modes Stage 3
    // transitions (opacity ramps on the boundary instructions).
    //
    // A transition lives on the boundary INTO segment i, with
    // effective half-width h (seconds, from the request — the JS
    // side clamped it so windows never overlap):
    //  • dip: the outgoing instruction fades 1→0 over [B−h, B]
    //    and the incoming fades 0→1 over [B, B+h]. No time is
    //    added — the cut's total length and the song sync are
    //    untouched, and the background behind a faded layer is
    //    black, so the dip reads as a fade through black.
    //  • crossfade (head inserted on track 2): the boundary
    //    splits into four spans — [B−h, B] blends track 1
    //    (outgoing, 1→0.5) over track 2 (incoming head, 0→0.5),
    //    [B, B+h] blends track 1 (incoming, 0.5→0) over track 2
    //    (incoming head, 0.5→1). The track-2 head is time-aligned
    //    with the main track, so the dissolve lands exactly on
    //    the incoming clip. A crossfade whose head insert failed
    //    degrades to a dip (crossfadeActive, above).
    //  • a boundary with no transition is a hard cut, exactly as
    //    before: one instruction per segment, one opaque layer.
    //
    // Halves are re-clamped here, symmetrically, against the
    // built segment durations (the JS side already did this —
    // belt-and-braces for a stale or hand-built request, so a
    // bad half can never split a span out of existence).
    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = canvasSize
    // The render grid is exactly the request's frame rate (the EDL's
    // 30fps grid) — the verified composition shape. (Round 3 sampled
    // at max(frameRate, 60); reverted with the Edit-screen crash fix.)
    videoComposition.frameDuration = CMTime(seconds: 1.0 / frameRate, preferredTimescale: timescale)
    var effectiveHalf = clips.map { max(0, $0.transitionInHalfSeconds ?? 0) }
    for i in 1..<clips.count where effectiveHalf[i] > 0 {
      let prevDur = segmentRanges[i - 1].duration.seconds
      let nextDur = segmentRanges[i].duration.seconds
      effectiveHalf[i] = min(effectiveHalf[i], prevDur, nextDur)
    }
    if clips.count > 2 {
      for i in 1..<(clips.count - 1) where effectiveHalf[i] > 0 && effectiveHalf[i + 1] > 0 {
        let gap = segmentRanges[i].duration.seconds
        if effectiveHalf[i] + effectiveHalf[i + 1] > gap {
          let cap = gap / 2
          effectiveHalf[i] = min(effectiveHalf[i], cap)
          effectiveHalf[i + 1] = min(effectiveHalf[i + 1], cap)
        }
      }
    }
    /// One layer of one instruction: a track, its canvas
    /// transform, and the opacity ramps over it (each a
    /// (start, end, range) triple; empty = fully opaque).
    struct LayerSpec {
      var track: AVMutableCompositionTrack
      var transform: CGAffineTransform
      var opacityRamps: [(Float, Float, CMTimeRange)] = []
    }
    func makeInstruction(range: CMTimeRange, layers: [LayerSpec]) -> AVMutableVideoCompositionInstruction {
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = range
      instruction.layerInstructions = layers.map { spec in
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: spec.track)
        layerInstruction.setTransform(spec.transform, at: range.start)
        for (startOpacity, endOpacity, rampRange) in spec.opacityRamps {
          layerInstruction.setOpacityRamp(
            fromStartOpacity: startOpacity, toEndOpacity: endOpacity, timeRange: rampRange)
        }
        return layerInstruction
      }
      return instruction
    }
    var instructions: [AVMutableVideoCompositionInstruction] = []
    for (index, range) in segmentRanges.enumerated() {
      let inCross =
        index > 0 && clips[index].transitionInKind == "crossfade" && effectiveHalf[index] > 0
        && crossfadeActive[index]
      let inDip =
        index > 0 && effectiveHalf[index] > 0
        && (clips[index].transitionInKind == "dip"
          || (clips[index].transitionInKind == "crossfade" && !crossfadeActive[index]))
      let outCross =
        index + 1 < clips.count && clips[index + 1].transitionInKind == "crossfade"
        && effectiveHalf[index + 1] > 0 && crossfadeActive[index + 1]
      let outDip =
        index + 1 < clips.count && effectiveHalf[index + 1] > 0
        && (clips[index + 1].transitionInKind == "dip"
          || (clips[index + 1].transitionInKind == "crossfade" && !crossfadeActive[index + 1]))
      let hIn = (inCross || inDip) ? effectiveHalf[index] : 0
      let hOut = (outCross || outDip) ? effectiveHalf[index + 1] : 0
      let start = range.start
      let end = range.end
      // Head span — second half of the incoming crossfade: the
      // incoming clip fades in on track 2 while the main track's
      // copy of it fades out (they show the same frame, so the
      // sum stays constant).
      if inCross, let track2 = compositionVideoTrack2 {
        let headRange = CMTimeRange(start: start, duration: CMTime(seconds: hIn, preferredTimescale: timescale))
        instructions.append(makeInstruction(range: headRange, layers: [
          LayerSpec(
            track: compositionVideoTrack, transform: segmentTransforms[index],
            opacityRamps: [(0.5, 0, headRange)]),
          LayerSpec(
            track: track2, transform: segmentTransforms[index],
            opacityRamps: [(0.5, 1, headRange)]),
        ]))
      }
      // Body span — the segment minus any crossfade head/tail.
      // Dip ramps attach here (they never split spans).
      let bodyStart = inCross ? CMTimeAdd(start, CMTime(seconds: hIn, preferredTimescale: timescale)) : start
      let bodyEnd = outCross ? CMTimeSubtract(end, CMTime(seconds: hOut, preferredTimescale: timescale)) : end
      if bodyEnd > bodyStart {
        var ramps: [(Float, Float, CMTimeRange)] = []
        if inDip {
          ramps.append((0, 1, CMTimeRange(start: start, duration: CMTime(seconds: hIn, preferredTimescale: timescale))))
        }
        if outDip {
          ramps.append((1, 0, CMTimeRange(
            start: CMTimeSubtract(end, CMTime(seconds: hOut, preferredTimescale: timescale)),
            duration: CMTime(seconds: hOut, preferredTimescale: timescale))))
        }
        instructions.append(makeInstruction(
          range: CMTimeRange(start: bodyStart, end: bodyEnd),
          layers: [LayerSpec(
            track: compositionVideoTrack, transform: segmentTransforms[index], opacityRamps: ramps)]
        ))
      }
      // Tail span — first half of the outgoing crossfade: the
      // outgoing clip fades out on track 1 while the next clip's
      // head fades in on track 2.
      if outCross, let track2 = compositionVideoTrack2 {
        let tailRange = CMTimeRange(
          start: CMTimeSubtract(end, CMTime(seconds: hOut, preferredTimescale: timescale)), end: end)
        instructions.append(makeInstruction(range: tailRange, layers: [
          LayerSpec(
            track: compositionVideoTrack, transform: segmentTransforms[index],
            opacityRamps: [(1, 0.5, tailRange)]),
          LayerSpec(
            track: track2, transform: segmentTransforms[index + 1],
            opacityRamps: [(0, 0.5, tailRange)]),
        ]))
      }
    }
    videoComposition.instructions = instructions

    var audioMix: AVMutableAudioMix?
    if includeAudioMix, !audioMixParameters.isEmpty {
      let mix = AVMutableAudioMix()
      mix.inputParameters = audioMixParameters
      audioMix = mix
    }

    // ---- Optional watermark (EXPORT builds only): the logo lockup
    // flipping between the top-left and bottom-right corners every
    // 5 seconds, via a CoreAnimation tool on the videoComposition
    // the export session renders. Preview builds must NOT carry the
    // tool: -[AVPlayerItem setVideoComposition:] throws an uncaught
    // NSException for a composition carrying an animation tool on
    // device (crash log MVMTStudio-2026-11-09-220942) — the app
    // overlays the logo in previews at the JS layer instead, so the
    // request's watermark fields have no effect on a preview build.
    // A missing/unloadable image degrades to no watermark: a render
    // must never fail over branding. Timed lyrics (request.lyrics)
    // burn in through the SAME tool's layer tree — created for the
    // lyrics alone when the watermark is off — and degrade the same
    // way: any lyric problem renders without them.
    if forExport, includeAnimationTool,
      let tool = makeAnimationTool(
        request: request,
        renderSize: canvasSize,
        durationSeconds: CMTimeGetSeconds(totalDuration)
      )
    {
      videoComposition.animationTool = tool
    }

    // ---- Optional look (edit/export-stage grade) ----
    // RULE (device failures, 2026-11-10): the factory filter
    // composition is BANNED everywhere in this module. Its
    // compositor threw on AVFoundation's own queue for BOTH kinds
    // of EDL build — EXC_CRASH/SIGABRT, outside avTry's reach:
    // EXPORT builds died on the animation-tool conflict (crash
    // log MVMTStudio-2026-11-10-181458, hit Export with the
    // watermark on and a look active), and PREVIEW builds died
    // too (Jaizon, entering Edit). Moving it into the render
    // transcode did not save it either: TikTok transcodes came
    // out as short, still-frame files with bad audio while High
    // exports stayed correct. So the grade has two homes, both of
    // them the same custom compositor:
    //  • PREVIEW builds: LookVideoCompositor hangs off this plain
    //    EDL composition and grades each frame as the player
    //    requests it, reading the resolved params from
    //    LookCompositorStore. Preview compositions never carry
    //    the animation tool (see above), and the editor must show
    //    the grade it will export.
    //  • EXPORT builds: this composition is left EXACTLY as it was
    //    before looks existed (animation tool and all); the
    //    resolved params travel out as BuiltComposition.pendingGrade
    //    and render() applies them in its post-render transcode —
    //    export grade = LookVideoCompositor inside the
    //    transcode's single-instruction composition over the
    //    finished file (watermark/lyrics already burned in).
    var pendingGrade: LookParamsRecord?
    if let look = request.look, !lookIsIdentity(look) {
      if forExport {
        pendingGrade = look
      } else {
        LookCompositorStore.current = look
        videoComposition.customVideoCompositorClass = LookVideoCompositor.self
      }
    } else if !forExport {
      // A no-look / identity preview build must not inherit a stale
      // grade from an earlier preview build (2026-11-13, Leak D):
      // the store is only written above, never cleared, so clear it
      // here — matching the transcode's defer discipline.
      LookCompositorStore.current = nil
    }

    // ---- Optional Extra Style scene (2.0) ----
    // Same two-home rule as the grade. PREVIEW builds attach
    // ExtraStylesCompositor (the grade folded in via the shared
    // slot, §6.2: grade first, then the scene) — it replaces
    // LookVideoCompositor when both are present, so the look block
    // above installs the Look class and this overrides it. EXPORT
    // builds carry the handle out as
    // BuiltComposition.pendingExtraStyleSceneHandle and render()
    // applies it in the post-render transcode. A stale/unknown
    // handle renders without a scene: the store lookup is the only
    // gate, and a miss is not an error.
    var pendingExtraStyleSceneHandle: String?
    if let handle = request.extraStyleSceneHandle,
      let scene = ExtraStyleSceneStore.shared.get(handle)
    {
      if forExport {
        pendingExtraStyleSceneHandle = handle
      } else {
        let slotLook = request.look.flatMap { lookIsIdentity($0) ? nil : $0 }
        ExtraStyleCompositorStore.current = ExtraStyleCompositorSlot(
          scene: scene, look: slotLook)
        videoComposition.customVideoCompositorClass = ExtraStylesCompositor.self
      }
    } else if !forExport {
      // Same stale-slot discipline as the grade above: a preview
      // build with no resolvable scene must not inherit a previous
      // build's scene slot.
      ExtraStyleCompositorStore.current = nil
    }

    return BuiltComposition(
      composition: composition,
      videoComposition: videoComposition,
      audioMix: audioMix,
      duration: totalDuration,
      appliedGainDb: appliedGainDb,
      pendingGrade: pendingGrade,
      pendingExtraStyleSceneHandle: pendingExtraStyleSceneHandle
    )
  }

  /// Builds the export CoreAnimation tool when the request carries
  /// a watermark and/or lyrics: a parent layer holding the full-frame
  /// video layer, the watermark layer (when enabled and its image
  /// loads) and one layer subtree per lyric line. Returns nil when
  /// neither produced anything — the composition then renders bare,
  /// exactly as a request without overlays always has.
  private static func makeAnimationTool(
    request: CompositeRequestRecord,
    renderSize: CGSize,
    durationSeconds: Double
  ) -> AVVideoCompositionCoreAnimationTool? {
    guard
      renderSize.width > 0, renderSize.height > 0,
      durationSeconds.isFinite, durationSeconds > 0
    else {
      return nil
    }

    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: renderSize)
    let videoLayer = CALayer()
    videoLayer.frame = parentLayer.bounds
    parentLayer.addSublayer(videoLayer)

    var hasOverlay = false
    if request.watermarkEnabled == true,
      let watermarkUri = request.watermarkImageUri, !watermarkUri.isEmpty,
      addWatermarkLayer(
        to: parentLayer,
        imageURL: resolveURL(watermarkUri),
        renderSize: renderSize,
        durationSeconds: durationSeconds
      )
    {
      hasOverlay = true
    }

    if let lyrics = request.lyrics, !lyrics.lines.isEmpty,
      addLyricLayers(
        to: parentLayer,
        lyrics: lyrics,
        renderSize: renderSize,
        durationSeconds: durationSeconds
      )
    {
      hasOverlay = true
    }

    guard hasOverlay else { return nil }
    return AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: videoLayer,
      in: parentLayer
    )
  }

  /// Adds the watermark layer to the tool's parent layer: the logo
  /// lockup (27% of the render width, aspect preserved, 85% opacity)
  /// starts in the TOP-LEFT corner and flips to the BOTTOM-RIGHT
  /// every 5 seconds for the whole composition — discrete keyframes,
  /// so it teleports rather than sliding. CALayer coordinates are
  /// bottom-left origin, so "top-left" means y near the frame's top.
  /// Returns false when the image cannot be loaded — callers treat
  /// that as "render without a watermark".
  private static func addWatermarkLayer(
    to parentLayer: CALayer,
    imageURL: URL,
    renderSize: CGSize,
    durationSeconds: Double
  ) -> Bool {
    guard
      let image = UIImage(contentsOfFile: imageURL.path),
      let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0
    else {
      return false
    }

    let watermarkWidth = renderSize.width * 0.27
    let watermarkHeight = watermarkWidth * CGFloat(cgImage.height) / CGFloat(cgImage.width)
    let margin = renderSize.width * 0.045

    let watermarkLayer = CALayer()
    watermarkLayer.contents = cgImage
    watermarkLayer.contentsGravity = .resizeAspect
    watermarkLayer.opacity = 0.85
    watermarkLayer.bounds = CGRect(x: 0, y: 0, width: watermarkWidth, height: watermarkHeight)

    // Corner CENTRES (CALayer position is the layer's centre).
    let topLeft = CGPoint(
      x: margin + watermarkWidth / 2,
      y: renderSize.height - margin - watermarkHeight / 2
    )
    let bottomRight = CGPoint(
      x: renderSize.width - margin - watermarkWidth / 2,
      y: margin + watermarkHeight / 2
    )
    watermarkLayer.position = topLeft

    // One 5-second slot per flip; slot i shows topLeft on even slots,
    // bottomRight on odd ones, each holding until the next keyTime.
    let slotCount = max(1, Int(ceil(durationSeconds / 5.0)))
    if slotCount > 1 {
      var positions: [CGPoint] = []
      var keyTimes: [NSNumber] = []
      for slot in 0..<slotCount {
        positions.append(slot % 2 == 0 ? topLeft : bottomRight)
        keyTimes.append(NSNumber(value: Double(slot) / Double(slotCount)))
      }
      let flip = CAKeyframeAnimation(keyPath: "position")
      flip.values = positions.map { NSValue(cgPoint: $0) }
      flip.keyTimes = keyTimes
      flip.duration = durationSeconds
      flip.beginTime = AVCoreAnimationBeginTimeAtZero
      flip.calculationMode = .discrete
      flip.isRemovedOnCompletion = false
      watermarkLayer.add(flip, forKey: "cornerFlip")
    }
    parentLayer.addSublayer(watermarkLayer)
    return true
  }

  // MARK: Lyrics burn-in (export only)
  //
  // The JS side resolves its font/animation presets into the plain
  // parameter model on LyricsRecord (see the records at the top of
  // this file) — this section is ONE generic applier, no catalogs.
  // Text is rendered ONCE per line (or per word) into an image with
  // NSAttributedString — which supports stroke + fill in a single
  // pass, unlike CATextLayer — and shown through image-backed
  // CALayers; every animation the parameter model needs (opacity,
  // offset, scale, rotation) is a LAYER animation, so the image
  // backing costs nothing. Layer hierarchy per line:
  //
  //   gate layer   — discrete opacity keyframes spanning the WHOLE
  //                  composition: 0 outside [start, end], 1 inside.
  //                  This is the visibility guarantee: whatever the
  //                  enter/exit animations hold outside their own
  //                  window, the line can never linger or pre-show.
  //   inner layer  — the line's enter/exit/emphasis keyframes (the
  //                  enter is skipped for the per-word modes that
  //                  animate their own entrances).
  //   pill layer (optional) + text/word image layers, inside inner.
  //
  // All times are composition seconds; animation beginTimes follow
  // the watermark convention (AVCoreAnimationBeginTimeAtZero + t).
  // Robustness: every value arriving from JS is sanitised (NaN /
  // out-of-range input becomes a safe default), every render step
  // is optional, and any failure drops that line — lyrics must
  // never fail an export.

  /// NaN/inf-safe Double: lyric parameters cross the JS bridge and
  /// feed CAKeyframeAnimation keyTimes, which RAISE on invalid
  /// values — sanitise everything at the boundary.
  private static func lyricFinite(_ value: Double, _ fallback: Double) -> Double {
    value.isFinite ? value : fallback
  }

  private static func lyricClamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
  }

  /// The JS overlay's easing (src/lib/lyricAnimations.ts header):
  /// easeOutCubic / easeInCubic. The sampled line animation below
  /// reproduces them exactly; the per-word CABasicAnimations still
  /// use CAMediaTimingFunction easeOut, which is the same family
  /// (known tolerance, docs/STYLES-PARITY.md).
  private static func lyricEaseOutCubic(_ x: Double) -> Double {
    1 - pow(1 - lyricClamp(x, 0, 1), 3)
  }

  private static func lyricEaseInCubic(_ x: Double) -> Double {
    let c = lyricClamp(x, 0, 1)
    return c * c * c
  }

  /// Parses "#RRGGBB" / "#RRGGBBAA" (the '#' is optional) and
  /// CSS "rgb(r,g,b)" / "rgba(r,g,b,a)". Nil when unparseable —
  /// callers substitute their own default. The rgba form matters:
  /// template pill backgrounds are authored as rgba() (Neon Sign,
  /// Retro TV, Spotlight, Storybook) and the old hex-only parse
  /// silently fell back to black — Spotlight's warm-white pill
  /// rendered black in export (Stage 4 parity audit).
  private static func lyricColor(_ hex: String?) -> UIColor? {
    guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    let lower = text.lowercased()
    if lower.hasPrefix("rgba(") || lower.hasPrefix("rgb(") {
      guard let close = text.firstIndex(of: ")") else { return nil }
      let inner = text[text.index(after: text.firstIndex(of: "(")!)..<close]
      let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 3 || parts.count == 4,
        let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2])
      else { return nil }
      let a = parts.count == 4 ? (Double(parts[3]) ?? 1) : 1
      return UIColor(
        red: CGFloat(lyricClamp(r / 255, 0, 1)),
        green: CGFloat(lyricClamp(g / 255, 0, 1)),
        blue: CGFloat(lyricClamp(b / 255, 0, 1)),
        alpha: CGFloat(lyricClamp(a, 0, 1))
      )
    }
    if text.hasPrefix("#") {
      text.removeFirst()
    }
    guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else {
      return nil
    }
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    if text.count == 6 {
      red = Double((value >> 16) & 0xFF) / 255
      green = Double((value >> 8) & 0xFF) / 255
      blue = Double(value & 0xFF) / 255
      alpha = 1
    } else {
      red = Double((value >> 24) & 0xFF) / 255
      green = Double((value >> 16) & 0xFF) / 255
      blue = Double((value >> 8) & 0xFF) / 255
      alpha = Double(value & 0xFF) / 255
    }
    return UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
  }

  /// CAKeyframeAnimation raises an NSException on non-monotonic
  /// keyTimes (this module's crash species) — sanitise a stop list
  /// into fractions that start at 0, end at 1 and strictly increase,
  /// or return nil when that is impossible. A stop whose fraction
  /// collides with its predecessor is nudged 0.0005 later; a stop
  /// that cannot fit before 1.0 is dropped (its neighbours still
  /// describe a valid animation).
  private static func lyricSanitizedStops<T>(_ stops: [(Double, T)]) -> [(Double, T)]? {
    guard stops.count >= 2 else { return nil }
    var out: [(Double, T)] = []
    for (rawFraction, value) in stops {
      var fraction = rawFraction.isFinite ? min(max(rawFraction, 0), 1) : 0
      if let last = out.last {
        if fraction <= last.0 {
          fraction = last.0 + 0.0005
        }
        if fraction > 1 {
          continue
        }
      }
      out.append((fraction, value))
    }
    guard out.count >= 2, let first = out.first, first.0 == 0 else { return nil }
    if let last = out.last, last.0 < 1 {
      out.append((1, last.1))
    }
    for index in 1..<out.count where out[index].0 <= out[index - 1].0 {
      return nil
    }
    return out
  }

  /// Resolves the style's font at a point size. Unknown PostScript
  /// names fall back to the system font. Bold handling is
  /// deterministic: when the named font's own face is not bold, its
  /// descriptor is asked for the bold trait (CoreText picks the
  /// family's bold face, or synthesises weight at render); if the
  /// result STILL is not a bold face, lyricTextImage lays a hair of
  /// same-colour stroke as a weight approximation, so `bold` always
  /// has a visible effect.
  private static func lyricFont(postScriptName: String, size: CGFloat, bold: Bool) -> UIFont {
    guard let named = UIFont(name: postScriptName, size: size) else {
      return UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
    guard bold, !named.fontDescriptor.symbolicTraits.contains(.traitBold) else {
      return named
    }
    let traits = named.fontDescriptor.symbolicTraits.union(.traitBold)
    if let boldDescriptor = named.fontDescriptor.withSymbolicTraits(traits) {
      return UIFont(descriptor: boldDescriptor, size: size)
    }
    return named
  }

  /// Renders one string (a whole line, or a single word) into an
  /// image with the font/fill/stroke baked in, at `scale`× its
  /// display size. Returns the image and the DISPLAY size (canvas
  /// points). Nil when the string measures empty or the bitmap
  /// cannot be made — callers drop that piece.
  private static func lyricTextImage(
    _ text: String,
    font: UIFont,
    fillColor: UIColor,
    strokeColor: UIColor?,
    strokeFractionOfFont: Double,
    boldStrokeFallback: Bool,
    pad: CGFloat,
    scale: CGFloat,
    /// Letter-spacing in points (Minimal Mono decor tracking).
    /// Applied as .kern in every pass, so the measured width
    /// already includes it.
    tracking: CGFloat = 0
  ) -> (image: CGImage, displaySize: CGSize)? {
    var strokeFraction = max(0, strokeFractionOfFont)
    // The user's chosen outline (a real stroke colour) renders
    // TWO passes, mirroring the JS preview's halo: a stroke-only
    // pass (positive strokeWidth = hollow stroke, centred on the
    // glyph path) at TWICE the fraction, so its outer edge lands
    // strokeFraction × fontSize beyond the glyph — then the fill
    // pass on top, glyph intact. The old single pass (negative
    // strokeWidth, stroke centred) ate half the stroke's width
    // out of the fill: heavy fonts printed as solid blobs and
    // thin fonts as hollow outlines — never what the preview
    // showed. The bold fallback keeps the single-pass behaviour:
    // a hair of the FILL colour around the glyph to fake weight.
    let hasRealStroke = strokeColor != nil && strokeFraction > 0
    var fallbackStrokeFraction: CGFloat = 0
    if !hasRealStroke, boldStrokeFallback {
      fallbackStrokeFraction = strokeFraction > 0 ? strokeFraction : 0.03
    }

    let fillAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: fillColor,
      .kern: tracking,
    ]
    let fillString = NSAttributedString(string: text, attributes: fillAttributes)
    let textSize = fillString.size()
    guard textSize.width > 0, textSize.height > 0 else { return nil }

    // `pad` (caller-supplied) leaves room for the stroke's
    // overhang around the measured text.
    let displaySize = CGSize(width: textSize.width + pad * 2, height: textSize.height + pad * 2)
    // Bitmap guard: never attempt an absurd allocation.
    guard displaySize.width * scale <= 8192, displaySize.height * scale <= 8192 else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: displaySize, format: format)
    let image = renderer.image { _ in
      let origin = CGPoint(x: pad, y: pad)
      if hasRealStroke, let strokeColor {
        let strokeAttributes: [NSAttributedString.Key: Any] = [
          .font: font,
          .foregroundColor: strokeColor,
          .strokeColor: strokeColor,
          .kern: tracking,
          // Percent of the font size; positive = stroke only.
          // Doubled: the stroke is centred on the path, so half
          // its width lands outside the glyph.
          .strokeWidth: NSNumber(value: Double(strokeFraction) * 200),
        ]
        NSAttributedString(string: text, attributes: strokeAttributes).draw(at: origin)
        fillString.draw(at: origin)
      } else if fallbackStrokeFraction > 0 {
        var attributes = fillAttributes
        attributes[.strokeColor] = fillColor
        attributes[.strokeWidth] = NSNumber(value: -Double(fallbackStrokeFraction) * 100)
        NSAttributedString(string: text, attributes: attributes).draw(at: origin)
      } else {
        fillString.draw(at: origin)
      }
    }
    guard let cgImage = image.cgImage else { return nil }
    return (cgImage, displaySize)
  }

  /// Bitmap scale for lyric text images: 2× the display size for
  /// crispness, capped so the bitmap never exceeds the canvas' own
  /// pixel size.
  private static func lyricRenderScale(displaySize: CGSize, renderSize: CGSize) -> CGFloat {
    var scale: CGFloat = 2
    if displaySize.width > 0 {
      scale = min(scale, renderSize.width / displaySize.width)
    }
    if displaySize.height > 0 {
      scale = min(scale, renderSize.height / displaySize.height)
    }
    return max(scale, 1)
  }

  /// The enter "from" transform shared by the line and word
  /// appliers: x/y offsets (fractions × line width/height), then
  /// rotation, then scale. Sign flip (Stage 4 parity audit): the
  /// layer space is y-up, so a positive Y translation moves the
  /// layer UP on screen and a positive rotation is
  /// counter-clockwise — the JS overlay (y-down) reads both the
  /// other way. The catalog spec says fromYOffsetFrac + = starts
  /// LOWER ("Rise" uses +0.8) and fromRotateDeg + = clockwise, so
  /// both are negated here. Before this fix every preset with a
  /// vertical offset or rotation ran mirrored in export (Rise fell
  /// instead of rising; Flip tilted the wrong way).
  private static func lyricFromTransform(
    _ animation: LyricAnimationRecord,
    lineHeight: CGFloat,
    lineWidth: CGFloat
  ) -> CATransform3D {
    let scale = CGFloat(lyricClamp(lyricFinite(animation.fromScale, 1), 0.05, 20))
    let yOffset = -CGFloat(lyricFinite(animation.fromYOffsetFrac, 0)) * lineHeight
    let xOffset = CGFloat(lyricFinite(animation.fromXOffsetFrac, 0)) * lineWidth
    let rotation = -CGFloat(lyricFinite(animation.fromRotateDeg, 0)) * .pi / 180
    return CATransform3DConcat(
      CATransform3DMakeTranslation(xOffset, yOffset, 0),
      CATransform3DConcat(
        CATransform3DMakeRotation(rotation, 0, 0, 1),
        CATransform3DMakeScale(scale, scale, 1)
      )
    )
  }

  /// The visibility window: discrete opacity over the WHOLE
  /// composition timeline — 0 before the line starts, 1 during,
  /// 0 after it ends. Model opacity is 0, so even if this animation
  /// cannot be built the line simply never appears.
  private static func addLyricGateAnimation(
    to layer: CALayer,
    start: Double,
    end: Double,
    totalDuration: Double
  ) {
    var stops: [(Double, Double)] = [(0, start <= 0 ? 1 : 0)]
    if start > 0 {
      stops.append((start / totalDuration, 1))
    }
    if end < totalDuration {
      stops.append((end / totalDuration, 0))
    }
    stops.append((1, stops.last?.1 ?? 0))
    guard let clean = lyricSanitizedStops(stops) else { return }
    let gate = CAKeyframeAnimation(keyPath: "opacity")
    gate.values = clean.map { NSNumber(value: $0.1) }
    gate.keyTimes = clean.map { NSNumber(value: $0.0) }
    gate.duration = totalDuration
    gate.beginTime = AVCoreAnimationBeginTimeAtZero
    gate.calculationMode = .discrete
    gate.fillMode = .both
    gate.isRemovedOnCompletion = false
    layer.add(gate, forKey: "lyricWindow")
  }

  /// Enter / exit / emphasis keyframes for one line, on its inner
  /// layer — SAMPLED from the JS overlay's envelope formulas
  /// (src/lib/lyricAnimations.ts header), so preview == export
  /// instead of "same family, different curve":
  ///   enterP = enterSecs <= 0 ? 1 : easeOutCubic(tIn / enterSecs)
  ///   exitP  = exitSecs  <= 0 ? 1 : easeInCubic(tOut / exitSecs)
  ///   e = min(enterP, exitP)
  ///   opacity = lerp(fromOpacity, 1, e)
  ///   scale   = lerp(fromScale, 1, e) (× the pulse, below)
  ///   offsetX = fromXOffsetFrac × (1 − e) × lineWidth
  ///   offsetY = fromYOffsetFrac × (1 − e) × lineHeight
  ///   rotate  = fromRotateDeg × (1 − e)
  /// The emphasis pulse (emphasisScale > 1) is the catalog's
  /// breathing pulse — 1 + (emphasisScale − 1) ×
  /// (0.5 − 0.5·cos(2π·tIn / P)), P = min(1.2s, line duration),
  /// repeating — and it applies ONLY in 'none' word mode
  /// (applyPulse). The old code swelled once at the line's
  /// midpoint AND pulsed karaoke lines, where the JS overlay never
  /// pulses at all (the current word pops instead). When applyEnter
  /// is false (the per-word modes animate their own entrances)
  /// the line starts at its resting state and only the exit
  /// envelope is applied. 25 samples with linear interpolation
  /// reproduce the eased curves to well under a percent.
  private static func addLyricLineAnimations(
    to layer: CALayer,
    animation: LyricAnimationRecord,
    applyEnter: Bool,
    applyPulse: Bool,
    start: Double,
    lineDuration: Double,
    lineHeight: CGFloat,
    lineWidth: CGFloat
  ) {
    let enter = max(0, lyricFinite(animation.enterSecs, 0))
    let exit = max(0, lyricFinite(animation.exitSecs, 0))
    let fromOpacity = lyricClamp(lyricFinite(animation.fromOpacity, 0), 0, 1)
    let fromScale = CGFloat(lyricClamp(lyricFinite(animation.fromScale, 1), 0.05, 20))
    let emphasisScale = CGFloat(lyricClamp(lyricFinite(animation.emphasisScale, 1), 1, 20))
    let fromX = CGFloat(lyricFinite(animation.fromXOffsetFrac, 0))
    let fromY = CGFloat(lyricFinite(animation.fromYOffsetFrac, 0))
    let fromRotate = CGFloat(lyricFinite(animation.fromRotateDeg, 0))
    let pulsePeriod = min(1.2, max(0.2, lineDuration))

    let sampleCount = 25
    var opacityStops: [(Double, Double)] = []
    var transformStops: [(Double, CATransform3D)] = []
    for i in 0..<sampleCount {
      let f = Double(i) / Double(sampleCount - 1)
      let tIn = f * lineDuration
      let tOut = (1 - f) * lineDuration
      let enterP: Double = !applyEnter ? 1 : (enter <= 0 ? 1 : lyricEaseOutCubic(tIn / enter))
      let exitP: Double = exit <= 0 ? 1 : lyricEaseInCubic(tOut / exit)
      let e = min(enterP, exitP)
      let opacity = fromOpacity + (1 - fromOpacity) * e
      var scale = fromScale + (1 - fromScale) * CGFloat(e)
      if applyPulse, emphasisScale > 1 {
        scale *= 1 + (emphasisScale - 1) * (0.5 - 0.5 * cos(2 * .pi * tIn / pulsePeriod))
      }
      // Layer space is y-up: negate the Y offset and the rotation
      // (same flip as lyricFromTransform).
      let dx = fromX * CGFloat(1 - e) * lineWidth
      let dy = -fromY * CGFloat(1 - e) * lineHeight
      let rotation = -fromRotate * CGFloat(1 - e) * .pi / 180
      let transform = CATransform3DConcat(
        CATransform3DMakeTranslation(dx, dy, 0),
        CATransform3DConcat(
          CATransform3DMakeRotation(rotation, 0, 0, 1),
          CATransform3DMakeScale(scale, scale, 1)
        )
      )
      opacityStops.append((f, opacity))
      transformStops.append((f, transform))
    }

    let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
    opacityAnimation.values = opacityStops.map { NSNumber(value: $0.1) }
    opacityAnimation.keyTimes = opacityStops.map { NSNumber(value: $0.0) }
    opacityAnimation.duration = lineDuration
    opacityAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + start
    opacityAnimation.fillMode = .both
    opacityAnimation.isRemovedOnCompletion = false
    layer.add(opacityAnimation, forKey: "lyricOpacity")

    let transformAnimation = CAKeyframeAnimation(keyPath: "transform")
    transformAnimation.values = transformStops.map { NSValue(caTransform3D: $0.1) }
    transformAnimation.keyTimes = transformStops.map { NSNumber(value: $0.0) }
    transformAnimation.duration = lineDuration
    transformAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + start
    transformAnimation.fillMode = .both
    transformAnimation.isRemovedOnCompletion = false
    layer.add(transformAnimation, forKey: "lyricTransform")
  }

  /// Per-word entrance for the 'stagger' mode: the word runs the
  /// line's enter animation (opacity + transform from the style's
  /// from-values), beginning at its staggered start time.
  private static func addLyricWordEnterAnimation(
    to layer: CALayer,
    animation: LyricAnimationRecord,
    wordBegin: Double,
    lineEnd: Double,
    lineHeight: CGFloat,
    lineWidth: CGFloat
  ) {
    let enter = max(0, lyricFinite(animation.enterSecs, 0))
    let available = lineEnd - wordBegin
    guard enter > 0, available > 0.02 else {
      // No room (or no enter) — the word is simply present.
      layer.opacity = 1
      return
    }
    layer.opacity = 0
    let duration = min(enter, available)
    let fromOpacity = lyricClamp(lyricFinite(animation.fromOpacity, 0), 0, 1)

    let opacityAnimation = CABasicAnimation(keyPath: "opacity")
    opacityAnimation.fromValue = NSNumber(value: fromOpacity)
    opacityAnimation.toValue = NSNumber(value: 1.0)
    opacityAnimation.duration = duration
    opacityAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + wordBegin
    opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    opacityAnimation.fillMode = .both
    opacityAnimation.isRemovedOnCompletion = false
    layer.add(opacityAnimation, forKey: "lyricWordOpacity")

    let transformAnimation = CABasicAnimation(keyPath: "transform")
    transformAnimation.fromValue = NSValue(caTransform3D: lyricFromTransform(animation, lineHeight: lineHeight, lineWidth: lineWidth))
    transformAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    transformAnimation.duration = duration
    transformAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + wordBegin
    transformAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    transformAnimation.fillMode = .both
    transformAnimation.isRemovedOnCompletion = false
    layer.add(transformAnimation, forKey: "lyricWordTransform")
  }

  /// Discrete appearance at a word's start — 'typewriter' words and
  /// karaoke highlights: opacity 0 until the word begins, 1 after.
  private static func addLyricWordPopAnimation(
    to layer: CALayer,
    wordStart: Double,
    lineStart: Double,
    lineDuration: Double
  ) {
    let fraction = lineDuration > 0
      ? lyricClamp((wordStart - lineStart) / lineDuration, 0, 1)
      : 0
    guard fraction > 0.0005 else {
      layer.opacity = 1
      return
    }
    guard fraction < 0.9995 else {
      // Starts at the line's very end — never visibly appears, and
      // a keyTime duplicated at 1.0 is not worth the risk.
      layer.opacity = 0
      return
    }
    layer.opacity = 0
    let pop = CAKeyframeAnimation(keyPath: "opacity")
    pop.values = [NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: 1)]
    pop.keyTimes = [NSNumber(value: 0), NSNumber(value: fraction), NSNumber(value: 1)]
    pop.duration = lineDuration
    pop.beginTime = AVCoreAnimationBeginTimeAtZero + lineStart
    pop.calculationMode = .discrete
    pop.fillMode = .both
    pop.isRemovedOnCompletion = false
    layer.add(pop, forKey: "lyricWordPop")
  }

  /// Karaoke current-word pop (Stage 4 parity audit): the JS
  /// overlay scales the word being sung by emphasisScale (× 1.25
  /// for a comic-burst emphasis word, whose image is already
  /// rendered 1.25× — the layer scale is just emphasisScale) and
  /// back to 1 once it is sung. Discrete, on the same clock as the
  /// opacity pop above. Skipped when emphasisScale is 1 (no pop).
  private static func addLyricWordHighlightScaleAnimation(
    to layer: CALayer,
    wordStart: Double,
    wordEnd: Double,
    lineStart: Double,
    lineDuration: Double,
    emphasisScale: Double
  ) {
    guard emphasisScale > 1.001, lineDuration > 0 else { return }
    let startFraction = lyricClamp((wordStart - lineStart) / lineDuration, 0, 1)
    let endFraction = lyricClamp((wordEnd - lineStart) / lineDuration, 0, 1)
    guard
      let clean = lyricSanitizedStops([
        (0, emphasisScale), (startFraction, emphasisScale), (endFraction, 1), (1, 1),
      ])
    else { return }
    let pop = CAKeyframeAnimation(keyPath: "transform.scale")
    pop.values = clean.map { NSNumber(value: $0.1) }
    pop.keyTimes = clean.map { NSNumber(value: $0.0) }
    pop.duration = lineDuration
    pop.beginTime = AVCoreAnimationBeginTimeAtZero + lineStart
    pop.calculationMode = .discrete
    pop.fillMode = .both
    pop.isRemovedOnCompletion = false
    layer.add(pop, forKey: "lyricWordHighlightScale")
  }

  /// A jagged starburst polygon (comic-burst): `spikes` outer
  /// points alternating with inner points at `innerRatio` of the
  /// rect's radii.
  private static func lyricStarburstPath(in rect: CGRect, spikes: Int, innerRatio: CGFloat) -> CGPath {
    let path = UIBezierPath()
    let cx = rect.midX
    let cy = rect.midY
    let outerRx = rect.width / 2
    let outerRy = rect.height / 2
    let total = max(4, spikes) * 2
    for i in 0..<total {
      let angle = CGFloat(i) * .pi / CGFloat(max(4, spikes)) - .pi / 2
      let r: CGFloat = i % 2 == 0 ? 1 : innerRatio
      let point = CGPoint(x: cx + cos(angle) * outerRx * r, y: cy + sin(angle) * outerRy * r)
      if i == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }
    path.close()
    return path.cgPath
  }

  /// Extra Style background shapes, drawn behind the text inside
  /// the inner layer (so they follow the line's enter/exit). Only
  /// the background kinds draw here; scanlines / glow / cursor /
  /// burst are applied at their own points in makeLyricLineLayer.
  private static func addLyricDecorBackground(
    to layer: CALayer,
    decor: LyricDecorRecord,
    lineIndex: Int,
    containerSize: CGSize,
    contentWidth: CGFloat,
    fontSize: CGFloat
  ) {
    let rect = CGRect(origin: .zero, size: containerSize)
    switch decor.kind {
    case "chat-bubble":
      // Sender (even line) in decor.color, receiver (odd line) in
      // decor.secondaryColor — the alternating conversation. The
      // tail hangs off the bottom edge, 0.72 × font size in from
      // the sender/receiver edge (Stage 4 parity audit — the old
      // 22%-of-width position was far too far in), sticking out
      // 0.22 × font size with its base 0.06 × font size inside.
      let isSender = lineIndex % 2 == 0
      let fill = lyricColor(isSender ? decor.color : decor.secondaryColor) ?? .white
      let path = UIBezierPath(roundedRect: rect, cornerRadius: fontSize * 0.5)
      let tailW = fontSize * 0.44
      let tailH = fontSize * 0.22
      let tailX = isSender ? rect.maxX - fontSize * 0.72 : rect.minX + fontSize * 0.72
      path.move(to: CGPoint(x: tailX - tailW / 2, y: fontSize * 0.06))
      path.addLine(to: CGPoint(x: tailX, y: -tailH))
      path.addLine(to: CGPoint(x: tailX + tailW / 2, y: fontSize * 0.06))
      path.close()
      let shape = CAShapeLayer()
      shape.path = path.cgPath
      shape.fillColor = fill.cgColor
      shape.frame = rect
      layer.addSublayer(shape)
    case "comic-burst":
      // Jagged starburst behind the line, with the decor's burst
      // word ("POW") as a small rotated label at the top-right.
      let fill = lyricColor(decor.color) ?? .yellow
      let stroke = lyricColor(decor.secondaryColor) ?? .black
      let pad = fontSize * 0.35
      let shape = CAShapeLayer()
      shape.path = lyricStarburstPath(in: rect.insetBy(dx: -pad, dy: -pad), spikes: 12, innerRatio: 0.78)
      shape.fillColor = fill.cgColor
      shape.strokeColor = stroke.cgColor
      shape.lineWidth = max(2, fontSize * 0.06)
      shape.frame = rect
      layer.addSublayer(shape)
      if !decor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let labelFont = UIFont.systemFont(ofSize: fontSize * 0.55, weight: .black)
        if let rendered = lyricTextImage(
          decor.text, font: labelFont, fillColor: stroke, strokeColor: nil,
          strokeFractionOfFont: 0, boldStrokeFallback: false, pad: 2, scale: 2
        ) {
          let label = CALayer()
          label.contents = rendered.image
          label.contentsScale = 2
          label.contentsGravity = .resize
          label.bounds = CGRect(origin: .zero, size: rendered.displaySize)
          // Top-right, half-outside the burst (Stage 4 parity
          // audit): the JS overlay places the label's centre
          // 0.35 × font size above the container top and flush
          // with the right edge (+ 0.2 × font size); the old
          // code sat it 0.15 × font size inside.
          label.position = CGPoint(
            x: containerSize.width + fontSize * 0.2 - rendered.displaySize.width / 2,
            y: containerSize.height + fontSize * 0.35 - rendered.displaySize.height / 2
          )
          label.transform = CATransform3DMakeRotation(-8 * .pi / 180, 0, 0, 1)
          layer.addSublayer(label)
        }
      }
    case "sticker-frame":
      // White frame with coloured corner dots. The −2° tilt
      // lives on the gate layer (it rotates the whole frame
      // including the text, like the JS overlay) — the old
      // per-shape rotation tilted the frame the wrong way and
      // left the text and dots untilted.
      let frame = CAShapeLayer()
      frame.path = UIBezierPath(roundedRect: rect, cornerRadius: fontSize * 0.2).cgPath
      frame.fillColor = nil
      frame.strokeColor = UIColor.white.cgColor
      frame.lineWidth = max(2, fontSize * 0.07)
      frame.frame = rect
      layer.addSublayer(frame)
      let dotSize = fontSize * 0.22
      let dotColors = [
        lyricColor(decor.color), lyricColor(decor.secondaryColor),
        lyricColor(decor.secondaryColor), lyricColor(decor.color),
      ]
      let corners = [
        CGPoint(x: 0, y: containerSize.height),
        CGPoint(x: containerSize.width, y: containerSize.height),
        CGPoint(x: 0, y: 0),
        CGPoint(x: containerSize.width, y: 0),
      ]
      for (i, corner) in corners.enumerated() {
        let dot = CALayer()
        dot.backgroundColor = (dotColors[i] ?? .white)?.cgColor
        dot.bounds = CGRect(origin: .zero, size: CGSize(width: dotSize, height: dotSize))
        dot.cornerRadius = dotSize / 2
        dot.position = corner
        layer.addSublayer(dot)
      }
    case "pill":
      // A wide subtitle bar, broader than the text. Rounded by
      // 0.4 × font size, like the JS overlay (Stage 4 audit —
      // the old stadium radius made the bar fully round-ended).
      let base = lyricColor(decor.color) ?? .black
      let alpha = CGFloat(lyricClamp(lyricFinite(decor.opacity, 0.7), 0, 1))
      let bar = CALayer()
      bar.frame = rect
      bar.backgroundColor = base.withAlphaComponent(alpha).cgColor
      bar.cornerRadius = fontSize * 0.4
      layer.addSublayer(bar)
    case "rule":
      // Thin horizontal rules above and below the line (Magazine,
      // Elegant Script, Storybook) — the same fractions the JS
      // preview uses, in the same colours. The rules sit at the
      // container's top and bottom edges: decorPadY reserves
      // the rule + gap outside the text, so they no longer
      // strike through it (Stage 4 parity audit).
      let ruleColor = (lyricColor(decor.color) ?? .white)
        .withAlphaComponent(CGFloat(lyricClamp(lyricFinite(decor.opacity, 0.9), 0, 1)))
      let ruleHeight = max(1, fontSize * 0.04)
      for y in [ruleHeight / 2, rect.height - ruleHeight / 2] {
        let rule = CALayer()
        rule.backgroundColor = ruleColor.cgColor
        // Text width, not container width (Stage 4 audit): the
        // JS overlay's rules span the line, and on Storybook —
        // a rule template WITH a style pill — the container is
        // wider than the text by the pill padding.
        rule.bounds = CGRect(origin: .zero, size: CGSize(width: contentWidth, height: ruleHeight))
        rule.position = CGPoint(x: rect.width / 2, y: y)
        layer.addSublayer(rule)
      }
    case "spray":
      // Scattered spray dots around the frame (Graffiti) — the
      // same deterministic spots the JS preview uses, as
      // (left, top, colour) fractions; layer space is y-up, so
      // the top fraction flips here.
      let dotSize = fontSize * 0.16
      let spots: [(CGFloat, CGFloat, Int)] = [
        (0.02, 0.08, 0), (0.96, 0.04, 1), (0.06, 0.92, 1), (0.94, 0.95, 0),
        (0.48, 0.0, 0), (0.0, 0.45, 1), (0.99, 0.55, 0), (0.24, 1.0, 1),
        (0.76, 0.0, 0), (0.38, 0.0, 1),
      ]
      let dotColors = [lyricColor(decor.color), lyricColor(decor.secondaryColor)]
      for (left, top, colourIndex) in spots {
        let dot = CALayer()
        dot.backgroundColor = (dotColors[colourIndex] ?? .white)?.cgColor
        dot.bounds = CGRect(origin: .zero, size: CGSize(width: dotSize, height: dotSize))
        dot.cornerRadius = dotSize / 2
        dot.position = CGPoint(x: rect.width * left, y: rect.height * (1 - top))
        layer.addSublayer(dot)
      }
    case "typing-dots":
      // A plain rounded bubble (Text Message Typing) — the
      // alternating conversation fill, like chat-bubble but with
      // no tail; the dots themselves live in makeLyricLineLayer.
      let isSender = lineIndex % 2 == 0
      let fill = lyricColor(isSender ? decor.color : decor.secondaryColor) ?? .white
      let bubble = CAShapeLayer()
      bubble.path = UIBezierPath(roundedRect: rect, cornerRadius: fontSize * 0.5).cgPath
      bubble.fillColor = fill.cgColor
      bubble.frame = rect
      layer.addSublayer(bubble)
    default:
      break
    }
  }

  /// Per-word entrance for the 'burst' decor (Word Explosion):
  /// the word flies in from above at `angleDeg`, fanned across
  /// the line, from 0.3× scale — instead of the shared
  /// from-transform. Same opacity + transform basics as the
  /// stagger enter.
  private static func addLyricWordBurstAnimation(
    to layer: CALayer,
    animation: LyricAnimationRecord,
    wordBegin: Double,
    lineEnd: Double,
    angleDeg: Double,
    distance: CGFloat
  ) {
    let enter = max(0, lyricFinite(animation.enterSecs, 0))
    let available = lineEnd - wordBegin
    guard enter > 0, available > 0.02 else {
      layer.opacity = 1
      return
    }
    layer.opacity = 0
    let duration = min(enter, available)
    let fromOpacity = lyricClamp(lyricFinite(animation.fromOpacity, 0), 0, 1)
    let radians = CGFloat(angleDeg) * .pi / 180
    // Translation: +sin is UP in layer space, matching the JS
    // overlay's −sin in screen space. Rotation: negated, same flip
    // as lyricFromTransform (layer space is y-up).
    let fromTransform = CATransform3DConcat(
      CATransform3DMakeTranslation(cos(radians) * distance, sin(radians) * distance, 0),
      CATransform3DConcat(
        CATransform3DMakeRotation(-CGFloat(lyricFinite(animation.fromRotateDeg, 0)) * .pi / 180, 0, 0, 1),
        CATransform3DMakeScale(0.3, 0.3, 1)
      )
    )
    let opacityAnimation = CABasicAnimation(keyPath: "opacity")
    opacityAnimation.fromValue = NSNumber(value: fromOpacity)
    opacityAnimation.toValue = NSNumber(value: 1.0)
    opacityAnimation.duration = duration
    opacityAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + wordBegin
    opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    opacityAnimation.fillMode = .both
    opacityAnimation.isRemovedOnCompletion = false
    layer.add(opacityAnimation, forKey: "lyricWordOpacity")

    let transformAnimation = CABasicAnimation(keyPath: "transform")
    transformAnimation.fromValue = NSValue(caTransform3D: fromTransform)
    transformAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    transformAnimation.duration = duration
    transformAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + wordBegin
    transformAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    transformAnimation.fillMode = .both
    transformAnimation.isRemovedOnCompletion = false
    layer.add(transformAnimation, forKey: "lyricWordTransform")
  }

  /// Per-word entrance for the 'bounce' decor (Bounce House):
  /// SAMPLED from the JS overlay's formula (LyricsOverlay):
  ///   e = easeOutCubic(τ / enterSecs)
  ///   scale = lerp(fromScale, 1, e) × (1 + 0.3·sin(2πe)·(1−e))
  ///   opacity = lerp(fromOpacity, 1, e)
  /// The old keyframe stops (fromScale → 1.25 → 0.9 → 1.05 → 1)
  /// were a different curve that only agreed with the preview at
  /// the endpoints. 13 samples with linear interpolation
  /// reproduce the wobble exactly.
  private static func addLyricWordBounceAnimation(
    to layer: CALayer,
    animation: LyricAnimationRecord,
    wordBegin: Double,
    lineEnd: Double
  ) {
    let enter = max(0, lyricFinite(animation.enterSecs, 0))
    let available = lineEnd - wordBegin
    guard enter > 0, available > 0.02 else {
      layer.opacity = 1
      return
    }
    layer.opacity = 0
    let duration = min(enter, available)
    let fromOpacity = lyricClamp(lyricFinite(animation.fromOpacity, 0), 0, 1)
    let fromScale = lyricClamp(lyricFinite(animation.fromScale, 1), 0.05, 20)

    let sampleCount = 13
    var opacityStops: [(Double, Double)] = []
    var scaleStops: [(Double, Double)] = []
    for i in 0..<sampleCount {
      let u = Double(i) / Double(sampleCount - 1)
      let e = lyricEaseOutCubic(u * duration / enter)
      opacityStops.append((u, fromOpacity + (1 - fromOpacity) * e))
      let base = Double(fromScale) + (1 - Double(fromScale)) * e
      scaleStops.append((u, base * (1 + 0.3 * sin(2 * .pi * e) * (1 - e))))
    }
    let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
    opacityAnimation.values = opacityStops.map { NSNumber(value: $0.1) }
    opacityAnimation.keyTimes = opacityStops.map { NSNumber(value: $0.0) }
    opacityAnimation.duration = duration
    opacityAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + wordBegin
    opacityAnimation.fillMode = .both
    opacityAnimation.isRemovedOnCompletion = false
    layer.add(opacityAnimation, forKey: "lyricWordOpacity")

    let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
    scaleAnimation.values = scaleStops.map { NSNumber(value: $0.1) }
    scaleAnimation.keyTimes = scaleStops.map { NSNumber(value: $0.0) }
    scaleAnimation.duration = duration
    scaleAnimation.beginTime = AVCoreAnimationBeginTimeAtZero + wordBegin
    scaleAnimation.fillMode = .both
    scaleAnimation.isRemovedOnCompletion = false
    layer.add(scaleAnimation, forKey: "lyricWordBounce")
  }

  /// Builds every lyric line's layer subtree. Returns true when at
  /// least one line was added.
  private static func addLyricLayers(
    to parentLayer: CALayer,
    lyrics: LyricsRecord,
    renderSize: CGSize,
    durationSeconds: Double
  ) -> Bool {
    let style = lyrics.style
    // Kind 'none' (Whisper, Minimal Mono) carries no visual decor
    // — its opacity IS the line's text opacity.
    var fillColor = lyricColor(style.color) ?? .white
    if lyrics.decor?.kind == "none" {
      fillColor = fillColor.withAlphaComponent(CGFloat(lyricClamp(lyricFinite(lyrics.decor?.opacity ?? 1, 1), 0, 1)))
    }
    let strokeColor = lyricColor(style.strokeColor)
    let strokeFraction = max(0, lyricFinite(style.strokeWidthRatio ?? 0, 0))
    // Font size = sizeRatio × canvas width (contract), clamped.
    let sizeRatio = lyricClamp(lyricFinite(style.sizeRatio, 0.045), 0.005, 0.5)
    let baseFontSize = CGFloat(sizeRatio) * renderSize.width
    guard baseFontSize >= 4 else { return false }

    var added = false
    for (index, line) in lyrics.lines.enumerated() {
      if let lineLayer = makeLyricLineLayer(
        line: line,
        lineIndex: index,
        style: style,
        decor: lyrics.decor,
        fillColor: fillColor,
        strokeColor: strokeColor,
        strokeFraction: strokeFraction,
        baseFontSize: baseFontSize,
        renderSize: renderSize,
        durationSeconds: durationSeconds
      ) {
        parentLayer.addSublayer(lineLayer)
        added = true
      }
    }
    return added
  }

  /// Builds one line's gate-layer subtree (see the section header
  /// for the hierarchy), or nil when the line cannot be rendered.
  /// `lineIndex` is the line's position in the song (chat bubbles
  /// alternate sides by it); `decor` is the project's Extra Style
  /// decor, or nil for the classic style.
  private static func makeLyricLineLayer(
    line: LyricLineRecord,
    lineIndex: Int,
    style: LyricStyleRecord,
    decor: LyricDecorRecord?,
    fillColor: UIColor,
    strokeColor: UIColor?,
    strokeFraction: Double,
    baseFontSize: CGFloat,
    renderSize: CGSize,
    durationSeconds: Double
  ) -> CALayer? {
    let decorKind = decor?.kind ?? "none"
    // Duet: the fill alternates by line — sender lines in
    // decor.color, receiver lines in decor.secondaryColor.
    let lineFillColor: UIColor = {
      guard decorKind == "duet", let decor = decor else { return fillColor }
      return lyricColor(lineIndex % 2 == 0 ? decor.color : decor.secondaryColor) ?? fillColor
    }()
    // Letter-spacing fraction (Minimal Mono decor tracking).
    let trackingFrac = lyricClamp(lyricFinite(decor?.tracking ?? 0, 0), 0, 1)
    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    // The line's window on the composition timeline, sanitised.
    let start = lyricClamp(lyricFinite(line.startSeconds, 0), 0, durationSeconds)
    let end = max(lyricFinite(line.endSeconds, 0), start + 0.05)
    let lineDuration = end - start

    let animation = style.animation
    let wordMode = ["stagger", "karaoke", "typewriter"].contains(animation.wordMode)
      ? animation.wordMode
      : "none"

    var font = lyricFont(postScriptName: style.fontPostScriptName, size: baseFontSize, bold: style.bold)
    // Container padding, computed FIRST (Stage 4 parity audit):
    // the padding values are the JS overlay's (LyricsOverlay) —
    // the old Swift numbers were roomier (chat-bubble 0.8/0.4 vs
    // 0.55/0.22, pill 1.1/0.3 vs 0.9/0.2, style pill 0.55/0.24
    // vs 0.45/0.16), so every backed line rendered bigger in
    // export than in preview. A decor background shape (bubble /
    // burst / frame / bar) replaces the style pill — the decor
    // draws the backing.
    let decorBackgroundKinds: Set<String> = ["chat-bubble", "comic-burst", "sticker-frame", "pill", "typing-dots"]
    let wantsPill = style.background == "pill" && !decorBackgroundKinds.contains(decorKind)
    let pillPadX = wantsPill ? font.pointSize * 0.45 : 0
    let pillPadY = wantsPill ? font.pointSize * 0.16 : 0
    var decorPadX: CGFloat = 0
    var decorPadY: CGFloat = 0
    switch decorKind {
    case "chat-bubble", "typing-dots": decorPadX = font.pointSize * 0.55; decorPadY = font.pointSize * 0.22
    case "comic-burst": decorPadX = font.pointSize * 0.7; decorPadY = font.pointSize * 0.35
    case "sticker-frame": decorPadX = font.pointSize * 0.4; decorPadY = font.pointSize * 0.28
    case "pill": decorPadX = font.pointSize * 0.9; decorPadY = font.pointSize * 0.2
    // Rules sit OUTSIDE the text (a rule-height bar plus the
    // 0.25 × font size gap the JS preview uses) — the old code
    // drew them 0.15 × font size inside the container edge, so
    // they struck through the text on pad-less templates.
    case "rule": decorPadY = max(1, font.pointSize * 0.04) + font.pointSize * 0.25
    default: break
    }

    // Line width (Jaizon, 2026-11-12): a line never runs past
    // this fraction of the canvas width — it wraps onto more
    // rows instead of clipping at the frame's edges (the old
    // shrink-to-fit also ignored the per-word image pads, so
    // long lines still overflowed). The font stays at the
    // style's sizeRatio; wrapping is what keeps a long line
    // readable at the chosen size. The limit applies to the
    // WHOLE container (text + padding), as the JS overlay's
    // lineBox maxWidth does — the old text-only limit let a
    // backed line run past maxWidthRatio by its padding.
    let maxTextWidth = max(
      renderSize.width * CGFloat(lyricClamp(lyricFinite(style.maxWidthRatio ?? 0.88, 0.88), 0.3, 1.0))
        - (pillPadX + decorPadX) * 2,
      renderSize.width * 0.2
    )
    let initialMeasure: [NSAttributedString.Key: Any] = [.font: font, .kern: baseFontSize * CGFloat(trackingFrac)]
    let measured = NSAttributedString(string: text, attributes: initialMeasure).size()
    guard measured.width > 0, measured.height > 0 else { return nil }
    // One unbreakable word wider than the limit is shrunk to
    // fit; a multi-word line wraps instead (below).
    if measured.width > maxTextWidth, text.split(separator: " ").count <= 1 {
      let scaledSize = baseFontSize * (maxTextWidth / measured.width)
      font = lyricFont(postScriptName: style.fontPostScriptName, size: scaledSize, bold: style.bold)
    }
    // Letter-spacing in points, from the final font size — folded
    // into every measurement and render so the wrap math already
    // includes it.
    let trackingPts = font.pointSize * CGFloat(trackingFrac)
    let boldFallback = style.bold && !font.fontDescriptor.symbolicTraits.contains(.traitBold)
    let measureAttributes: [NSAttributedString.Key: Any] = [.font: font, .kern: trackingPts]

    // Word timings for the word modes. A word whose own window is
    // unusable (missing / zero-length) gets an even slice of the
    // line instead.
    var words: [(text: String, start: Double, end: Double)] = []
    if wordMode != "none", let rawWords = line.words {
      let usable = rawWords.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if !usable.isEmpty {
        let slot = lineDuration / Double(usable.count)
        words = usable.enumerated().map { index, word in
          let wordStart = lyricFinite(word.startSeconds, 0)
          let wordEnd = lyricFinite(word.endSeconds, 0)
          if wordEnd > wordStart {
            return (text: word.text, start: wordStart, end: wordEnd)
          }
          return (
            text: word.text,
            start: start + slot * Double(index),
            end: start + slot * Double(index + 1)
          )
        }
      }
    }
    // A line with no word timings that is wider than the limit
    // is tokenised so the word path below can wrap it; its words
    // enter as a group (the inner layer's enter still applies —
    // see the applyEnter condition below).
    if words.isEmpty, measured.width > maxTextWidth {
      let tokens = text.split(separator: " ").map(String.init)
      if tokens.count > 1 {
        let slot = lineDuration / Double(tokens.count)
        words = tokens.enumerated().map { index, token in
          (
            text: token,
            start: start + slot * Double(index),
            end: start + slot * Double(index + 1)
          )
        }
      }
    }
    let useWords = !words.isEmpty

    // Emoji row (Extra Styles): the line's stored emoji rendered
    // above the text, inside the same content block — the text
    // block is pushed down by `textTopOffset` below. Emoji render
    // in the system font (colour emoji glyphs), never the lyric
    // font, which may not carry them.
    var emojiLayer: CALayer?
    var emojiDisplaySize = CGSize.zero
    let emojiGap = baseFontSize * 0.25
    if decorKind == "emoji-row",
      let emojiText = line.emoji?.trimmingCharacters(in: .whitespacesAndNewlines),
      !emojiText.isEmpty
    {
      let emojiSize = baseFontSize * 1.15 * CGFloat(lyricClamp(lyricFinite(decor?.scale ?? 1, 1), 0.5, 3))
      let emojiFont = UIFont.systemFont(ofSize: emojiSize)
      if let rendered = lyricTextImage(
        emojiText,
        font: emojiFont,
        fillColor: .white,
        strokeColor: nil,
        strokeFractionOfFont: 0,
        boldStrokeFallback: false,
        pad: 2,
        scale: 2
      ) {
        let layer = CALayer()
        layer.contents = rendered.image
        layer.contentsScale = 2
        layer.contentsGravity = .resize
        layer.bounds = CGRect(origin: .zero, size: rendered.displaySize)
        emojiLayer = layer
        emojiDisplaySize = rendered.displaySize
      }
    }
    let textTopOffset: CGFloat = emojiLayer == nil ? 0 : emojiDisplaySize.height + emojiGap

    // Emphasis words (Extra Styles): word indices the stored
    // intelligence flagged (ALL-CAPS / repeated). Only the
    // comic-burst decor enlarges them, at render time.
    let emphasisIndices = Set(line.emphasisWordIndices ?? [])

    // Image padding around the measured text (room for the
    // stroke's overhang): generous for a whole line, tighter per
    // word — per-word pads ADD UP across a line, so word renders
    // keep them small to stay near the shrink-to-fit width. (The
    // bold-fallback stroke, 0.03 of the font size at most, needs
    // 0.015 — covered by both floors.)
    let linePad = font.pointSize * CGFloat(max(strokeFraction, 0.05)) + 2
    let wordPad = font.pointSize * CGFloat(max(strokeFraction, 0.02)) + 1

    // Bitmap scale from the estimated whole-line display size.
    let estimatedSize = CGSize(
      width: measured.width + linePad * 2,
      height: measured.height + linePad * 2
    )
    let renderScale = lyricRenderScale(displaySize: estimatedSize, renderSize: renderSize)

    // ---- Content: one image for the line, or one per word ----
    var contentSize = CGSize.zero
    var singleLayer: CALayer?
    var wordEntries: [(
      layer: CALayer, highlight: CALayer?, centerX: CGFloat, centerY: CGFloat, row: Int, wordStart: Double, index: Int
    )] = []
    var rowWidths: [CGFloat] = []

    if useWords {
      let spaceWidth = NSAttributedString(string: " ", attributes: measureAttributes).size().width
      // The gap between two word images: the space plus the kern
      // on both sides of it (tracking applies between every pair
      // of adjacent glyphs, space included).
      let gapWidth = spaceWidth + trackingPts * 2
      var cursorX: CGFloat = 0
      var rowY: CGFloat = 0
      var rowHeight: CGFloat = 0
      var rowIndex = 0
      // Split Screen Words: two fixed rows — even words on top,
      // odd words below — with their own cursors. The row height
      // is measured once ("Ag" spans ascender + descender) so the
      // lower row's position never depends on word order.
      let splitGap = font.pointSize * 1.2
      let splitRowHeight =
        NSAttributedString(string: "Ag", attributes: measureAttributes).size().height + wordPad * 2
      var splitCursors: [CGFloat] = [0, 0]
      for (index, word) in words.enumerated() {
        let isKaraoke = wordMode == "karaoke"
        // Karaoke colour-swap: unsung words render in the style
        // colour at 45% opacity; the highlight twin renders at
        // full strength and pops in at the word's start.
        let baseFill = isKaraoke ? lineFillColor.withAlphaComponent(0.45) : lineFillColor
        // Comic-burst emphasis: a flagged word renders 25% larger.
        // In karaoke mode the sizing is stateful (Stage 4 parity
        // audit): the JS overlay shows an unsung emphasis word at
        // 1× and grows it to 1.25× only once sung — so the BASE
        // (unsung, 45%) image uses the plain font and the
        // HIGHLIGHT twin uses the enlarged one. The old code had
        // it backwards (big unsung word, plain sung word) and the
        // highlight never popped to emphasisScale while current.
        let isEmphasis = decorKind == "comic-burst" && emphasisIndices.contains(index)
        let wordFont = isEmphasis
          ? lyricFont(postScriptName: style.fontPostScriptName, size: baseFontSize * 1.25, bold: style.bold)
          : font
        let baseWordFont = isKaraoke ? font : wordFont
        let baseWordBoldFallback = style.bold && !baseWordFont.fontDescriptor.symbolicTraits.contains(.traitBold)
        let wordBoldFallback = style.bold && !wordFont.fontDescriptor.symbolicTraits.contains(.traitBold)
        guard
          let rendered = lyricTextImage(
            word.text,
            font: baseWordFont,
            fillColor: baseFill,
            strokeColor: strokeColor,
            strokeFractionOfFont: strokeFraction,
            boldStrokeFallback: baseWordBoldFallback,
            pad: wordPad,
            scale: renderScale,
            tracking: trackingPts
          )
        else { continue }

        let wordLayer = CALayer()
        wordLayer.contents = rendered.image
        wordLayer.contentsScale = renderScale
        wordLayer.contentsGravity = .resize
        wordLayer.bounds = CGRect(origin: .zero, size: rendered.displaySize)

        var highlightLayer: CALayer?
        if isKaraoke,
          let highlighted = lyricTextImage(
            word.text,
            font: wordFont,
            fillColor: lineFillColor,
            strokeColor: strokeColor,
            strokeFractionOfFont: strokeFraction,
            boldStrokeFallback: wordBoldFallback,
            pad: wordPad,
            scale: renderScale,
            tracking: trackingPts
          )
        {
          let layer = CALayer()
          layer.contents = highlighted.image
          layer.contentsScale = renderScale
          layer.contentsGravity = .resize
          layer.bounds = CGRect(origin: .zero, size: highlighted.displaySize)
          layer.opacity = 0
          highlightLayer = layer
        }

        let wordWidth = rendered.displaySize.width
        if decorKind == "split-screen" {
          // No wrapping: each row is its own line, laid out
          // left-to-right on its own cursor. Lines are short by
          // construction (≤7 words, ≤36 chars), so a row stays
          // inside the width limit.
          let row = index % 2
          wordEntries.append((
            layer: wordLayer,
            highlight: highlightLayer,
            centerX: splitCursors[row] + wordWidth / 2,
            centerY: textTopOffset + (row == 0 ? splitRowHeight / 2 : splitRowHeight + splitGap + splitRowHeight / 2),
            row: row,
            wordStart: word.start,
            index: index
          ))
          splitCursors[row] += wordWidth + gapWidth
          continue
        }
        // Wave Rider: words ride a sine wave across the line —
        // the same phase/amplitude the JS preview uses
        // (amplitude 0.35 × font size × decor scale, one period
        // per three words). centerY is top-down, so a positive
        // offset moves the word down, like the preview's
        // translateY. Stagger-only, like the preview: in any
        // other word mode the JS overlay shows the line flat.
        let waveOffset: CGFloat =
          decorKind == "wave-path" && wordMode == "stagger"
          ? CGFloat(sin(Double(index) * 2 * .pi / 3)) * font.pointSize * 0.35
            * CGFloat(lyricClamp(lyricFinite(decor?.scale ?? 1, 1), 0.25, 3))
          : 0
        // Wrap: a word that would run past the limit starts a
        // new row (unless the row is empty — one wide word).
        if cursorX > 0, cursorX + wordWidth > maxTextWidth {
          rowWidths.append(cursorX - gapWidth)
          rowY += rowHeight
          rowIndex += 1
          cursorX = 0
          rowHeight = 0
        }
        wordEntries.append((
          layer: wordLayer,
          highlight: highlightLayer,
          centerX: cursorX + wordWidth / 2,
          centerY: textTopOffset + rowY + rendered.displaySize.height / 2 + waveOffset,
          row: rowIndex,
          wordStart: word.start,
          index: index
        ))
        cursorX += wordWidth + gapWidth
        rowHeight = max(rowHeight, rendered.displaySize.height)
      }
      guard !wordEntries.isEmpty else { return nil }
      if decorKind == "split-screen" {
        rowWidths = [max(0, splitCursors[0] - gapWidth), max(0, splitCursors[1] - gapWidth)]
        contentSize = CGSize(
          width: max(rowWidths.max() ?? 0, emojiDisplaySize.width),
          height: textTopOffset + splitRowHeight * 2 + splitGap
        )
      } else {
        rowWidths.append(cursorX - gapWidth)
        contentSize = CGSize(
          width: max(rowWidths.max() ?? 0, emojiDisplaySize.width),
          height: textTopOffset + rowY + rowHeight
        )
      }
    } else {
      guard
        let rendered = lyricTextImage(
          text,
          font: font,
          fillColor: lineFillColor,
          strokeColor: strokeColor,
          strokeFractionOfFont: strokeFraction,
          boldStrokeFallback: boldFallback,
          pad: linePad,
          scale: renderScale,
          tracking: trackingPts
        )
      else { return nil }
      let imageLayer = CALayer()
      imageLayer.contents = rendered.image
      imageLayer.contentsScale = renderScale
      imageLayer.contentsGravity = .resize
      imageLayer.bounds = CGRect(origin: .zero, size: rendered.displaySize)
      singleLayer = imageLayer
      contentSize = CGSize(
        width: max(rendered.displaySize.width, emojiDisplaySize.width),
        height: textTopOffset + rendered.displaySize.height
      )
    }
    guard contentSize.width > 0, contentSize.height > 0 else { return nil }

    // ---- Container: the pill adds padding around the content ----
    // (Pads were computed up top, before the wrap limit, so the
    // maxWidthRatio limit already accounts for them.)
    let containerSize = CGSize(
      width: contentSize.width + (pillPadX + decorPadX) * 2,
      height: contentSize.height + (pillPadY + decorPadY) * 2
    )

    // Anchor: horizontally per the decor align (Minimal Mono
    // sits left, at the 4% margin; 'right' mirrors it; 'center'
    // is the classic behaviour); vertically per style.position.
    // The margins are fractions of the canvas WIDTH — the JS
    // overlay pads top by 0.16 × width and bottom by 0.20 ×
    // width (0.09 / 0.1125 of a 9:16 height), and the old
    // 10%-of-height margins sat ~1% off the preview in both
    // directions (Stage 4 parity audit).
    // CALayer space is bottom-left origin, y up.
    var centreX: CGFloat
    switch decor?.align ?? "center" {
    case "left": centreX = containerSize.width / 2 + renderSize.width * 0.04
    case "right": centreX = renderSize.width - containerSize.width / 2 - renderSize.width * 0.04
    default: centreX = renderSize.width / 2
    }
    // Chat bubbles (and typing-dots bubbles) shift sideways by
    // line: sender right, receiver left, 6% of the canvas width
    // — the JS overlay translates the bubble View the same way;
    // the old code never shifted, so every bubble sat centred.
    if decorKind == "chat-bubble" || decorKind == "typing-dots" {
      centreX += (lineIndex % 2 == 0 ? 1 : -1) * renderSize.width * 0.06
    }
    // Duet: lines alternate top/bottom by line index — sender
    // low, receiver high (the JS preview mirrors this).
    let effectivePosition = decorKind == "duet" ? (lineIndex % 2 == 0 ? "bottom" : "top") : style.position
    var rawCentreY: CGFloat
    switch effectivePosition {
    case "top":
      rawCentreY = renderSize.height - renderSize.width * 0.16 - containerSize.height / 2
    case "center":
      rawCentreY = renderSize.height / 2
    default: // "bottom" and anything unrecognised
      rawCentreY = renderSize.width * 0.20 + containerSize.height / 2
    }
    // Fine vertical nudge (Jaizon): a fraction of the canvas
    // height on top of the anchor — positive moves the line UP
    // (layer space is y-up). The on-canvas clamp still applies.
    rawCentreY +=
      CGFloat(lyricClamp(lyricFinite(style.verticalOffsetRatio ?? 0, 0), -0.3, 0.3))
      * renderSize.height
    let centreY = min(
      max(rawCentreY, containerSize.height / 2),
      renderSize.height - containerSize.height / 2
    )

    let gateLayer = CALayer()
    gateLayer.bounds = CGRect(origin: .zero, size: containerSize)
    gateLayer.position = CGPoint(x: centreX, y: centreY)
    gateLayer.opacity = 0
    addLyricGateAnimation(to: gateLayer, start: start, end: end, totalDuration: durationSeconds)
    // Static rotation, on the gate layer, whose only animation is
    // opacity — the inner layer carries the enter/exit transform,
    // so rotating it would be wiped out. Sign flip (Stage 4
    // parity audit): layer space is y-up, so a JS −3° (3°
    // counter-clockwise on screen) is +3° here. The gate also
    // carries the comic-burst and sticker-frame containers'
    // −2° tilt (the JS overlay rotates those whole frames,
    // text included, so the tilt belongs on the gate, not on
    // the background shape alone — the old code tilted the
    // sticker frame shape but left the text untilted).
    let gateRotationDeg =
      -lyricFinite(decor?.rotationDeg ?? 0, 0)
      + (decorKind == "comic-burst" || decorKind == "sticker-frame" ? 2 : 0)
    if gateRotationDeg != 0 {
      gateLayer.transform = CATransform3DMakeRotation(CGFloat(gateRotationDeg) * .pi / 180, 0, 0, 1)
    }

    let innerLayer = CALayer()
    innerLayer.bounds = CGRect(origin: .zero, size: containerSize)
    innerLayer.position = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    gateLayer.addSublayer(innerLayer)

    if wantsPill {
      let pillLayer = CALayer()
      pillLayer.frame = CGRect(origin: .zero, size: containerSize)
      let pillColor = lyricColor(style.backgroundColor) ?? UIColor.black.withAlphaComponent(0.55)
      pillLayer.backgroundColor = pillColor.cgColor
      // Rounded corners, not a stadium: the JS overlay rounds
      // the style pill by 0.35 × font size (Stage 4 audit).
      pillLayer.cornerRadius = font.pointSize * 0.35
      innerLayer.addSublayer(pillLayer)
    }

    // Extra Style background shapes, behind the text.
    if let decor = decor {
      addLyricDecorBackground(
        to: innerLayer,
        decor: decor,
        lineIndex: lineIndex,
        containerSize: containerSize,
        contentWidth: contentSize.width,
        fontSize: font.pointSize
      )
    }
    // Sublayer index where the text content starts (after the pill
    // and decor background): ghost-trail copies insert here so
    // they sit behind the live text but in front of the backing.
    let contentInsertIndex = innerLayer.sublayers?.count ?? 0

    // Content is centred in the container (pill padding is
    // symmetric, so the content centre is the container centre).
    let contentCentre = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    // The text block's centre (the emoji row, when present, takes
    // the top of the content area).
    let textHeight = contentSize.height - textTopOffset
    let textCentreY = contentCentre.y + (contentSize.height / 2 - (textTopOffset + textHeight / 2))
    if let emojiLayer {
      emojiLayer.position = CGPoint(
        x: contentCentre.x,
        y: contentCentre.y + (contentSize.height / 2 - emojiDisplaySize.height / 2)
      )
      innerLayer.addSublayer(emojiLayer)
    }
    // Drop shadow (Extra Styles): 'glow' is a soft halo with no
    // offset (neon, hologram, spotlight); 'shadow' is a hard
    // offset drop (Big Bold Billboard). Layer space is y-up, so
    // down-right on screen is a negative-height offset.
    let shadowColor: UIColor? = {
      switch decorKind {
      case "glow", "shadow": return lyricColor(decor?.color)
      default: return nil
      }
    }()
    let shadowOpacity: Float = shadowColor == nil ? 0 : Float(lyricClamp(lyricFinite(decor?.opacity ?? 0.6, 0.6), 0, 1))
    let shadowRadius: CGFloat = decorKind == "shadow" ? font.pointSize * 0.08 : font.pointSize * 0.4
    let shadowOffset: CGSize =
      decorKind == "shadow"
      ? CGSize(width: font.pointSize * 0.08, height: -font.pointSize * 0.08)
      : .zero
    if let singleLayer {
      singleLayer.position = CGPoint(x: contentCentre.x, y: textCentreY)
      if let shadowColor {
        singleLayer.shadowColor = shadowColor.cgColor
        singleLayer.shadowOpacity = shadowOpacity
        singleLayer.shadowRadius = shadowRadius
        singleLayer.shadowOffset = shadowOffset
      }
      innerLayer.addSublayer(singleLayer)
    }
    for entry in wordEntries {
      // Rows are aligned within the content width per the decor
      // align (Stage 4 parity audit): the JS overlay left/right
      // aligns Minimal Mono's rows, and the old code centred
      // every row on both sides. contentOriginX is the left edge
      // of the text block inside the container.
      let contentOriginX = (containerSize.width - contentSize.width) / 2
      let rowOriginX: CGFloat
      switch decor?.align ?? "center" {
      case "left": rowOriginX = contentOriginX
      case "right": rowOriginX = contentOriginX + contentSize.width - rowWidths[entry.row]
      default: rowOriginX = contentOriginX + (contentSize.width - rowWidths[entry.row]) / 2
      }
      let position = CGPoint(
        x: rowOriginX + entry.centerX,
        y: contentCentre.y + (contentSize.height / 2 - entry.centerY)
      )
      entry.layer.position = position
      if let shadowColor {
        entry.layer.shadowColor = shadowColor.cgColor
        entry.layer.shadowOpacity = shadowOpacity
        entry.layer.shadowRadius = shadowRadius
        entry.layer.shadowOffset = shadowOffset
      }
      innerLayer.addSublayer(entry.layer)
      if let highlight = entry.highlight {
        highlight.position = position
        if let shadowColor {
          highlight.shadowColor = shadowColor.cgColor
          highlight.shadowOpacity = shadowOpacity
          highlight.shadowRadius = shadowRadius
          highlight.shadowOffset = shadowOffset
        }
        innerLayer.addSublayer(highlight)
        addLyricWordPopAnimation(
          to: highlight,
          wordStart: entry.wordStart,
          lineStart: start,
          lineDuration: lineDuration
        )
        // Karaoke current-word pop: the highlight scales to
        // emphasisScale while its word is sung (1.18 karaoke,
        // 1.3 karaoke-pop), then back to 1 — matching the JS
        // overlay's scaleX on the current word (Stage 4 audit;
        // the old code never popped the highlight at all).
        addLyricWordHighlightScaleAnimation(
          to: highlight,
          wordStart: entry.wordStart,
          wordEnd: entry.index < words.count ? words[entry.index].end : entry.wordStart,
          lineStart: start,
          lineDuration: lineDuration,
          emphasisScale: animation.emphasisScale
        )
      }
      switch wordMode {
      case "stagger":
        let stagger = max(0, lyricFinite(animation.wordStaggerSecs, 0.05))
        let wordBegin = min(max(start + Double(entry.index) * stagger, start), end - 0.05)
        if decorKind == "burst" || decorKind == "rain" {
          // Word Explosion: each word flies in from above, fanned
          // across the line (30°…150°); Rain is the same flight
          // straight down (90°), instead of the shared
          // from-transform.
          let count = max(1, wordEntries.count)
          let angle = decorKind == "rain"
            ? 90
            : 30 + (count > 1 ? Double(entry.index) / Double(count - 1) * 120 : 60)
          // Flight distance (Stage 4 parity audit): the JS
          // overlay flies words 2.2 × font size × scale — the
          // old content-size-based distance (≈ 4× larger on a
          // wide line) sent them off the frame.
          let distance = font.pointSize * 2.2
            * CGFloat(lyricClamp(lyricFinite(decor?.scale ?? 1, 1), 0.25, 3))
          addLyricWordBurstAnimation(
            to: entry.layer,
            animation: animation,
            wordBegin: wordBegin,
            lineEnd: end,
            angleDeg: angle,
            distance: distance
          )
        } else if decorKind == "bounce" {
          // Bounce House: each word pops in with a scale overshoot.
          addLyricWordBounceAnimation(
            to: entry.layer,
            animation: animation,
            wordBegin: wordBegin,
            lineEnd: end
          )
        } else {
          // Container size, not content size (Stage 4 audit):
          // the JS overlay scales the enter offsets by the line
          // box, which includes the padding.
          addLyricWordEnterAnimation(
            to: entry.layer,
            animation: animation,
            wordBegin: wordBegin,
            lineEnd: end,
            lineHeight: containerSize.height,
            lineWidth: containerSize.width
          )
        }
      case "typewriter":
        addLyricWordPopAnimation(
          to: entry.layer,
          wordStart: entry.wordStart,
          lineStart: start,
          lineDuration: lineDuration
        )
      default:
        break // karaoke base words are present for the whole line
      }
    }

    // Ghost trail (Extra Styles — Echo): a faded copy of the
    // text, offset down-right, inserted behind the live text but
    // in front of the backing. Static — the gate fades it with
    // the line, and it never carries a word animation.
    if decorKind == "ghost-trail", let decor = decor {
      let trailOpacity = Float(lyricClamp(lyricFinite(decor.opacity, 0.35), 0, 1))
      let trailScale = CGFloat(lyricClamp(lyricFinite(decor.scale ?? 1, 1), 0.25, 3))
      let dx = font.pointSize * 0.5 * trailScale
      var ghosts: [CALayer] = []
      if let singleLayer {
        let ghost = CALayer()
        ghost.contents = singleLayer.contents
        ghost.contentsScale = singleLayer.contentsScale
        ghost.contentsGravity = .resize
        ghost.bounds = singleLayer.bounds
        // Layer space is y-up: down-right on screen is (+x, −y).
        ghost.position = CGPoint(x: singleLayer.position.x + dx, y: singleLayer.position.y - dx)
        ghost.opacity = trailOpacity
        ghosts.append(ghost)
      }
      for entry in wordEntries {
        let ghost = CALayer()
        ghost.contents = entry.layer.contents
        ghost.contentsScale = entry.layer.contentsScale
        ghost.contentsGravity = .resize
        ghost.bounds = entry.layer.bounds
        // Same align-aware row origin as the live words above.
        let contentOriginX = (containerSize.width - contentSize.width) / 2
        let rowOriginX: CGFloat
        switch decor.align {
        case "left": rowOriginX = contentOriginX
        case "right": rowOriginX = contentOriginX + contentSize.width - rowWidths[entry.row]
        default: rowOriginX = contentOriginX + (contentSize.width - rowWidths[entry.row]) / 2
        }
        let position = CGPoint(
          x: rowOriginX + entry.centerX,
          y: contentCentre.y + (contentSize.height / 2 - entry.centerY)
        )
        ghost.position = CGPoint(x: position.x + dx, y: position.y - dx)
        ghost.opacity = trailOpacity
        ghosts.append(ghost)
      }
      for (i, ghost) in ghosts.enumerated() {
        innerLayer.insertSublayer(ghost, at: UInt32(min(contentInsertIndex + i, innerLayer.sublayers?.count ?? 0)))
      }
    }

    // Scanlines (Extra Styles — Hologram): thin translucent lines
    // across the text, drawn over it. The JS overlay measures
    // them against the CONTENT height/width (plus one font size
    // of overhang) — the old code used the container, so the
    // lines were spaced and sized to the padding, not the text.
    if decorKind == "scanlines", let decor = decor, let scanColor = lyricColor(decor.color) {
      let lineCount = 8
      let scanHeight = containerSize.height / CGFloat(lineCount * 4)
      let alpha = CGFloat(lyricClamp(lyricFinite(decor.opacity, 0.5), 0, 1)) * 0.4
      let scanWidth = contentSize.width + font.pointSize
      for i in 0..<lineCount {
        let scan = CALayer()
        scan.backgroundColor = scanColor.withAlphaComponent(alpha).cgColor
        scan.bounds = CGRect(origin: .zero, size: CGSize(width: scanWidth, height: scanHeight))
        scan.position = CGPoint(
          x: contentCentre.x,
          // y in layer space: content-relative, top row first
          // — (i + 0.5) / 8 down from the content's top.
          y: contentCentre.y + contentSize.height * (0.5 - (CGFloat(i) + 0.5) / CGFloat(lineCount))
        )
        innerLayer.addSublayer(scan)
      }
    }

    // Cursor (Extra Styles — Typewriter Classic): a blinking block
    // after the text, on the text's centre line. Typewriter-only
    // (Stage 4 parity audit): the JS overlay shows the cursor
    // only for typewriter lines; the old code drew it for any
    // line carrying the decor. It sits after the LAST word of
    // the LAST row — the old code put it at the content's right
    // edge at the text-block centre, which is wrong on a
    // wrapped line.
    if decorKind == "cursor", wordMode == "typewriter", let decor = decor, let cursorColor = lyricColor(decor.color) {
      let cursorWidth = font.pointSize * 0.45
      let cursorHeight = max(textHeight * 0.8, font.pointSize * 0.8)
      let cursor = CALayer()
      cursor.backgroundColor = cursorColor.cgColor
      cursor.bounds = CGRect(origin: .zero, size: CGSize(width: cursorWidth, height: cursorHeight))
      let lastRow = max(0, rowWidths.count - 1)
      let lastWord = wordEntries.filter { $0.row == lastRow }.max(by: { $0.centerX < $1.centerX })
      let contentOriginX = (containerSize.width - contentSize.width) / 2
      let lastRowOriginX: CGFloat
      switch decor.align {
      case "left": lastRowOriginX = contentOriginX
      case "right": lastRowOriginX = contentOriginX + contentSize.width - rowWidths[lastRow]
      default: lastRowOriginX = contentOriginX + (contentSize.width - rowWidths[lastRow]) / 2
      }
      let lastWordRight = lastWord.map {
        lastRowOriginX + $0.centerX + $0.layer.bounds.width / 2
      } ?? (contentCentre.x + contentSize.width / 2)
      let lastWordCentreY = lastWord.map {
        contentCentre.y + (contentSize.height / 2 - $0.centerY)
      } ?? textCentreY
      cursor.position = CGPoint(
        x: lastWordRight + cursorWidth / 2,
        y: lastWordCentreY
      )
      cursor.opacity = 0
      // Blink: discrete 1/0 every 0.5 s across the line window.
      // Key times are strictly increasing by construction (0,
      // 1/steps, …, 1), so no sanitising is needed.
      let steps = max(1, Int(lineDuration / 0.5))
      let blink = CAKeyframeAnimation(keyPath: "opacity")
      blink.values = (0...steps).map { NSNumber(value: $0 % 2 == 0 ? 1 : 0) }
      blink.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
      blink.duration = lineDuration
      blink.beginTime = AVCoreAnimationBeginTimeAtZero + start
      blink.calculationMode = .discrete
      blink.fillMode = .both
      blink.isRemovedOnCompletion = false
      cursor.add(blink, forKey: "lyricCursorBlink")
      innerLayer.addSublayer(cursor)
    }

    // Typing dots (Extra Styles — Text Message Typing): three
    // dots at the bubble's bottom-right, in the text colour,
    // visible for the first half second of the line while the
    // typewriter words appear.
    if decorKind == "typing-dots" {
      let dotRadius = font.pointSize * 0.08
      let dotColor = lyricColor(style.color) ?? .black
      let visibleFraction = lineDuration > 0 ? min(0.5 / lineDuration, 1) : 1
      for i in 0..<3 {
        let dot = CALayer()
        dot.backgroundColor = dotColor.cgColor
        dot.bounds = CGRect(origin: .zero, size: CGSize(width: dotRadius * 2, height: dotRadius * 2))
        dot.cornerRadius = dotRadius
        dot.position = CGPoint(
          x: containerSize.width - font.pointSize * (0.55 + CGFloat(2 - i) * 0.32),
          y: font.pointSize * 0.5
        )
        if visibleFraction >= 1 {
          dot.opacity = 1
        } else {
          dot.opacity = 0
          let show = CAKeyframeAnimation(keyPath: "opacity")
          show.values = [NSNumber(value: 1), NSNumber(value: 0)]
          show.keyTimes = [NSNumber(value: 0), NSNumber(value: visibleFraction)]
          show.duration = lineDuration
          show.beginTime = AVCoreAnimationBeginTimeAtZero + start
          show.calculationMode = .discrete
          show.fillMode = .both
          show.isRemovedOnCompletion = false
          dot.add(show, forKey: "lyricTypingDot")
        }
        innerLayer.addSublayer(dot)
      }
    }

    // Line enter/exit/emphasis on the inner layer. The per-word
    // modes animate their own entrances (stagger / typewriter), so
    // their inner layer carries only the exit + emphasis; 'none'
    // and 'karaoke' lines enter as a whole. The enter offsets are
    // scaled by the CONTAINER size — the JS overlay measures the
    // line box (text + padding), not the bare text. The emphasis
    // pulse applies only in 'none' word mode, matching the JS
    // overlay (Stage 4 parity audit).
    addLyricLineAnimations(
      to: innerLayer,
      animation: animation,
      applyEnter: wordMode == "none" || wordMode == "karaoke",
      applyPulse: wordMode == "none",
      start: start,
      lineDuration: lineDuration,
      lineHeight: containerSize.height,
      lineWidth: containerSize.width
    )

    return gateLayer
  }

  // MARK: Loudness (auto volume)

  /// The auto-volume gain decision — an EXACT mirror of
  /// normalizationGainDb in src/lib/loudness.ts (where it is unit
  /// tested); keep the two in step. Nil = apply nothing: a
  /// non-finite measurement (decode failure) or silence — a silent
  /// track must never be amplified into audibility.
  static func normalizationGainDb(measuredLufs: Double, peakDbfs: Double) -> Double? {
    guard measuredLufs.isFinite, peakDbfs.isFinite else { return nil }
    guard measuredLufs >= -60 else { return nil }
    let gain = min(-14 - measuredLufs, -1 - peakDbfs)
    return min(15, max(-15, gain))
  }

  /// Measures (or recalls) the loudness of one song region. Cached
  /// per path+size+mtime+region (LoudnessCache) because compositions
  /// rebuild on every edit. Any failure returns nil — the caller
  /// keeps unity gain, silently.
  private static func measureLoudness(
    asset: AVURLAsset,
    track: AVAssetTrack,
    range: CMTimeRange,
    cacheKey: String
  ) async -> LoudnessMeasurement? {
    if let cached = LoudnessCache.shared.get(cacheKey) {
      return cached
    }
    var sampleRate = 48_000.0
    var streamChannels = 2
    if let descriptions = try? await track.load(.formatDescriptions),
      let first = descriptions.first,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)
    {
      if asbd.pointee.mSampleRate > 0 { sampleRate = asbd.pointee.mSampleRate }
      if asbd.pointee.mChannelsPerFrame > 0 { streamChannels = Int(asbd.pointee.mChannelsPerFrame) }
    }
    guard
      let measurement = decodeLoudness(
        asset: asset,
        track: track,
        range: range,
        sampleRate: sampleRate,
        streamChannels: streamChannels
      )
    else {
      return nil
    }
    LoudnessCache.shared.set(cacheKey, measurement)
    return measurement
  }

  /// Stream-decodes the region at the track's native rate (Float32
  /// PCM, no full-track buffering — block energies accumulate on the
  /// fly) and computes a BS.1770-style K-weighted integrated
  /// loudness: per-channel K-weighting, 400 ms block energies,
  /// absolute gate at −70 LUFS, then the standard −10 LU relative
  /// gate. The peak is the raw SAMPLE peak (not true peak — no
  /// oversampling), the compact approximation the −1 dBFS ceiling
  /// budget allows for. At most the first two channels are measured
  /// (channel weights 1.0 — front L/R; surround content is not
  /// weighted up).
  private static func decodeLoudness(
    asset: AVAsset,
    track: AVAssetTrack,
    range: CMTimeRange,
    sampleRate: Double,
    streamChannels: Int
  ) -> LoudnessMeasurement? {
    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?
    let setupException = avTry {
      do {
        let createdReader = try AVAssetReader(asset: asset)
        createdReader.timeRange = range
        let outputSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
        let createdOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        createdOutput.alwaysCopiesSampleData = false
        if createdReader.canAdd(createdOutput) {
          createdReader.add(createdOutput)
          reader = createdReader
          output = createdOutput
        }
      } catch {
        // Unreadable — the guards below read nil as "unmeasurable".
      }
    }
    guard setupException == nil, let reader, let output, reader.startReading() else {
      return nil
    }

    let measuredChannels = max(1, min(2, streamChannels))
    let filters = (0..<measuredChannels).map { _ in KWeightingFilter() }
    let blockFrames = max(1, Int(0.4 * sampleRate))
    var blockSums = [Double](repeating: 0, count: measuredChannels)
    var framesInBlock = 0
    var blockEnergies: [Double] = []
    var peak = 0.0

    func flushBlock() {
      guard framesInBlock > 0 else { return }
      var z = 0.0
      for channel in 0..<measuredChannels {
        z += blockSums[channel] / Double(framesInBlock)
      }
      blockEnergies.append(z)
      blockSums = [Double](repeating: 0, count: measuredChannels)
      framesInBlock = 0
    }

    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let byteLength = CMBlockBufferGetDataLength(blockBuffer)
      let floatCount = byteLength / 4
      guard floatCount >= streamChannels else { continue }
      var floats = [Float](repeating: 0, count: floatCount)
      let copyStatus = floats.withUnsafeMutableBytes { pointer -> OSStatus in
        guard let baseAddress = pointer.baseAddress else { return OSStatus(-1) }
        return CMBlockBufferCopyDataBytes(
          blockBuffer,
          atOffset: 0,
          dataLength: floatCount * 4,
          destination: baseAddress
        )
      }
      guard copyStatus == noErr else { return nil }
      let frameCount = floatCount / streamChannels
      for frame in 0..<frameCount {
        let base = frame * streamChannels
        for channel in 0..<measuredChannels {
          let sample = Double(floats[base + channel])
          let magnitude = abs(sample)
          if magnitude > peak { peak = magnitude }
          let weighted = filters[channel].process(sample)
          blockSums[channel] += weighted * weighted
        }
        framesInBlock += 1
        if framesInBlock == blockFrames {
          flushBlock()
        }
      }
    }
    if reader.status == .failed {
      return nil
    }
    // A trailing partial block still counts when it holds ≥100 ms.
    if framesInBlock >= blockFrames / 4 {
      flushBlock()
    }
    guard !blockEnergies.isEmpty else { return nil }

    // Two-stage gating: absolute (−70 LUFS), then relative (−10 LU
    // under the absolute-gated result), per BS.1770.
    let absoluteGateZ = pow(10.0, (-70.0 + 0.691) / 10.0)
    let absoluteGated = blockEnergies.filter { $0 > absoluteGateZ }
    guard !absoluteGated.isEmpty else { return nil }
    let ungatedMean = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
    let ungatedLufs = -0.691 + 10.0 * log10(ungatedMean)
    let relativeGateZ = pow(10.0, (ungatedLufs - 10.0 + 0.691) / 10.0)
    let gated = absoluteGated.filter { $0 > relativeGateZ }
    let kept = gated.isEmpty ? absoluteGated : gated
    let integrated = -0.691 + 10.0 * log10(kept.reduce(0, +) / Double(kept.count))
    return LoudnessMeasurement(
      lufs: integrated.isFinite ? integrated : -120,
      peakDbfs: peak > 0 ? 20.0 * log10(peak) : -120
    )
  }

  // MARK: Auto EQ (harshness taming)

  /// Recipe version for the analysis + render below. Bumped whenever
  /// the band layout, gain logic or render chain changes, so a cached
  /// render from an older recipe is never reused (it is part of the
  /// cache key).
  private static let eqSettingsVersion = 1

  /// Band centres (Hz): octave-ish spacing with extra resolution
  /// through the harshness region (2–8 kHz), where the ear is most
  /// sensitive and where harsh masters pile up energy.
  private static let eqBandCentersHz: [Double] = [
    125, 250, 500, 1_000, 2_000, 3_000, 4_000, 6_000, 8_000, 12_000,
  ]

  /// Indices into eqBandCentersHz that count as harsh (2–8 kHz).
  private static let eqHarshBandIndices: Set<Int> = [4, 5, 6, 7, 8]

  /// A harsh band must sit at least this far above the song's
  /// average band level before any cut is taken — below that the
  /// band is just part of the song's tone, not harshness.
  private static let eqExcessThresholdDb = 2.0

  /// The deepest cut Auto EQ will ever take.
  private static let eqMaxCutDb = 6.0

  /// At or below this broadband level the file counts as silence:
  /// no cuts (never process noise into a "tone").
  private static let eqSilenceDbfs = -60.0

  /// Auto EQ entry point (bridge: `prepareEqSong`). Returns the URI
  /// composition builds should use for this song: a cached,
  /// EQ-rendered copy when the song measures harsh, or the ORIGINAL
  /// uri when it doesn't — and the original on ANY failure. Never
  /// throws, so a preview or export can never be blocked on EQ.
  /// Only composition builds consume the result; capture, record-time
  /// playback and the sync measurement always use the original file.
  static func prepareEqSong(_ uri: String) async -> String {
    let sourceURL = resolveURL(uri)
    guard sourceURL.isFileURL else { return uri }
    let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    let fileMtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    guard fileSize > 0 else { return uri }
    let cacheKey =
      "\(sourceURL.path)|\(fileSize)|\(fileMtime)|eqv\(eqSettingsVersion)"
    if let cached = EqRenderCache.shared.get(cacheKey) {
      return cached
    }
    guard let outputURL = eqCacheFileURL(cacheKey: cacheKey) else { return uri }
    if FileManager.default.fileExists(atPath: outputURL.path) {
      EqRenderCache.shared.set(cacheKey, outputURL.absoluteString)
      return outputURL.absoluteString
    }
    guard let gainsDb = await analyzeEqGains(asset: AVURLAsset(url: sourceURL)) else {
      return uri
    }
    // Nothing worth cutting: the original IS the answer (and what
    // the session remembers, so the song isn't re-analyzed on every
    // preview rebuild).
    if gainsDb.allSatisfy({ $0 == 0 }) {
      EqRenderCache.shared.set(cacheKey, uri)
      return uri
    }
    guard renderEqSong(sourceURL: sourceURL, gainsDb: gainsDb, outputURL: outputURL) else {
      return uri
    }
    EqRenderCache.shared.set(cacheKey, outputURL.absoluteString)
    return outputURL.absoluteString
  }

  /// The on-disk home of one rendered song: Application Support,
  /// keyed by an FNV-1a hash of the cache key (stable across
  /// launches; no crypto import needed for a cache filename).
  private static func eqCacheFileURL(cacheKey: String) -> URL? {
    guard
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    else { return nil }
    let directory = support.appendingPathComponent("MVMTStudio/eq", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in cacheKey.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return directory.appendingPathComponent(String(format: "eq-%016llx.wav", hash))
  }

  /// Measures the FULL song's per-band levels and turns them into
  /// per-band gains in dB (cuts only, 0 … −6 dB). Nil when the file
  /// can't be decoded — the caller keeps the original song.
  ///
  /// The logic: stream-decode once, run every channel (first two)
  /// through the bandpass bank, and take each band's RMS level.
  /// Harshness is RELATIVE: a harsh band's excess over the song's
  /// average band level (the mean of all band levels) beyond a
  /// gentle 2 dB threshold becomes its cut, clamped to 6 dB. Each
  /// cut then shoulders half-strength onto its immediate neighbour
  /// bands so the correction is smooth rather than notchy. A quiet
  /// or spectrally balanced song measures no excess and gets all
  /// zeros — no render, no change.
  private static func analyzeEqGains(asset: AVURLAsset) async -> [Double]? {
    let bandCount = eqBandCentersHz.count
    let zeroGains = [Double](repeating: 0, count: bandCount)
    guard let track = (try? await asset.loadTracks(withMediaType: .audio))?.first else {
      return nil
    }
    var sampleRate = 48_000.0
    var streamChannels = 2
    if let descriptions = try? await track.load(.formatDescriptions),
      let first = descriptions.first,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)
    {
      if asbd.pointee.mSampleRate > 0 { sampleRate = asbd.pointee.mSampleRate }
      if asbd.pointee.mChannelsPerFrame > 0 { streamChannels = Int(asbd.pointee.mChannelsPerFrame) }
    }
    let measuredChannels = max(1, min(2, streamChannels))
    // Bands too close to Nyquist can't be designed or measured at
    // this sample rate; they report no energy and take no cut.
    let measurable = eqBandCentersHz.map { $0 < sampleRate * 0.45 }

    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?
    let setupException = avTry {
      do {
        let createdReader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
        let createdOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        createdOutput.alwaysCopiesSampleData = false
        if createdReader.canAdd(createdOutput) {
          createdReader.add(createdOutput)
          reader = createdReader
          output = createdOutput
        }
      } catch {
        // Unreadable — the guards below read nil as "unmeasurable".
      }
    }
    guard setupException == nil, let reader, let output, reader.startReading() else {
      return nil
    }

    let filters: [[BandpassFilter]] = (0..<measuredChannels).map { _ in
      eqBandCentersHz.map { BandpassFilter(centerHz: $0, sampleRate: sampleRate) }
    }
    var bandSums = [[Double]](
      repeating: [Double](repeating: 0, count: bandCount),
      count: measuredChannels
    )
    var rawSums = [Double](repeating: 0, count: measuredChannels)
    var frameCount = 0

    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let byteLength = CMBlockBufferGetDataLength(blockBuffer)
      let floatCount = byteLength / 4
      guard floatCount >= streamChannels else { continue }
      var floats = [Float](repeating: 0, count: floatCount)
      let copyStatus = floats.withUnsafeMutableBytes { pointer -> OSStatus in
        guard let baseAddress = pointer.baseAddress else { return OSStatus(-1) }
        return CMBlockBufferCopyDataBytes(
          blockBuffer,
          atOffset: 0,
          dataLength: floatCount * 4,
          destination: baseAddress
        )
      }
      guard copyStatus == noErr else { return nil }
      let frames = floatCount / streamChannels
      for frame in 0..<frames {
        let base = frame * streamChannels
        for channel in 0..<measuredChannels {
          let sample = Double(floats[base + channel])
          rawSums[channel] += sample * sample
          for band in 0..<bandCount where measurable[band] {
            let filtered = filters[channel][band].process(sample)
            bandSums[channel][band] += filtered * filtered
          }
        }
      }
      frameCount += frames
    }
    if reader.status == .failed {
      return nil
    }
    guard frameCount > 0 else { return nil }

    // Broadband level: silence (or digital black) takes no cuts.
    let broadbandEnergy =
      rawSums.reduce(0, +) / Double(measuredChannels) / Double(frameCount)
    guard broadbandEnergy > 0 else { return zeroGains }
    let broadbandDb = 10.0 * log10(broadbandEnergy)
    guard broadbandDb >= eqSilenceDbfs else { return zeroGains }

    // Per-band levels (channels averaged in the energy domain).
    // Levels are floored at −80 dB before averaging into the
    // reference so a band with essentially no content (e.g. 12 kHz
    // in a lo-fi recording) can't drag the reference down and make
    // every other band look "excessive".
    var bandLevels = [Double](repeating: -120, count: bandCount)
    for band in 0..<bandCount where measurable[band] {
      var energy = 0.0
      for channel in 0..<measuredChannels {
        energy += bandSums[channel][band]
      }
      energy /= Double(measuredChannels) * Double(frameCount)
      if energy > 0 {
        bandLevels[band] = 10.0 * log10(energy)
      }
    }
    let flooredLevels = bandLevels.map { max($0, -80) }
    let referenceDb = flooredLevels.reduce(0, +) / Double(bandCount)

    // Raw cuts: harsh bands only, excess over the threshold.
    var rawCuts = [Double](repeating: 0, count: bandCount)
    for band in eqHarshBandIndices where measurable[band] {
      let excess = bandLevels[band] - referenceDb - eqExcessThresholdDb
      rawCuts[band] = min(eqMaxCutDb, max(0, excess))
    }
    // Smooth: every band also takes half of its strongest
    // neighbour's raw cut, so the correction shoulders gently into
    // the bands beside the harsh region (1 kHz and 12 kHz included)
    // instead of stepping at the region's edges.
    var gainsDb = [Double](repeating: 0, count: bandCount)
    for band in 0..<bandCount {
      var cut = rawCuts[band]
      if band > 0 { cut = max(cut, rawCuts[band - 1] / 2) }
      if band < bandCount - 1 { cut = max(cut, rawCuts[band + 1] / 2) }
      gainsDb[band] = -min(eqMaxCutDb, cut)
    }
    return gainsDb
  }

  /// Renders the full song through an AVAudioUnitEQ in AVAudioEngine
  /// offline (manual-rendering) mode into `outputURL`, preserving
  /// the source's EXACT frame count. The output is LPCM WAV — no
  /// encoder delay or priming samples — so the processed song lines
  /// up sample-for-sample with the original: region starts, cut
  /// timing and sync are untouched. Renders to a temp file and moves
  /// it into place only when complete, so a partial render is never
  /// served from the cache. False on any failure; the caller falls
  /// back to the original song.
  private static func renderEqSong(
    sourceURL: URL,
    gainsDb: [Double],
    outputURL: URL
  ) -> Bool {
    let tempURL = outputURL.deletingPathExtension()
      .appendingPathExtension("tmp-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    do {
      let sourceFile = try AVAudioFile(forReading: sourceURL)
      let format = sourceFile.processingFormat
      let totalFrames = sourceFile.length
      guard totalFrames > 0, format.sampleRate > 0, format.channelCount > 0 else {
        return false
      }

      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      let eq = AVAudioUnitEQ(numberOfBands: eqBandCentersHz.count)
      engine.attach(player)
      engine.attach(eq)
      engine.connect(player, to: eq, format: format)
      engine.connect(eq, to: engine.mainMixerNode, format: format)
      for (index, band) in eq.bands.enumerated() {
        band.filterType = .parametric
        // Clamp under Nyquist for very low sample rates; the
        // analysis already measured nothing up there in that case.
        band.frequency = Float(min(eqBandCentersHz[index], format.sampleRate * 0.45))
        band.bandwidth = 1.0  // octaves — matches the analysis width
        band.gain = Float(gainsDb[index])
        band.bypass = gainsDb[index] == 0
      }
      eq.globalGain = 0  // cuts only — no makeup boost, ever

      let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: !format.isInterleaved,
      ]
      let outputFile = try AVAudioFile(
        forWriting: tempURL,
        settings: outputSettings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
      )

      try engine.enableManualRenderingMode(
        .offline,
        format: format,
        maximumFrameCount: 4096
      )
      player.scheduleFile(sourceFile, at: nil)
      try engine.start()
      player.play()

      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: engine.manualRenderingFormat,
          frameCapacity: 4096
        )
      else {
        engine.stop()
        return false
      }
      var written: AVAudioFramePosition = 0
      var stalledRenders = 0
      while written < totalFrames {
        let framesToRender = AVAudioFrameCount(
          min(4096, AVAudioFramePosition(totalFrames - written))
        )
        let status = try engine.renderOffline(framesToRender, to: buffer)
        switch status {
        case .success, .insufficientDataFromInputNode:
          if buffer.frameLength > 0 {
            try outputFile.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
            stalledRenders = 0
          } else {
            stalledRenders += 1
            if stalledRenders > 8 { engine.stop(); return false }
          }
        case .cannotDoInCurrentContext:
          // Transient by contract, but never spin forever on it.
          stalledRenders += 1
          if stalledRenders > 64 { engine.stop(); return false }
        case .error:
          engine.stop()
          return false
        @unknown default:
          engine.stop()
          return false
        }
      }
      engine.stop()
      guard written == totalFrames else { return false }
      try FileManager.default.moveItem(at: tempURL, to: outputURL)
      return true
    } catch {
      return false
    }
  }

  // MARK: Mix & Master — Stage 1 (dynamic corrective EQ)
  //
  // Same corrective idea as Auto EQ (cuts only, harsh + mud bands
  // measured against the song's own band balance), but measured in
  // 1.0 s windows with 50% overlap and applied as a SMOOTHED,
  // time-varying gain curve — never a per-second EQ switch. The
  // profile (smoothed windows + findings) is stored as JSON beside
  // the rendered WAV so the Stage 3 UI can draw it without
  // re-analyzing. The render is a new file in MVMTStudio/mixmaster;
  // the original is never touched and any failure returns it.
  // `renderEqSong` is deliberately left untouched — this stage
  // mirrors its render loop instead of refactoring it, so Auto EQ's
  // proven path stays byte-identical.

  /// Recipe version for the Stage 1 analysis + render. Part of the
  /// cache key; bump when the window layout, gain logic or render
  /// chain changes.
  /// Bumped to 2 in Stage 2: the Master EQ stage joined the
  /// chain, so Stage 1 renders must never be served for Stage 2
  /// settings. Mirrors MIX_MASTER_PROFILE_VERSION.
  private static let mixMasterProfileVersion = 2

  /// Analysis windows: 1.0 s long, 50% overlap — a new analysis
  /// point every 0.5 s.
  private static let mmWindowSeconds = 1.0
  private static let mmHopSeconds = 0.5

  /// A window holding less than this much audio is dropped (except
  /// the first, so a sub-second song still gets one analysis point).
  private static let mmMinWindowSeconds = 0.25

  /// Smoothing: 3-point moving average across windows, then a slew
  /// limit of ±1.5 dB per 100 ms of song time.
  private static let mmSlewDbPer100ms = 1.5

  /// Only cuts at or above this depth are reported as findings.
  private static let mmFindingMinCutDb = 1.0
  /// The findings list is capped at the deepest cuts (keeps the
  /// stored profile small on long songs).
  private static let mmMaxFindings = 100

  /// Low-mid bands that count as "mud" under the same excess rule
  /// as the harsh bands (250 Hz, 500 Hz).
  private static let mmMudBandIndices: Set<Int> = [1, 2]

  /// Master EQ target curve, dB per band (same band order as
  /// Auto EQ: 125, 250, 500, 1k, 2k, 3k, 4k, 6k, 8k, 12k Hz): a
  /// slight low-end shelf, flat mids, a gentle high shelf. A
  /// constant, tuned by ear on device — not per-song magic.
  /// Mirrors MM_MASTER_TARGET_DB in src/lib/mixMasterCurve.ts.
  private static let mmMasterTargetDb: [Double] = [
    1.5, 1.0, 0.5, 0, 0, 0, 0, 0.5, 1.0, 1.5,
  ]
  /// Master EQ gain clamp, dB — cuts AND boosts are allowed here.
  private static let mmMasterMaxGainDb = 3.0
  /// A song quieter than this broadband takes no master EQ at all.
  private static let mmMasterSilenceDbfs = -60.0
  /// Corrected band levels at or below this floor count as no energy.
  private static let mmMasterLevelFloorDb = -80.0
  /// A band carries energy when its corrected level is within this
  /// many dB of the loudest band.
  private static let mmMasterActiveBelowPeakDb = 25.0

  private struct MixMasterWindowRecord: Codable {
    var timeSeconds: Double
    var gainsDb: [Double]
  }

  private struct MixMasterFindingRecord: Codable {
    var timeSeconds: Double
    var bandHz: Double
    var cutDb: Double
    var reason: String
  }

  /// Per-stage controls (Stage 2), as stored in the profile and
  /// as passed in from JS (resolved there; the native resolver
  /// below is the backstop for direct callers). The master switch
  /// is separate (`mixMasterEnabled` on the project): these only
  /// matter while the suite is on. Unset reads as both stages ON
  /// at full intensity.
  private struct MixMasterStageSettingsRecord: Codable {
    var correctiveEnabled: Bool
    var correctiveIntensity: Double
    var masterEnabled: Bool
    var masterIntensity: Double
  }

  /// Clamp raw bridge arguments to the effective settings set.
  private static func resolveMmStageSettings(
    correctiveEnabled: Bool,
    correctiveIntensity: Double,
    masterEnabled: Bool,
    masterIntensity: Double
  ) -> MixMasterStageSettingsRecord {
    func intensity(_ value: Double) -> Double {
      value.isFinite ? min(100, max(0, value)) : 100
    }
    return MixMasterStageSettingsRecord(
      correctiveEnabled: correctiveEnabled,
      correctiveIntensity: intensity(correctiveIntensity),
      masterEnabled: masterEnabled,
      masterIntensity: intensity(masterIntensity)
    )
  }

  /// Canonical cache-key fragment for a resolved settings set.
  /// Mirrors mixMasterStageSettingsKey in mixMasterCurve.ts.
  private static func mmStageSettingsKey(_ settings: MixMasterStageSettingsRecord) -> String {
    "c\(settings.correctiveEnabled ? 1 : 0):\(Int(settings.correctiveIntensity))" +
      "|m\(settings.masterEnabled ? 1 : 0):\(Int(settings.masterIntensity))"
  }

  private struct MixMasterProfileRecord: Codable {
    var version: Int
    var songKey: String
    var sampleRate: Double
    var durationSeconds: Double
    var windows: [MixMasterWindowRecord]
    var findings: [MixMasterFindingRecord]
    /// Master EQ gains as applied (post toggle/intensity).
    var masterGainsDb: [Double]
    /// The stage settings the render was made with.
    var stages: MixMasterStageSettingsRecord
  }

  /// Smooths raw per-window gains: (a) a 3-point moving average
  /// across windows, per band, then (b) a slew limit applied
  /// sequentially per band. Mirrors `smoothGainCurve` in
  /// src/lib/mixMasterCurve.ts; the Node tests pin it.
  private static func smoothMmGains(_ raw: [[Double]]) -> [[Double]] {
    guard !raw.isEmpty else { return [] }
    let bandCount = eqBandCentersHz.count
    var averaged = raw
    for i in raw.indices {
      for b in 0..<bandCount {
        var sum = raw[i][b]
        var n = 1
        if i > 0 { sum += raw[i - 1][b]; n += 1 }
        if i < raw.count - 1 { sum += raw[i + 1][b]; n += 1 }
        averaged[i][b] = sum / Double(n)
      }
    }
    let maxStep = mmSlewDbPer100ms * (mmHopSeconds / 0.1)
    var out: [[Double]] = [averaged[0]]
    for i in 1..<averaged.count {
      var gains = averaged[i]
      for b in 0..<bandCount {
        let prev = out[i - 1][b]
        gains[b] = max(prev - maxStep, min(prev + maxStep, gains[b]))
      }
      out.append(gains)
    }
    return out
  }

  /// The smoothed gain set at a song time: linear interpolation
  /// between the bracketing analysis points, clamped to the first /
  /// last window outside the range. Mirrors `mixMasterGainAtTime`
  /// in src/lib/mixMasterCurve.ts.
  private static func mmGainAtTime(
    windows: [MixMasterWindowRecord],
    timeSeconds: Double
  ) -> [Double] {
    let zero = [Double](repeating: 0, count: eqBandCentersHz.count)
    guard let first = windows.first else { return zero }
    if timeSeconds <= first.timeSeconds { return first.gainsDb }
    guard let last = windows.last else { return first.gainsDb }
    if timeSeconds >= last.timeSeconds { return last.gainsDb }
    for i in 1..<windows.count {
      if timeSeconds <= windows[i].timeSeconds {
        let a = windows[i - 1]
        let b = windows[i]
        let span = b.timeSeconds - a.timeSeconds
        let f = span > 0 ? (timeSeconds - a.timeSeconds) / span : 0
        return zip(a.gainsDb, b.gainsDb).map { $0.0 + ($0.1 - $0.0) * f }
      }
    }
    return last.gainsDb
  }

  /// Mean applied corrective gain per band, over the stored
  /// windows. Mirrors meanGainPerBand in mixMasterCurve.ts.
  private static func mmMeanGains(_ windows: [MixMasterWindowRecord]) -> [Double] {
    let bandCount = eqBandCentersHz.count
    guard !windows.isEmpty else { return [Double](repeating: 0, count: bandCount) }
    var sums = [Double](repeating: 0, count: bandCount)
    for window in windows {
      for b in 0..<bandCount {
        sums[b] += window.gainsDb[b]
      }
    }
    return sums.map { $0 / Double(windows.count) }
  }

  /// The Master EQ gain set for a song: one static gain per band,
  /// driving the whole-song balance toward the target curve.
  /// Mirrors computeMasterGains in mixMasterCurve.ts exactly
  /// (same order of operations): the balance is measured on the
  /// CORRECTED signal (raw overall level + mean applied
  /// corrective gain per band), the reference is the mean of
  /// (corrected level − target) over the bands that carry energy
  /// (peak-relative, within 25 dB of the loudest band), gains are
  /// clamped to ±3 dB, and a near-silent song gets no master EQ.
  /// Returns the RAW master gains (pre toggle/intensity) — the
  /// caller scales them.
  private static func mmMasterGains(
    overallLevelsDb: [Double],
    meanCorrectiveGainsDb: [Double],
    broadbandDbfs: Double
  ) -> [Double] {
    let bandCount = eqBandCentersHz.count
    guard overallLevelsDb.count == bandCount,
          meanCorrectiveGainsDb.count == bandCount
    else {
      return [Double](repeating: 0, count: bandCount)
    }
    guard broadbandDbfs >= mmMasterSilenceDbfs else {
      return [Double](repeating: 0, count: bandCount)
    }
    let floored = overallLevelsDb.enumerated().map { (b, level) in
      max(level + meanCorrectiveGainsDb[b], mmMasterLevelFloorDb)
    }
    guard let peak = floored.max() else {
      return [Double](repeating: 0, count: bandCount)
    }
    let active = floored.map { $0 > peak - mmMasterActiveBelowPeakDb }
    var referenceSum = 0.0
    var activeCount = 0
    for b in 0..<bandCount where active[b] {
      referenceSum += floored[b] - mmMasterTargetDb[b]
      activeCount += 1
    }
    guard activeCount > 0 else {
      return [Double](repeating: 0, count: bandCount)
    }
    let reference = referenceSum / Double(activeCount)
    return floored.enumerated().map { (b, level) in
      guard active[b] else { return 0 }
      let gain = reference + mmMasterTargetDb[b] - level
      return max(-mmMasterMaxGainDb, min(mmMasterMaxGainDb, gain))
    }
  }

  /// The on-disk home of one Mix & Master render + profile:
  /// Application Support, keyed by an FNV-1a hash of the cache key
  /// (same scheme as the Auto EQ cache, separate directory).
  private static func mixMasterCacheFileURL(cacheKey: String) -> URL? {
    guard
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    else { return nil }
    let directory = support.appendingPathComponent("MVMTStudio/mixmaster", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in cacheKey.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return directory.appendingPathComponent(String(format: "mm-%016llx.wav", hash))
  }

  /// The profile lives beside its render, same base name, .json.
  private static func mixMasterProfileURL(for outputURL: URL) -> URL {
    outputURL.deletingPathExtension().appendingPathExtension("json")
  }

  /// Writes the profile JSON beside the render (temp file moved
  /// into place only when complete). Best effort — a missing
  /// profile never blocks serving the render.
  private static func writeMixMasterProfile(_ profile: MixMasterProfileRecord, to url: URL) {
    let tempURL = url.deletingPathExtension()
      .appendingPathExtension("tmp-\(UUID().uuidString).json")
    do {
      let data = try JSONEncoder().encode(profile)
      try data.write(to: tempURL)
      if FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.removeItem(at: url)
      }
      try FileManager.default.moveItem(at: tempURL, to: url)
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
    }
  }

  /// Mix & Master entry point (bridge: `prepareMixMasterSong`).
  /// Returns the URI composition builds should use for this song:
  /// a cached, processed copy when either stage has anything to
  /// do, or the ORIGINAL uri when it doesn't — and the original
  /// on ANY failure. Never throws, so a preview or export can
  /// never be blocked on it. Only composition builds consume the
  /// result; capture, record-time playback and the sync
  /// measurement always use the original file.
  ///
  /// Stage 2: the chain is [dynamic corrective EQ] → [static
  /// Master EQ], each with its own toggle + intensity. The
  /// settings ride the cache key, so a settings change re-renders
  /// and identical settings never re-render twice.
  static func prepareMixMasterSong(
    _ uri: String,
    correctiveEnabled: Bool,
    correctiveIntensity: Double,
    masterEnabled: Bool,
    masterIntensity: Double
  ) async -> String {
    let settings = resolveMmStageSettings(
      correctiveEnabled: correctiveEnabled,
      correctiveIntensity: correctiveIntensity,
      masterEnabled: masterEnabled,
      masterIntensity: masterIntensity
    )
    let sourceURL = resolveURL(uri)
    guard sourceURL.isFileURL else { return uri }
    let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    let fileMtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    guard fileSize > 0 else { return uri }
    let cacheKey =
      "\(sourceURL.path)|\(fileSize)|\(fileMtime)|mmv\(mixMasterProfileVersion)|\(mmStageSettingsKey(settings))"
    if let cached = EqRenderCache.shared.get(cacheKey) {
      return cached
    }
    guard let outputURL = mixMasterCacheFileURL(cacheKey: cacheKey) else { return uri }
    let profileURL = mixMasterProfileURL(for: outputURL)
    if FileManager.default.fileExists(atPath: outputURL.path) {
      // Render cached; make sure its profile is beside it (an
      // interrupted earlier run could have left the WAV without one).
      if !FileManager.default.fileExists(atPath: profileURL.path),
         let analysis = await analyzeMixMaster(asset: AVURLAsset(url: sourceURL), settings: settings) {
        writeMixMasterProfile(
          MixMasterProfileRecord(
            version: mixMasterProfileVersion,
            songKey: cacheKey,
            sampleRate: analysis.sampleRate,
            durationSeconds: analysis.durationSeconds,
            windows: analysis.windows,
            findings: analysis.findings,
            masterGainsDb: analysis.masterGainsDb,
            stages: settings
          ),
          to: profileURL
        )
      }
      EqRenderCache.shared.set(cacheKey, outputURL.absoluteString)
      return outputURL.absoluteString
    }
    guard let analysis = await analyzeMixMaster(asset: AVURLAsset(url: sourceURL), settings: settings) else {
      return uri
    }
    // Nothing worth changing anywhere: the original IS the answer
    // (and what the session remembers, so the song isn't
    // re-analyzed on every preview rebuild). Both stages count —
    // a master-only correction still renders.
    if analysis.windows.allSatisfy({ $0.gainsDb.allSatisfy({ $0 == 0 }) })
        && analysis.masterGainsDb.allSatisfy({ $0 == 0 }) {
      EqRenderCache.shared.set(cacheKey, uri)
      return uri
    }
    guard renderMixMasterSong(
      sourceURL: sourceURL,
      windows: analysis.windows,
      masterGainsDb: analysis.masterGainsDb,
      outputURL: outputURL
    ) else {
      return uri
    }
    writeMixMasterProfile(
      MixMasterProfileRecord(
        version: mixMasterProfileVersion,
        songKey: cacheKey,
        sampleRate: analysis.sampleRate,
        durationSeconds: analysis.durationSeconds,
        windows: analysis.windows,
        findings: analysis.findings,
        masterGainsDb: analysis.masterGainsDb,
        stages: settings
      ),
      to: profileURL
    )
    EqRenderCache.shared.set(cacheKey, outputURL.absoluteString)
    return outputURL.absoluteString
  }

  /// Mix & Master profile reader (bridge: `getMixMasterProfile`,
  /// Stage 3 UI). Returns the stored profile JSON for this song +
  /// stage settings, or nil when the engine has nothing for it.
  /// The profile file is written beside the render by
  /// `prepareMixMasterSong`; when it is missing — an interrupted
  /// earlier run, or a song whose gains are all zero so no render
  /// was written — the analysis runs again and the profile is built
  /// from it directly (no render, no file write), so the UI can
  /// still show the flat curve and "already balanced" instead of a
  /// blank screen. Never throws: a missing file or an undecodable
  /// song is nil, not an error.
  static func mixMasterProfile(
    _ uri: String,
    correctiveEnabled: Bool,
    correctiveIntensity: Double,
    masterEnabled: Bool,
    masterIntensity: Double
  ) async -> String? {
    let settings = resolveMmStageSettings(
      correctiveEnabled: correctiveEnabled,
      correctiveIntensity: correctiveIntensity,
      masterEnabled: masterEnabled,
      masterIntensity: masterIntensity
    )
    let sourceURL = resolveURL(uri)
    guard sourceURL.isFileURL else { return nil }
    let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    let fileMtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    guard fileSize > 0 else { return nil }
    let cacheKey =
      "\(sourceURL.path)|\(fileSize)|\(fileMtime)|mmv\(mixMasterProfileVersion)|\(mmStageSettingsKey(settings))"
    guard let outputURL = mixMasterCacheFileURL(cacheKey: cacheKey) else { return nil }
    let profileURL = mixMasterProfileURL(for: outputURL)
    if let data = try? Data(contentsOf: profileURL),
       let json = String(data: data, encoding: .utf8), !json.isEmpty {
      return json
    }
    guard let analysis = await analyzeMixMaster(asset: AVURLAsset(url: sourceURL), settings: settings) else {
      return nil
    }
    let profile = MixMasterProfileRecord(
      version: mixMasterProfileVersion,
      songKey: cacheKey,
      sampleRate: analysis.sampleRate,
      durationSeconds: analysis.durationSeconds,
      windows: analysis.windows,
      findings: analysis.findings,
      masterGainsDb: analysis.masterGainsDb,
      stages: settings
    )
    guard let data = try? JSONEncoder().encode(profile) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Mix & Master Stage 4: transcode a processed (Float32 WAV)
  /// render to AAC (.m4a, AppleM4A preset — 256 kbps) at the given
  /// destination, for sharing. Returns the destination URI on
  /// success, nil on any failure — never throws, so the JS side
  /// treats nil as "export failed" and the track is never touched.
  /// The WAV export needs no native code at all (a plain file copy
  /// on the JS side); only the compressed format comes through
  /// here. A stale partial file at the destination would make the
  /// session fail outright, so it starts clean — and a failed
  /// session's partial output is removed so a retry starts clean.
  static func exportMixMasterAac(sourceUri: String, destinationUri: String) async -> String? {
    let sourceURL = resolveURL(sourceUri)
    let destinationURL = resolveURL(destinationUri)
    guard sourceURL.isFileURL, destinationURL.isFileURL else { return nil }
    guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try? FileManager.default.removeItem(at: destinationURL)
    }
    let asset = AVURLAsset(url: sourceURL)
    var createdExporter: AVAssetExportSession?
    let exporterException = avTry {
      guard
        let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
      else { return }
      session.outputURL = destinationURL
      session.outputFileType = .m4a
      session.shouldOptimizeForNetworkUse = false
      createdExporter = session
    }
    if exporterException != nil { return nil }
    guard let exporter = createdExporter else { return nil }
    let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      exporter.exportAsynchronously {
        if exporter.status == .completed {
          continuation.resume(returning: true)
        } else {
          try? FileManager.default.removeItem(at: destinationURL)
          continuation.resume(returning: false)
        }
      }
    }
    return ok ? destinationURL.absoluteString : nil
  }

  /// Measures the song in 1.0 s windows (50% overlap) and turns
  /// each window's band balance into per-band gains in dB (cuts
  /// only, 0 … −6 dB), then smooths the whole curve. Nil when the
  /// file can't be decoded — the caller keeps the original song.
  ///
  /// Per window the rule is Auto EQ's rule applied to THAT window's
  /// balance: harsh (2–8 kHz) and mud (250/500 Hz) bands whose level
  /// exceeds the window's mean band level by more than 2 dB take a
  /// cut equal to the excess (clamped to 6 dB), shouldered
  /// half-strength onto neighbours. A window quieter than −60 dBFS
  /// broadband takes no cuts (never process noise into "tone").
  /// The filters run CONTINUOUSLY across the song — only the energy
  /// accumulators reset at window boundaries — so there is no
  /// filter transient at a window edge; the gains are interpolated
  /// at render time, so the audio path never sees a window edge.
  /// Overlapping windows are handled with two live accumulators:
  /// each sample's filtered energy lands in every window that
  /// covers it.
  ///
  /// Stage 2: the same decode pass also accumulates the
  /// WHOLE-SONG band levels for the Master EQ, and the returned
  /// windows are the APPLIED gains (smoothed, then scaled by the
  /// corrective stage's toggle/intensity). The master gains are
  /// computed from the corrected overall levels (see the tail of
  /// this function). `settings` is already resolved.
  private static func analyzeMixMaster(
    asset: AVURLAsset,
    settings: MixMasterStageSettingsRecord
  ) async -> (
    windows: [MixMasterWindowRecord],
    findings: [MixMasterFindingRecord],
    masterGainsDb: [Double],
    sampleRate: Double,
    durationSeconds: Double
  )? {
    let bandCount = eqBandCentersHz.count
    guard let track = (try? await asset.loadTracks(withMediaType: .audio))?.first else {
      return nil
    }
    var sampleRate = 48_000.0
    var streamChannels = 2
    if let descriptions = try? await track.load(.formatDescriptions),
      let first = descriptions.first,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)
    {
      if asbd.pointee.mSampleRate > 0 { sampleRate = asbd.pointee.mSampleRate }
      if asbd.pointee.mChannelsPerFrame > 0 { streamChannels = Int(asbd.pointee.mChannelsPerFrame) }
    }
    let measuredChannels = max(1, min(2, streamChannels))
    // Bands too close to Nyquist can't be designed or measured at
    // this sample rate; they report no energy and take no cut.
    let measurable = eqBandCentersHz.map { $0 < sampleRate * 0.45 }

    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?
    let setupException = avTry {
      do {
        let createdReader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
        let createdOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        createdOutput.alwaysCopiesSampleData = false
        if createdReader.canAdd(createdOutput) {
          createdReader.add(createdOutput)
          reader = createdReader
          output = createdOutput
        }
      } catch {
        // Unreadable — the guards below read nil as "unmeasurable".
      }
    }
    guard setupException == nil, let reader, let output, reader.startReading() else {
      return nil
    }

    let filters: [[BandpassFilter]] = (0..<measuredChannels).map { _ in
      eqBandCentersHz.map { BandpassFilter(centerHz: $0, sampleRate: sampleRate) }
    }
    let windowFrames = Int(mmWindowSeconds * sampleRate)
    let hopFrames = Int(mmHopSeconds * sampleRate)

    struct WindowAccumulator {
      var startFrame: Int
      var bandSums: [[Double]]
      var rawSums: [Double]
      var frames: Int
    }
    func zeroBandSums() -> [[Double]] {
      [[Double]](repeating: [Double](repeating: 0, count: bandCount), count: measuredChannels)
    }

    // Raw (unsmoothed) per-window gains, in window order.
    var rawWindows: [(timeSeconds: Double, gainsDb: [Double])] = []
    var findings: [MixMasterFindingRecord] = []

    func flushWindow(_ acc: WindowAccumulator) {
      let timeSeconds = Double(acc.startFrame) / sampleRate
      guard acc.frames > 0 else { return }
      // Broadband level: a near-silent window takes no cuts.
      let broadbandEnergy =
        acc.rawSums.reduce(0, +) / Double(measuredChannels) / Double(acc.frames)
      guard broadbandEnergy > 0 else {
        rawWindows.append((timeSeconds, [Double](repeating: 0, count: bandCount)))
        return
      }
      let broadbandDb = 10.0 * log10(broadbandEnergy)
      guard broadbandDb >= eqSilenceDbfs else {
        rawWindows.append((timeSeconds, [Double](repeating: 0, count: bandCount)))
        return
      }
      var bandLevels = [Double](repeating: -120, count: bandCount)
      for band in 0..<bandCount where measurable[band] {
        var energy = 0.0
        for channel in 0..<measuredChannels {
          energy += acc.bandSums[channel][band]
        }
        energy /= Double(measuredChannels) * Double(acc.frames)
        if energy > 0 {
          bandLevels[band] = 10.0 * log10(energy)
        }
      }
      let flooredLevels = bandLevels.map { max($0, -80) }
      let referenceDb = flooredLevels.reduce(0, +) / Double(bandCount)
      // Raw cuts: harsh + mud bands only, excess over the threshold.
      var rawCuts = [Double](repeating: 0, count: bandCount)
      for band in 0..<bandCount where measurable[band] {
        guard eqHarshBandIndices.contains(band) || mmMudBandIndices.contains(band) else {
          continue
        }
        let excess = bandLevels[band] - referenceDb - eqExcessThresholdDb
        rawCuts[band] = min(eqMaxCutDb, max(0, excess))
      }
      // Smooth: every band also takes half of its strongest
      // neighbour's raw cut (same shoulder as Auto EQ).
      var gainsDb = [Double](repeating: 0, count: bandCount)
      for band in 0..<bandCount {
        var cut = rawCuts[band]
        if band > 0 { cut = max(cut, rawCuts[band - 1] / 2) }
        if band < bandCount - 1 { cut = max(cut, rawCuts[band + 1] / 2) }
        gainsDb[band] = -min(eqMaxCutDb, cut)
      }
      // Findings report DIRECT cuts only (shouldered bands are the
      // neighbour's doing, not this band's own excess).
      for band in 0..<bandCount where rawCuts[band] >= mmFindingMinCutDb {
        findings.append(MixMasterFindingRecord(
          timeSeconds: timeSeconds,
          bandHz: eqBandCentersHz[band],
          cutDb: rawCuts[band],
          reason: mmMudBandIndices.contains(band) ? "mud" : "harshness"
        ))
      }
      rawWindows.append((timeSeconds, gainsDb))
    }

    // Whole-song accumulators for the Master EQ (Stage 2): the
    // same filtered values, summed over the entire decode, so the
    // master stage measures the full song in the same pass.
    var wholeBandSums = zeroBandSums()
    var wholeRawSums = [Double](repeating: 0, count: measuredChannels)
    var wholeFrames = 0

    var active: [WindowAccumulator] = [
      WindowAccumulator(startFrame: 0, bandSums: zeroBandSums(), rawSums: [Double](repeating: 0, count: measuredChannels), frames: 0)
    ]
    var nextWindowStart = hopFrames
    var frameIndex = 0

    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let byteLength = CMBlockBufferGetDataLength(blockBuffer)
      let floatCount = byteLength / 4
      guard floatCount >= streamChannels else { continue }
      var floats = [Float](repeating: 0, count: floatCount)
      let copyStatus = floats.withUnsafeMutableBytes { pointer -> OSStatus in
        guard let baseAddress = pointer.baseAddress else { return OSStatus(-1) }
        return CMBlockBufferCopyDataBytes(
          blockBuffer,
          atOffset: 0,
          dataLength: floatCount * 4,
          destination: baseAddress
        )
      }
      guard copyStatus == noErr else { return nil }
      let frames = floatCount / streamChannels
      for frame in 0..<frames {
        // A new window starts every hop (50% overlap with the one
        // before it); the previous windows stay live until full.
        if frameIndex == nextWindowStart {
          active.append(WindowAccumulator(
            startFrame: frameIndex,
            bandSums: zeroBandSums(),
            rawSums: [Double](repeating: 0, count: measuredChannels),
            frames: 0
          ))
          nextWindowStart += hopFrames
        }
        let base = frame * streamChannels
        for channel in 0..<measuredChannels {
          let sample = Double(floats[base + channel])
          var filtered = [Double](repeating: 0, count: bandCount)
          for band in 0..<bandCount where measurable[band] {
            filtered[band] = filters[channel][band].process(sample)
          }
          for w in active.indices {
            active[w].rawSums[channel] += sample * sample
            for band in 0..<bandCount where measurable[band] {
              let f = filtered[band]
              active[w].bandSums[channel][band] += f * f
            }
          }
          // Whole-song accumulators (Master EQ): same values,
          // summed over the entire decode.
          wholeRawSums[channel] += sample * sample
          for band in 0..<bandCount where measurable[band] {
            let f = filtered[band]
            wholeBandSums[channel][band] += f * f
          }
        }
        for w in active.indices {
          active[w].frames += 1
        }
        wholeFrames += 1
        frameIndex += 1
        while let first = active.first, frameIndex >= first.startFrame + windowFrames {
          flushWindow(first)
          active.removeFirst()
        }
      }
    }
    if reader.status == .failed {
      return nil
    }
    // Flush whatever windows are still open (the tail of the song).
    for acc in active {
      flushWindow(acc)
    }
    guard !rawWindows.isEmpty else { return nil }

    let durationSeconds = Double(frameIndex) / sampleRate
    // Trailing rule (mirrors mixMasterWindowStarts): drop a final
    // window holding < 0.25 s of audio, unless it is the only one.
    if rawWindows.count > 1,
       let last = rawWindows.last,
       durationSeconds - last.timeSeconds < mmMinWindowSeconds {
      rawWindows.removeLast()
    }
    // Findings belong to the windows that survived; keep the
    // deepest cuts, time-ordered.
    if let lastTime = rawWindows.last?.timeSeconds {
      findings.removeAll { $0.timeSeconds > lastTime }
    }
    // Findings report the cuts that will actually be rendered:
    // scale them by the corrective stage's intensity (and drop
    // them entirely when the stage is off), so the "what changed
    // and why" list never claims a cut that never happened.
    let correctiveFactor = settings.correctiveEnabled
      ? settings.correctiveIntensity / 100 : 0
    findings = findings
      .map { finding in
        var scaled = finding
        scaled.cutDb *= correctiveFactor
        return scaled
      }
      .filter { $0.cutDb >= mmFindingMinCutDb }
    findings.sort { $0.cutDb > $1.cutDb }
    if findings.count > mmMaxFindings {
      findings = Array(findings.prefix(mmMaxFindings))
    }
    findings.sort { $0.timeSeconds < $1.timeSeconds }

    let smoothed = smoothMmGains(rawWindows.map { $0.gainsDb })
    // The stored windows are the APPLIED gains: smoothed, then
    // scaled by the corrective stage's intensity (0 when off), so
    // the profile and the render always agree.
    let windows = zip(rawWindows, smoothed).map {
      MixMasterWindowRecord(
        timeSeconds: $0.0.timeSeconds,
        gainsDb: $0.1.map { $0 * correctiveFactor }
      )
    }
    // Master EQ (Stage 2): the whole-song balance vs the target
    // curve, measured on the CORRECTED levels — the raw overall
    // level plus the mean applied corrective gain per band.
    let meanCorrective = mmMeanGains(windows)
    var overallLevelsDb = [Double](repeating: -120, count: bandCount)
    var wholeBroadbandDb = -120.0
    if wholeFrames > 0 {
      let wholeBroadbandEnergy =
        wholeRawSums.reduce(0, +) / Double(measuredChannels) / Double(wholeFrames)
      if wholeBroadbandEnergy > 0 {
        wholeBroadbandDb = 10.0 * log10(wholeBroadbandEnergy)
      }
      for band in 0..<bandCount where measurable[band] {
        var energy = 0.0
        for channel in 0..<measuredChannels {
          energy += wholeBandSums[channel][band]
        }
        energy /= Double(measuredChannels) * Double(wholeFrames)
        if energy > 0 {
          overallLevelsDb[band] = 10.0 * log10(energy)
        }
      }
    }
    let masterFactor = settings.masterEnabled ? settings.masterIntensity / 100 : 0
    let masterGainsDb = mmMasterGains(
      overallLevelsDb: overallLevelsDb,
      meanCorrectiveGainsDb: meanCorrective,
      broadbandDbfs: wholeBroadbandDb
    ).map { $0 * masterFactor }
    return (
      windows: windows,
      findings: findings,
      masterGainsDb: masterGainsDb,
      sampleRate: sampleRate,
      durationSeconds: durationSeconds
    )
  }

  /// Renders the full song through TWO AVAudioUnitEQs in offline
  /// manual-rendering mode — [dynamic corrective EQ] → [static
  /// Master EQ] — with the corrective band gains driven by the
  /// smoothed curve: before each 4096-frame block the engine sets
  /// every band's gain from the curve at that block's timestamp
  /// (linear interpolation between analysis points). The master
  /// gains are static, set once at setup. Both units stay attached
  /// for the whole render, so their filter state is continuous and
  /// the corrective gains move at most the slew limit between
  /// blocks — no clicks, no per-second switching. Bands are never
  /// bypassed (a band at 0 dB at the song's start may cut later in
  /// the song; a 0 dB band is sonically inert anyway). Otherwise
  /// the same contract as renderEqSong: Float32 WAV, EXACT source
  /// frame count, temp file moved into place only when complete.
  /// False on any failure; the caller falls back to the original song.
  private static func renderMixMasterSong(
    sourceURL: URL,
    windows: [MixMasterWindowRecord],
    masterGainsDb: [Double],
    outputURL: URL
  ) -> Bool {
    let tempURL = outputURL.deletingPathExtension()
      .appendingPathExtension("tmp-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    guard masterGainsDb.count == eqBandCentersHz.count else { return false }
    do {
      let sourceFile = try AVAudioFile(forReading: sourceURL)
      let format = sourceFile.processingFormat
      let totalFrames = sourceFile.length
      guard totalFrames > 0, format.sampleRate > 0, format.channelCount > 0 else {
        return false
      }

      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      let eq = AVAudioUnitEQ(numberOfBands: eqBandCentersHz.count)
      let masterEq = AVAudioUnitEQ(numberOfBands: eqBandCentersHz.count)
      engine.attach(player)
      engine.attach(eq)
      engine.attach(masterEq)
      engine.connect(player, to: eq, format: format)
      engine.connect(eq, to: masterEq, format: format)
      engine.connect(masterEq, to: engine.mainMixerNode, format: format)
      let initialGains = mmGainAtTime(windows: windows, timeSeconds: 0)
      for (index, band) in eq.bands.enumerated() {
        band.filterType = .parametric
        // Clamp under Nyquist for very low sample rates; the
        // analysis already measured nothing up there in that case.
        band.frequency = Float(min(eqBandCentersHz[index], format.sampleRate * 0.45))
        band.bandwidth = 1.0  // octaves — matches the analysis width
        band.gain = Float(initialGains[index])
        band.bypass = false
      }
      eq.globalGain = 0  // cuts only — no makeup boost, ever
      // Master EQ (Stage 2): static gains, set once — the whole
      // song's balance against the target curve. Same band setup
      // as the corrective unit; a 0 dB band is inert, so the unit
      // stays in the chain even when the stage is off.
      for (index, band) in masterEq.bands.enumerated() {
        band.filterType = .parametric
        band.frequency = Float(min(eqBandCentersHz[index], format.sampleRate * 0.45))
        band.bandwidth = 1.0
        band.gain = Float(masterGainsDb[index])
        band.bypass = false
      }
      masterEq.globalGain = 0

      let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: !format.isInterleaved,
      ]
      let outputFile = try AVAudioFile(
        forWriting: tempURL,
        settings: outputSettings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
      )

      try engine.enableManualRenderingMode(
        .offline,
        format: format,
        maximumFrameCount: 4096
      )
      player.scheduleFile(sourceFile, at: nil)
      try engine.start()
      player.play()

      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: engine.manualRenderingFormat,
          frameCapacity: 4096
        )
      else {
        engine.stop()
        return false
      }
      var written: AVAudioFramePosition = 0
      var stalledRenders = 0
      while written < totalFrames {
        // Drive the EQ from the smoothed curve at this block's song
        // position — before the render, so the block is processed
        // with the gains for its own timestamp.
        let gains = mmGainAtTime(
          windows: windows,
          timeSeconds: Double(written) / format.sampleRate
        )
        for (index, band) in eq.bands.enumerated() {
          band.gain = Float(gains[index])
        }
        let framesToRender = AVAudioFrameCount(
          min(4096, AVAudioFramePosition(totalFrames - written))
        )
        let status = try engine.renderOffline(framesToRender, to: buffer)
        switch status {
        case .success, .insufficientDataFromInputNode:
          if buffer.frameLength > 0 {
            try outputFile.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
            stalledRenders = 0
          } else {
            stalledRenders += 1
            if stalledRenders > 8 { engine.stop(); return false }
          }
        case .cannotDoInCurrentContext:
          // Transient by contract, but never spin forever on it.
          stalledRenders += 1
          if stalledRenders > 64 { engine.stop(); return false }
        case .error:
          engine.stop()
          return false
        @unknown default:
          engine.stop()
          return false
        }
      }
      engine.stop()
      guard written == totalFrames else { return false }
      try FileManager.default.moveItem(at: tempURL, to: outputURL)
      return true
    } catch {
      return false
    }
  }

  // MARK: Look (CI grade on the composed frames)

  private static func lookIsIdentity(_ look: LookParamsRecord) -> Bool {
    abs(look.brightness) < 0.001
      && abs(look.contrast - 1) < 0.001
      && abs(look.saturation - 1) < 0.001
      && abs(look.exposureEV) < 0.001
      && abs(look.temperature) < 0.01
      && abs(look.vibrance) < 0.001
      && abs(look.sharpen) < 0.001
      && abs(look.vignette) < 0.001
  }

  /// The filter chain for one composed frame, built per request
  /// (CIFilter instances are not shared across the compositor's
  /// concurrent calls). Stages at identity values are skipped, in
  /// the fixed order: exposure → temperature → colour controls →
  /// vibrance → sharpen → vignette. Applied by
  /// LookVideoCompositor in both grade homes — preview
  /// compositions and the render transcode's single-instruction
  /// composition — internal rather than private so the compositor
  /// class can reach it.
  static func gradedImage(_ source: CIImage, look: LookParamsRecord) -> CIImage {
    var image = source
    func apply(_ name: String, _ parameters: [String: Any]) {
      guard let filter = CIFilter(name: name) else { return }
      filter.setValue(image, forKey: kCIInputImageKey)
      for (key, value) in parameters {
        filter.setValue(value, forKey: key)
      }
      if let output = filter.outputImage {
        image = output
      }
    }
    if abs(look.exposureEV) > 0.001 {
      apply("CIExposureAdjust", [kCIInputEVKey: look.exposureEV])
    }
    if abs(look.temperature) > 0.01 {
      // Positive warmth: the scene's assumed neutral sits ABOVE
      // 6500K, so converting down to a 6500 target warms the frame.
      // 40K per warmth unit maps the ±30 range onto ±1200K.
      let neutral = CIVector(x: CGFloat(6500 + look.temperature * 40), y: 0)
      apply("CITemperatureAndTint", [
        "inputNeutral": neutral,
        "inputTargetNeutral": CIVector(x: 6500, y: 0),
      ])
    }
    if abs(look.brightness) > 0.001 || abs(look.contrast - 1) > 0.001
      || abs(look.saturation - 1) > 0.001
    {
      apply("CIColorControls", [
        kCIInputBrightnessKey: look.brightness,
        kCIInputContrastKey: look.contrast,
        kCIInputSaturationKey: look.saturation,
      ])
    }
    if abs(look.vibrance) > 0.001 {
      apply("CIVibrance", ["inputAmount": look.vibrance])
    }
    if look.sharpen > 0.001 {
      apply("CISharpenLuminance", [kCIInputSharpnessKey: look.sharpen])
    }
    if look.vignette > 0.001 {
      let radius = max(source.extent.width, source.extent.height) * 0.75
      apply("CIVignette", ["inputIntensity": look.vignette, "inputRadius": radius])
    }
    // Filters can grow the extent (vignette especially); the
    // compositor wants the frame it asked for.
    return image.cropped(to: source.extent)
  }

  // MARK: Export

  /// Runs ONE export session for a built composition with no
  /// progress reporting — the audio-repair ladder's runner (the
  /// first render keeps render()'s own progress-wired session).
  /// Creation and videoComposition assignment are validate-and-
  /// throw territory, guarded like every other session here.
  private static func runRepairSession(built: BuiltComposition, outputURL: URL) async throws {
    var createdExporter: AVAssetExportSession?
    let exporterException = avTry {
      guard
        let session = AVAssetExportSession(
          asset: built.composition,
          presetName: AVAssetExportPresetHighestQuality
        )
      else {
        return
      }
      session.outputURL = outputURL
      session.outputFileType = .mp4
      session.shouldOptimizeForNetworkUse = false
      session.videoComposition = built.videoComposition
      if let audioMix = built.audioMix {
        session.audioMix = audioMix
      }
      createdExporter = session
    }
    if let exporterException {
      throw exceptionError("The export session rejected the composition", exporterException)
    }
    guard let exporter = createdExporter else {
      throw compositorError("Could not create the export session.")
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      exporter.exportAsynchronously {
        switch exporter.status {
        case .completed:
          continuation.resume()
        case .failed, .cancelled:
          continuation.resume(
            throwing: exporter.error
              ?? compositorError(
                exporter.status == .cancelled ? "The export was cancelled." : "The video export failed."
              )
          )
        default:
          continuation.resume(throwing: compositorError("The video export ended unexpectedly."))
        }
      }
    }
  }

  static func render(
    _ request: CompositeRequestRecord,
    onProgress: ((Double) -> Void)? = nil
  ) async throws -> CompositeResultRecord {
    let built = try await buildComposition(request, forExport: true)

    guard
      let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else {
      throw compositorError("Could not locate the caches directory.")
    }
    let outputURL = cachesDirectory.appendingPathComponent("mvmt-export-\(UUID().uuidString).mp4")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }

    // Guarded: creating the session and assigning its
    // videoComposition validate the built composition, and
    // AVFoundation raises an NSException (not an error) for some
    // invalid ones. A caught exception takes the ordinary
    // export-failure path — throw, like every other failure here.
    var createdExporter: AVAssetExportSession?
    let exporterException = avTry {
      guard
        let session = AVAssetExportSession(
          asset: built.composition,
          presetName: AVAssetExportPresetHighestQuality
        )
      else {
        return
      }
      session.outputURL = outputURL
      session.outputFileType = .mp4
      session.shouldOptimizeForNetworkUse = false
      session.videoComposition = built.videoComposition
      if let audioMix = built.audioMix {
        session.audioMix = audioMix
      }
      createdExporter = session
    }
    if let exporterException {
      throw exceptionError("The export session rejected the composition", exporterException)
    }
    guard let exporter = createdExporter else {
      throw compositorError("Could not create the export session.")
    }

    // Register for cancellation + progress when the caller gave an id.
    let exportId = request.exportId
    if let exportId {
      ExportSessionStore.shared.register(exportId, session: exporter)
    }
    defer {
      if let exportId {
        ExportSessionStore.shared.unregister(exportId)
      }
    }

    // When a post-render transcode will follow (size control and/or
    // a pending export grade — see below), the export session owns
    // only the first 80% of the progress bar — the transcode
    // reports the rest, so the bar never sits at 100% mid-work.
    let pendingGrade = built.pendingGrade
    let pendingExtraStyleSceneHandle = built.pendingExtraStyleSceneHandle
    let transcodePlanned =
      request.exportVideoBitrate != nil || request.exportTargetSizeMB != nil || pendingGrade != nil
      || pendingExtraStyleSceneHandle != nil
    let progressCeiling = transcodePlanned ? 0.8 : 1.0

    let progressTask: Task<Void, Never>? = (exportId != nil && onProgress != nil)
      ? Task {
          while !Task.isCancelled {
            let status = exporter.status
            if status != .waiting && status != .exporting {
              break
            }
            onProgress?(Double(exporter.progress) * progressCeiling)
            try? await Task.sleep(nanoseconds: 100_000_000)
          }
        }
      : nil

    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        exporter.exportAsynchronously {
          switch exporter.status {
          case .completed:
            continuation.resume()
          case .failed, .cancelled:
            continuation.resume(
              throwing: exporter.error
                ?? compositorError(
                  exporter.status == .cancelled ? "The export was cancelled." : "The video export failed."
                )
            )
          default:
            continuation.resume(throwing: compositorError("The video export ended unexpectedly."))
          }
        }
      }
    } catch {
      progressTask?.cancel()
      throw error
    }
    progressTask?.cancel()
    if exportId != nil {
      onProgress?(progressCeiling)
    }

    // MEASURE the written file — the result reports the rendered asset's
    // real duration and display size, never the requested values.
    let outputAsset = AVURLAsset(url: outputURL)
    let measuredDuration = try await outputAsset.load(.duration)
    let outputVideoTracks = try await outputAsset.loadTracks(withMediaType: .video)
    guard let outputVideoTrack = outputVideoTracks.first else {
      throw compositorError("The exported file has no video track.")
    }
    let outputNaturalSize = try await outputVideoTrack.load(.naturalSize)
    let outputTransform = try await outputVideoTrack.load(.preferredTransform)
    var outputDisplay = outputNaturalSize.applying(outputTransform)
    let measuredSeconds = CMTimeGetSeconds(measuredDuration)
    var renderSeconds = measuredSeconds.isFinite ? measuredSeconds : 0

    // ---- Audio health check + repair ladder ----
    // Device evidence (Jaizon, 2026-11-11): a master can come out
    // of the export session with a full-length video track and an
    // audio track truncated to a few seconds (measured: 2.4s of
    // audio inside a 42s file, on the imported-video project —
    // while other projects render whole). The session reports
    // .completed either way, so the render must CHECK ITS OWN
    // WORK: probe the master's audio track, and when it is short,
    // re-render through progressively plainer builds — first
    // without the animation tool, then also without the audio
    // mix — keeping the first whole result (else the longest).
    // A repaired master carries no burned overlays; the
    // post-render pass below burns them in instead
    // (overlaysPending), so a repair never costs the lyrics or
    // the watermark — and a healthy first render is untouched.
    var overlaysPending = false
    var acceptedGainDb = built.appliedGainDb
    let audioExpected = !(request.audioUri ?? "").isEmpty && request.audioVolume > 0
    if audioExpected, renderSeconds > 0 {
      let masterAudio = await trackDurationSeconds(outputURL, mediaType: .audio)
      if masterAudio == nil || masterAudio! < renderSeconds * 0.85 {
        var bestURL: URL? = nil
        var bestAudio = masterAudio ?? 0
        var bestGainDb: Double? = acceptedGainDb
        // (includeAnimationTool, includeAudioMix) — plainest last.
        for (withTool, withMix) in [(false, true), (false, false)] {
          let repairURL = cachesDirectory.appendingPathComponent(
            "mvmt-export-repair-\(UUID().uuidString).mp4"
          )
          do {
            let repairBuilt = try await buildComposition(
              request, forExport: true,
              includeAnimationTool: withTool, includeAudioMix: withMix
            )
            try await runRepairSession(built: repairBuilt, outputURL: repairURL)
            let repairAudio = await trackDurationSeconds(repairURL, mediaType: .audio) ?? 0
            if repairAudio > bestAudio {
              if let stale = bestURL {
                try? FileManager.default.removeItem(at: stale)
              }
              bestURL = repairURL
              bestAudio = repairAudio
              bestGainDb = withMix ? repairBuilt.appliedGainDb : nil
            } else {
              try? FileManager.default.removeItem(at: repairURL)
            }
            if repairAudio >= renderSeconds * 0.85 {
              break
            }
          } catch {
            try? FileManager.default.removeItem(at: repairURL)
            continue
          }
        }
        if let bestURL {
          try? FileManager.default.removeItem(at: outputURL)
          try? FileManager.default.moveItem(at: bestURL, to: outputURL)
          acceptedGainDb = bestGainDb
          overlaysPending = true
          if let remeasured = await measureRenderedFile(outputURL) {
            renderSeconds = remeasured.seconds
            outputDisplay = remeasured.display
          }
        }
      }
    }

    // ---- Post-render pass (render-only): transcode the finished
    // file at an explicit video bitrate (see transcodeVideoFile),
    // for size control and/or to apply the export grade the builder
    // carried out as pendingGrade (the factory filter composition
    // is banned — the grade cannot ride the export composition
    // itself; see the RULE in buildComposition).
    // The composition is untouched — the preview built from this
    // same request stays truthful, only the file's encoding (and,
    // with a grade, its pixels) changes. ANY failure delivers the
    // original render: this pass must never fail an export — a
    // failed graded pass delivers the render UNGRADED rather than
    // nothing.
    var finalURL = outputURL
    var appliedBitrate: Int? = nil
    var targetBitrate: Int? = nil
    let transcodeCanvasSize = CGSize(
      width: request.canvasWidth ?? Int(abs(outputDisplay.width).rounded()),
      height: request.canvasHeight ?? Int(abs(outputDisplay.height).rounded())
    )
    let transcodeFrameRate = request.frameRate ?? 30
    var transcodeCodec = request.exportCodec ?? "h264"
    if let targetMB = request.exportTargetSizeMB, targetMB > 0 {
      targetBitrate = videoBitrate(forTargetSizeMB: targetMB, durationSeconds: renderSeconds)
    } else if let fixed = request.exportVideoBitrate, fixed > 0 {
      targetBitrate = Int(fixed)
    } else if pendingGrade != nil || pendingExtraStyleSceneHandle != nil {
      // Grade/scene-only pass: no size fields were set, so the rate
      // is chosen for transparency — 0.22 bits per pixel-frame
      // clamped to 16–50 Mbps, one generation down from a
      // HighestQuality master, at the render's own canvas/frame
      // rate, H.264.
      let pixels = Double(transcodeCanvasSize.width) * Double(transcodeCanvasSize.height)
      targetBitrate = min(50_000_000, max(16_000_000, Int(pixels * transcodeFrameRate * 0.22)))
      transcodeCodec = "h264"
    }
    // A repaired master carries no burned overlays — burn them in
    // during the post-render pass, forcing a transparent pass when
    // no size/grade work was planned (the tool then rides the
    // pass's single-instruction composition, the same seat the
    // export grade uses).
    var burnTool: AVVideoCompositionCoreAnimationTool? = nil
    if overlaysPending {
      burnTool = makeAnimationTool(
        request: request,
        renderSize: CGSize(width: abs(outputDisplay.width), height: abs(outputDisplay.height)),
        durationSeconds: renderSeconds
      )
      if targetBitrate == nil {
        let pixels = Double(transcodeCanvasSize.width) * Double(transcodeCanvasSize.height)
        targetBitrate = min(50_000_000, max(16_000_000, Int(pixels * transcodeFrameRate * 0.22)))
        transcodeCodec = "h264"
      }
    }
    if let targetBitrate {
      let canvasSize = transcodeCanvasSize
      let codec = transcodeCodec
      let transcodeProgress: ((Double) -> Void)? =
        (exportId != nil && onProgress != nil)
        ? { fraction in onProgress?(0.8 + 0.2 * fraction) }
        : nil
      // A master whose animation tool carried lyric layers is a
      // sound final file but corrupts in the reader/writer pass
      // below (see flattenRenderedFile) — stage it through a bare
      // session render first and transcode THAT. A flatten failure
      // falls back to transcoding the original render, as before.
      var transcodeSourceURL = outputURL
      var flattenedURL: URL? = nil
      if !overlaysPending, let lyrics = request.lyrics, !lyrics.lines.isEmpty,
        let flattened = await flattenRenderedFile(sourceURL: outputURL)
      {
        flattenedURL = flattened
        transcodeSourceURL = flattened
      }
      var delivered = await transcodeVideoFile(
        sourceURL: transcodeSourceURL,
        videoBitrateBps: targetBitrate,
        codec: codec,
        canvasSize: canvasSize,
        frameRate: transcodeFrameRate,
        grade: pendingGrade,
        animationTool: burnTool,
        sceneHandle: pendingExtraStyleSceneHandle,
        onProgress: transcodeProgress
      )
      var usedBitrate = targetBitrate
      // ONE corrective pass when a target was missed by >3%: rerun
      // from the ORIGINAL render (not the first transcode — no
      // double-generation loss) at the proportionally reduced rate.
      if let first = delivered, let targetMB = request.exportTargetSizeMB, targetMB > 0,
        let firstSize = fileSizeBytes(first)
      {
        let targetBytes = targetMB * 1_000_000
        if Double(firstSize) > targetBytes * 1.03, targetBitrate > transcodeMinVideoBitrate {
          let corrected = max(
            transcodeMinVideoBitrate,
            Int(Double(targetBitrate) * targetBytes / Double(firstSize))
          )
          if corrected < targetBitrate,
            let second = await transcodeVideoFile(
              sourceURL: transcodeSourceURL,
              videoBitrateBps: corrected,
              codec: codec,
              canvasSize: canvasSize,
              frameRate: transcodeFrameRate,
              grade: pendingGrade,
              animationTool: burnTool,
              sceneHandle: pendingExtraStyleSceneHandle,
              onProgress: transcodeProgress
            )
          {
            try? FileManager.default.removeItem(at: first)
            delivered = second
            usedBitrate = corrected
          }
        }
      }
      // Duration guard: a transcode that comes back drastically
      // shorter than the render carries the corruption signature
      // this whole staging dance exists to avoid — never deliver
      // it. The flattened file (full length, vanilla structure)
      // takes its place; without one, the original render stands.
      var accepted = delivered
      if let candidate = accepted,
        let candidateSeconds = await mediaDurationSeconds(candidate),
        renderSeconds > 0, candidateSeconds < renderSeconds * 0.85
      {
        try? FileManager.default.removeItem(at: candidate)
        accepted = nil
        if let flattenedURL {
          try? FileManager.default.removeItem(at: outputURL)
          finalURL = flattenedURL
        }
      }
      // Audio guard: the container check above follows the LONGEST
      // track, so a candidate whose audio was truncated behind a
      // full-length video would pass it. Compare audio tracks
      // directly; a short-audio candidate is rejected for the
      // master (or its flattened staging) exactly like a short
      // container.
      if let candidate = accepted,
        let referenceAudio = await trackDurationSeconds(flattenedURL ?? outputURL, mediaType: .audio),
        let candidateAudio = await trackDurationSeconds(candidate, mediaType: .audio),
        referenceAudio > 0, candidateAudio < referenceAudio * 0.85
      {
        try? FileManager.default.removeItem(at: candidate)
        accepted = nil
        if let flattenedURL {
          try? FileManager.default.removeItem(at: outputURL)
          finalURL = flattenedURL
        }
      }
      if let accepted {
        // The transcoded file supersedes the original render.
        try? FileManager.default.removeItem(at: outputURL)
        finalURL = accepted
        appliedBitrate = usedBitrate
      }
      // The flattened staging file is an intermediate — it never
      // survives as the delivered file.
      if let flattenedURL, flattenedURL != finalURL {
        try? FileManager.default.removeItem(at: flattenedURL)
      }
      if exportId != nil {
        onProgress?(1.0)
      }
    }

    // Re-measure when the delivered file is the transcoded one.
    var resultDuration = renderSeconds
    var resultWidth = Int(abs(outputDisplay.width).rounded())
    var resultHeight = Int(abs(outputDisplay.height).rounded())
    if finalURL != outputURL {
      let finalAsset = AVURLAsset(url: finalURL)
      if let finalDuration = try? await finalAsset.load(.duration) {
        let seconds = CMTimeGetSeconds(finalDuration)
        if seconds.isFinite {
          resultDuration = seconds
        }
      }
      if let finalTrack = (try? await finalAsset.loadTracks(withMediaType: .video))?.first,
        let finalNaturalSize = try? await finalTrack.load(.naturalSize),
        let finalTransform = try? await finalTrack.load(.preferredTransform)
      {
        let display = finalNaturalSize.applying(finalTransform)
        resultWidth = Int(abs(display.width).rounded())
        resultHeight = Int(abs(display.height).rounded())
      }
    }

    let result = CompositeResultRecord()
    result.uri = finalURL.absoluteString
    result.durationSeconds = resultDuration
    result.width = resultWidth
    result.height = resultHeight
    result.fileSizeBytes = fileSizeBytes(finalURL) ?? 0
    result.appliedVideoBitrate = appliedBitrate
    result.appliedGainDb = acceptedGainDb
    return result
  }

  // MARK: Export size control (post-render transcode)

  /// Audio allowance inside a target file size, and the bitrate the
  /// transcode re-encodes audio at when passthrough is impossible.
  private static let transcodeAudioBitrateBps = 192_000

  /// Video bitrate floor for target-size work — mirrors
  /// MIN_VIDEO_BITRATE_BPS in src/lib/exportSize.ts.
  private static let transcodeMinVideoBitrate = 800_000

  /// The video bitrate that makes a render of `durationSeconds`
  /// land at `targetMB` total — an EXACT mirror of
  /// videoBitrateForTargetSize in src/lib/exportSize.ts (where it is
  /// unit tested); keep the two in step.
  static func videoBitrate(forTargetSizeMB targetMB: Double, durationSeconds: Double) -> Int {
    guard durationSeconds > 0, targetMB > 0 else { return transcodeMinVideoBitrate }
    let raw = ((targetMB * 8_000_000) / durationSeconds - Double(transcodeAudioBitrateBps)) * 0.94
    return max(transcodeMinVideoBitrate, Int(raw))
  }

  private static func fileSizeBytes(_ url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.intValue
  }

  /// A finished file's measured duration in seconds (nil when it
  /// cannot be read) — the duration guard's yardstick.
  private static func mediaDurationSeconds(_ url: URL) async -> Double? {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return nil }
    let seconds = CMTimeGetSeconds(duration)
    return seconds.isFinite ? seconds : nil
  }

  /// One track's duration inside a finished file (nil when the
  /// track is absent or unreadable) — the audio-health probe's
  /// yardstick: a file's CONTAINER duration follows its longest
  /// track, so a truncated audio track hides behind a full-length
  /// video track unless the audio is measured on its own.
  private static func trackDurationSeconds(_ url: URL, mediaType: AVMediaType) async -> Double? {
    let asset = AVURLAsset(url: url)
    guard
      let track = (try? await asset.loadTracks(withMediaType: mediaType))?.first,
      let range = try? await track.load(.timeRange)
    else {
      return nil
    }
    let seconds = CMTimeGetSeconds(range.duration)
    return seconds.isFinite ? seconds : nil
  }

  /// A finished file's container duration + video display size
  /// (nil when unreadable) — re-measure after a repair render
  /// replaces the master file.
  private static func measureRenderedFile(_ url: URL) async -> (seconds: Double, display: CGSize)? {
    let asset = AVURLAsset(url: url)
    guard
      let duration = try? await asset.load(.duration),
      let track = (try? await asset.loadTracks(withMediaType: .video))?.first,
      let naturalSize = try? await track.load(.naturalSize),
      let transform = try? await track.load(.preferredTransform)
    else {
      return nil
    }
    let display = naturalSize.applying(transform)
    let seconds = CMTimeGetSeconds(duration)
    return (seconds.isFinite ? seconds : 0, CGSize(width: abs(display.width), height: abs(display.height)))
  }

  /// Re-renders a finished export file through a PLAIN composition
  /// — the master's own video and audio tracks inserted whole, no
  /// animation tool, no grade, no video composition — at
  /// HighestQuality, and returns the new file's URL (nil on any
  /// failure; the caller then transcodes the original render, as
  /// before).
  ///
  /// WHY (Jaizon's device triangulation, 2026-11-11): a master
  /// rendered with lyric layers in its animation tool is a sound
  /// final file — High with the look on Original delivers it
  /// untouched and it plays perfectly — but the reader/writer
  /// transcode corrupts exactly those masters: TikTok and
  /// Balanced/Small exports of styled projects came out as
  /// ~4-second still-frame files with bad audio, graded or
  /// ungraded, while watermark-only masters transcode cleanly.
  /// The export session's own machinery reads compositions built
  /// from files without trouble (every preview proves the decode
  /// path), so a styled master takes one bare session pass first:
  /// the flattened file is the vanilla structure the reader/writer
  /// pass handles everywhere else, with the overlays already
  /// burned into its pixels.
  private static func flattenRenderedFile(sourceURL: URL) async -> URL? {
    // Precise timing: the composition inserts below are only as
    // faithful as the loaded track ranges, and the approximate
    // load is exactly what lets pre-roll hide inside a track.
    let asset = AVURLAsset(
      url: sourceURL,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    guard
      let sourceVideo = (try? await asset.loadTracks(withMediaType: .video))?.first,
      let videoRange = try? await sourceVideo.load(.timeRange),
      videoRange.duration.isValid, CMTimeGetSeconds(videoRange.duration) > 0,
      let videoTransform = try? await sourceVideo.load(.preferredTransform)
    else {
      return nil
    }
    let sourceAudio = (try? await asset.loadTracks(withMediaType: .audio))?.first
    var audioRange: CMTimeRange?
    if let sourceAudio {
      audioRange = try? await sourceAudio.load(.timeRange)
    }

    let composition = AVMutableComposition()
    do {
      guard
        let videoTrack = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        return nil
      }
      try insertTimeRangeGuarded(
        into: videoTrack, videoRange, of: sourceVideo, at: .zero,
        "The rendered video could not be staged for resizing"
      )
      videoTrack.preferredTransform = videoTransform
      if let sourceAudio, let audioRange,
        CMTimeGetSeconds(audioRange.duration) > 0,
        let audioTrack = composition.addMutableTrack(
          withMediaType: .audio,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      {
        try insertTimeRangeGuarded(
          into: audioTrack, audioRange, of: sourceAudio, at: .zero,
          "The rendered audio could not be staged for resizing"
        )
      }
    } catch {
      return nil
    }

    guard
      let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else {
      return nil
    }
    let outputURL = cachesDirectory.appendingPathComponent("mvmt-export-flat-\(UUID().uuidString).mp4")
    var createdSession: AVAssetExportSession?
    let sessionException = avTry {
      guard
        let session = AVAssetExportSession(
          asset: composition,
          presetName: AVAssetExportPresetHighestQuality
        )
      else {
        return
      }
      session.outputURL = outputURL
      session.outputFileType = .mp4
      session.shouldOptimizeForNetworkUse = false
      createdSession = session
    }
    if sessionException != nil {
      return nil
    }
    guard let session = createdSession else { return nil }
    let completed: Bool = await withCheckedContinuation { continuation in
      session.exportAsynchronously {
        continuation.resume(returning: session.status == .completed)
      }
    }
    guard completed, FileManager.default.fileExists(atPath: outputURL.path) else {
      try? FileManager.default.removeItem(at: outputURL)
      return nil
    }
    return outputURL
  }

  /// Transcodes a finished render at an explicit video bitrate via
  /// AVAssetReader → AVAssetWriter. The source is a plain file
  /// (watermark/lyrics already burned in). Without a grade there is
  /// NO video composition at all: a track output vends the file's
  /// own frames and timestamps, and the writer re-encodes them at
  /// the canvas (the render's own dimensions). When `grade` is set,
  /// the reader side uses a plain single-instruction composition
  /// whose custom compositor is LookVideoCompositor — the
  /// export-side home of the look. When `sceneHandle` resolves to
  /// a prepared Extra Styles scene, the same composition carries
  /// ExtraStylesCompositor instead (the grade folded in, §6.2) —
  /// the export-side home of the scene. Audio is re-encoded to AAC
  /// 192k stereo first (a format this code fully controls), with
  /// stored-format passthrough as the fallback attempt. Returns
  /// nil on ANY failure — the caller delivers the original render.
  private static func transcodeVideoFile(
    sourceURL: URL,
    videoBitrateBps: Int,
    codec: String,
    canvasSize: CGSize,
    frameRate: Double,
    grade: LookParamsRecord? = nil,
    animationTool: AVVideoCompositionCoreAnimationTool? = nil,
    sceneHandle: String? = nil,
    onProgress: ((Double) -> Void)? = nil
  ) async -> URL? {
    let asset = AVURLAsset(url: sourceURL)
    guard
      let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first,
      let duration = try? await asset.load(.duration),
      let naturalSize = try? await videoTrack.load(.naturalSize),
      let preferredTransform = try? await videoTrack.load(.preferredTransform)
    else {
      return nil
    }
    let durationSeconds = CMTimeGetSeconds(duration)
    guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
    let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first
    var audioFormatDescription: CMFormatDescription?
    if let audioTrack {
      audioFormatDescription = (try? await audioTrack.load(.formatDescriptions))?.first
    }

    // Audio strategy order: re-encode first (deterministic LPCM →
    // AAC), passthrough second. The Bool is `passthroughAudio`.
    let attempts: [Bool] = audioTrack != nil ? [false, true] : [false]
    for passthroughAudio in attempts {
      if let url = await transcodeAttempt(
        asset: asset,
        videoTrack: videoTrack,
        audioTrack: audioTrack,
        audioFormatDescription: audioFormatDescription,
        naturalSize: naturalSize,
        preferredTransform: preferredTransform,
        durationSeconds: durationSeconds,
        videoBitrateBps: videoBitrateBps,
        codec: codec,
        canvasSize: canvasSize,
        frameRate: frameRate,
        grade: grade,
        animationTool: animationTool,
        sceneHandle: sceneHandle,
        passthroughAudio: passthroughAudio,
        onProgress: onProgress
      ) {
        return url
      }
    }
    return nil
  }

  /// One transcode attempt with a chosen audio strategy. All
  /// construction is validate-and-throw territory, so it runs
  /// inside avTry with Swift errors collected (the
  /// insertTimeRangeGuarded pattern).
  private static func transcodeAttempt(
    asset: AVAsset,
    videoTrack: AVAssetTrack,
    audioTrack: AVAssetTrack?,
    audioFormatDescription: CMFormatDescription?,
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform,
    durationSeconds: Double,
    videoBitrateBps: Int,
    codec: String,
    canvasSize: CGSize,
    frameRate: Double,
    grade: LookParamsRecord?,
    animationTool: AVVideoCompositionCoreAnimationTool?,
    sceneHandle: String? = nil,
    passthroughAudio: Bool,
    onProgress: ((Double) -> Void)?
  ) async -> URL? {
    // Install a graded attempt's params BEFORE any reader using
    // the composition below can start, and clear them when this
    // attempt exits by ANY path (setup failure, pump failure, or
    // success). The defer is registered first and only acts for a
    // graded attempt, so an ungraded attempt never disturbs a
    // preview's slot. A scene attempt installs the scene slot the
    // same way (grade folded in — the scene compositor is the one
    // reading it).
    defer {
      if grade != nil {
        LookCompositorStore.current = nil
      }
      if sceneHandle != nil {
        ExtraStyleCompositorStore.current = nil
      }
    }
    if let grade {
      LookCompositorStore.current = grade
    }
    var scene: PreparedExtraStyleScene? = nil
    if let sceneHandle, let found = ExtraStyleSceneStore.shared.get(sceneHandle) {
      scene = found
      ExtraStyleCompositorStore.current = ExtraStyleCompositorSlot(
        scene: found, look: grade)
    }

    guard
      let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else {
      return nil
    }
    let outputURL = cachesDirectory.appendingPathComponent("mvmt-export-sized-\(UUID().uuidString).mp4")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }

    var reader: AVAssetReader?
    var writer: AVAssetWriter?
    var videoOutput: AVAssetReaderOutput?
    var videoInput: AVAssetWriterInput?
    var audioOutput: AVAssetReaderTrackOutput?
    var audioInput: AVAssetWriterInput?
    var setupError: Error?
    let setupException = avTry {
      do {
        let createdReader = try AVAssetReader(asset: asset)
        let createdWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Reader-side video path. The ungraded path is deliberately
        // boring: a plain track output with NO video composition,
        // so the master file's own frames and timestamps flow
        // straight to the writer's encoder. Only a graded attempt,
        // a scene attempt, or an animation-tool attempt uses a
        // composition output, and then only a plain
        // single-instruction composition.
        let targetFrameDuration = CMTime(
          value: 1,
          timescale: CMTimeScale(max(1.0, frameRate).rounded())
        )
        let videoOutputSettings: [String: Any] = [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let createdVideoOutput: AVAssetReaderOutput
        if grade != nil || animationTool != nil || scene != nil {
          // COMPOSITION pass: one instruction over the full
          // duration, one layer carrying the aspect-fill
          // normalisation. A grade installs LookVideoCompositor
          // as the custom compositor (its params were installed
          // in LookCompositorStore at the start of this attempt);
          // a scene installs ExtraStylesCompositor instead — it
          // folds the grade in (§6.2), reading scene + grade from
          // ExtraStyleCompositorStore; an animation tool (a
          // repaired master's overlay burn-in — see render())
          // rides the same composition. The three combine freely:
          // grade the frames, composite the scene over them, then
          // the tool composites its layers over that.
          let composition = AVMutableVideoComposition()
          composition.renderSize = canvasSize
          composition.frameDuration = targetFrameDuration
          if scene != nil {
            composition.customVideoCompositorClass = ExtraStylesCompositor.self
          } else if grade != nil {
            composition.customVideoCompositorClass = LookVideoCompositor.self
          }
          if let animationTool {
            composition.animationTool = animationTool
          }
          let instruction = AVMutableVideoCompositionInstruction()
          instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
          )
          let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
          let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
          let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
          if displaySize.width > 0, displaySize.height > 0 {
            let fillScale = max(
              canvasSize.width / displaySize.width,
              canvasSize.height / displaySize.height
            )
            var transform = preferredTransform
            transform = transform.concatenating(
              CGAffineTransform(translationX: -displayRect.origin.x, y: -displayRect.origin.y)
            )
            transform = transform.concatenating(CGAffineTransform(scaleX: fillScale, y: fillScale))
            let centreX = (canvasSize.width - displaySize.width * fillScale) / 2
            let centreY = (canvasSize.height - displaySize.height * fillScale) / 2
            transform = transform.concatenating(
              CGAffineTransform(translationX: centreX, y: centreY)
            )
            layerInstruction.setTransform(transform, at: .zero)
          }
          instruction.layerInstructions = [layerInstruction]
          composition.instructions = [instruction]

          let compositionOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: videoOutputSettings
          )
          compositionOutput.videoComposition = composition
          createdVideoOutput = compositionOutput
        } else {
          // UNGRADED: no composition anywhere — the track output
          // vends the rendered file's frames untouched.
          createdVideoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: videoOutputSettings
          )
        }

        guard createdReader.canAdd(createdVideoOutput) else {
          throw compositorError("The transcode reader rejected the video output.")
        }
        createdReader.add(createdVideoOutput)

        // No AVVideoExpectedSourceFrameRateKey — the banned-key
        // discipline from the capture writer applies here too. An
        // ungraded attempt takes cadence from the source samples;
        // a graded attempt's composition carries the frameDuration.
        var compressionProperties: [String: Any] = [
          AVVideoAverageBitRateKey: videoBitrateBps,
          AVVideoMaxKeyFrameIntervalKey: 60,
        ]
        let codecType: AVVideoCodecType = codec == "hevc" ? .hevc : .h264
        if codecType == .h264 {
          compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoSettings: [String: Any] = [
          AVVideoCodecKey: codecType,
          AVVideoWidthKey: Int(canvasSize.width),
          AVVideoHeightKey: Int(canvasSize.height),
          AVVideoCompressionPropertiesKey: compressionProperties,
        ]
        let createdVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        createdVideoInput.expectsMediaDataInRealTime = false
        guard createdWriter.canAdd(createdVideoInput) else {
          throw compositorError("The transcode writer rejected the video input.")
        }
        createdWriter.add(createdVideoInput)

        if let audioTrack {
          let createdAudioOutput: AVAssetReaderTrackOutput
          let createdAudioInput: AVAssetWriterInput
          if passthroughAudio {
            // Nil settings on both sides = the samples pass through
            // in their stored (AAC) format untouched.
            createdAudioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            createdAudioInput = AVAssetWriterInput(
              mediaType: .audio,
              outputSettings: nil,
              sourceFormatHint: audioFormatDescription
            )
          } else {
            createdAudioOutput = AVAssetReaderTrackOutput(
              track: audioTrack,
              outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
              ]
            )
            createdAudioInput = AVAssetWriterInput(
              mediaType: .audio,
              outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: transcodeAudioBitrateBps,
              ]
            )
          }
          createdAudioOutput.alwaysCopiesSampleData = false
          createdAudioInput.expectsMediaDataInRealTime = false
          guard createdReader.canAdd(createdAudioOutput) else {
            throw compositorError("The transcode reader rejected the audio output.")
          }
          createdReader.add(createdAudioOutput)
          guard createdWriter.canAdd(createdAudioInput) else {
            throw compositorError("The transcode writer rejected the audio input.")
          }
          createdWriter.add(createdAudioInput)
          audioOutput = createdAudioOutput
          audioInput = createdAudioInput
        }

        reader = createdReader
        writer = createdWriter
        videoOutput = createdVideoOutput
        videoInput = createdVideoInput
      } catch {
        setupError = error
      }
    }
    guard setupException == nil, setupError == nil,
      let reader, let writer, let videoOutput, let videoInput
    else {
      return nil
    }

    guard reader.startReading(), writer.startWriting() else {
      writer.cancelWriting()
      return nil
    }
    writer.startSession(atSourceTime: .zero)

    // The classic reader/writer pump: each input pulls from its
    // output on its own serial queue until the output runs dry.
    // An input is marked finished ONLY at end-of-stream (the
    // reader returns nil) or on append failure. The previous
    // shape marked it finished the first time the while loop
    // exited — including a mere back-pressure pause
    // (isReadyForMoreMediaData == false) — so every transcode
    // "completed" after a second or two of media and render()'s
    // duration guard silently substituted the raw master: no
    // size control, no codec conversion, no grade, ever. That
    // was the root of the whole styled-export saga (the ~4s
    // TikTok stubs were this pump's output, delivered before
    // the guard existed).
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let group = DispatchGroup()
      group.enter()
      videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "au.mvmtstudio.transcode.video")) {
        while videoInput.isReadyForMoreMediaData {
          guard let buffer = videoOutput.copyNextSampleBuffer() else {
            videoInput.markAsFinished()
            group.leave()
            return
          }
          if !videoInput.append(buffer) {
            videoInput.markAsFinished()
            group.leave()
            return
          }
          let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
          let seconds = CMTimeGetSeconds(pts)
          if seconds.isFinite, durationSeconds > 0 {
            onProgress?(min(1, max(0, seconds / durationSeconds)))
          }
        }
        // Back-pressure pause: return WITHOUT finishing — the
        // input calls this handler again when it wants more.
      }
      if let audioInput, let audioOutput {
        group.enter()
        audioInput.requestMediaDataWhenReady(
          on: DispatchQueue(label: "au.mvmtstudio.transcode.audio")
        ) {
          while audioInput.isReadyForMoreMediaData {
            guard let buffer = audioOutput.copyNextSampleBuffer() else {
              audioInput.markAsFinished()
              group.leave()
              return
            }
            if !audioInput.append(buffer) {
              audioInput.markAsFinished()
              group.leave()
              return
            }
          }
        }
      }
      group.notify(queue: DispatchQueue(label: "au.mvmtstudio.transcode.done")) {
        continuation.resume()
      }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }
    guard writer.status == .completed, reader.status != .failed else {
      try? FileManager.default.removeItem(at: outputURL)
      return nil
    }
    return outputURL
  }

  // MARK: Asset inspection

  static func inspect(_ uri: String) async throws -> AssetInfoRecord {
    let asset = AVURLAsset(url: resolveURL(uri))
    let duration = try await asset.load(.duration)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)

    let info = AssetInfoRecord()
    let durationSeconds = CMTimeGetSeconds(duration)
    info.durationSeconds = durationSeconds.isFinite ? durationSeconds : 0
    info.hasVideo = !videoTracks.isEmpty
    info.hasAudio = !audioTracks.isEmpty
    info.width = 0
    info.height = 0
    info.frameRate = 0
    if let videoTrack = videoTracks.first {
      let naturalSize = try await videoTrack.load(.naturalSize)
      let preferredTransform = try await videoTrack.load(.preferredTransform)
      let display = naturalSize.applying(preferredTransform)
      info.width = Int(abs(display.width).rounded())
      info.height = Int(abs(display.height).rounded())
      let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
      info.frameRate = Double(nominalFrameRate)
      // Per-track placement on the asset timeline — the first frame is
      // NOT necessarily at t=0 (camera files carry small start offsets,
      // and video/audio tracks need not start together).
      let videoTimeRange = try await videoTrack.load(.timeRange)
      let videoStart = CMTimeGetSeconds(videoTimeRange.start)
      info.videoStartSeconds = videoStart.isFinite ? videoStart : 0
      let videoDuration = CMTimeGetSeconds(videoTimeRange.duration)
      info.videoDurationSeconds = videoDuration.isFinite ? videoDuration : 0
    }
    if let audioTrack = audioTracks.first {
      let audioTimeRange = try await audioTrack.load(.timeRange)
      let audioStart = CMTimeGetSeconds(audioTimeRange.start)
      info.audioStartSeconds = audioStart.isFinite ? audioStart : 0
      let audioDuration = CMTimeGetSeconds(audioTimeRange.duration)
      info.audioDurationSeconds = audioDuration.isFinite ? audioDuration : 0
    }
    return info
  }

  // MARK: Take sync measurement (file-based ground truth)
  //
  // A take's stored sync offset used to be a JS estimate: the audio
  // player's position sampled immediately BEFORE camera.recordAsync —
  // blind to the camera's variable spin-up (~100–400ms, different per
  // take), which is exactly the per-take lip-sync error. This measures
  // the truth FROM THE RECORDED FILE instead:
  //
  //   1. The take's per-track timeRanges give the intra-file A/V
  //      offset δ = audioStart − videoStart (where each track's first
  //      sample actually sits on the asset timeline).
  //   2. The take's mic audio captured the master song playing aloud,
  //      so cross-correlating it against the song file gives P_A0 —
  //      the song position at the take's audio-track start.
  //   3. The first video frame sits at asset time videoStart, i.e.
  //      (videoStart − audioStart) from the audio start, so the song
  //      position at the first frame is S0 = P_A0 − δ.
  //
  // Correlation runs in two stages at 8kHz mono: a coarse pass over
  // RMS envelopes (100Hz hops) spanning the whole search window, then
  // a sample-accurate raw-PCM refinement within ±120ms of the coarse
  // peak. Cost for a 3-minute take: ~7M envelope MACs (coarse) and
  // ~150M MACs (refine — 1921 lags × ~10s slice) — the dominant cost,
  // still ≲1s on device. Expected failure modes are reported in the
  // record's status, never thrown.
  //
  // IMPORTED videos search differently: the song can begin anywhere
  // in the file, so a searchWindowSeconds request beyond the ±10s
  // local clamp switches to a full-song search (the window recentres
  // on the whole song; the coarse needle is capped at the take's
  // first 60s to bound the cost). The gates are identical — a
  // full-song match must clear the same ρ and peak-ratio floors.

  /// Below this take-audio RMS the mic cannot contain the song
  /// (earbuds, silence) — reported as 'noSongInMic'.
  private static let syncSilenceRMSFloor: Double = 0.005
  /// Confidence gates: below either floor the alignment is reported
  /// ('lowConfidence') but never applied — S0 stays nil.
  private static let syncConfidenceFloor: Double = 0.45
  private static let syncPeakRatioFloor: Double = 1.8

  private static let syncSampleRate: Double = 8000
  /// Envelope resolution: 10ms hops, ~25ms RMS windows.
  private static let syncEnvelopeHopSamples = 80
  private static let syncEnvelopeWindowSamples = 200
  /// Refine searches ±120ms around the coarse peak, sample by sample.
  private static let syncRefineHalfWindowSamples = 960
  /// Full-range (import) searches cap the COARSE needle at the take's
  /// first 60s (6000 envelope steps at 100Hz): the coarse stage only
  /// has to locate the take's START within the refine window, and an
  /// uncapped needle would make its cost grow with the whole imported
  /// file's length. The refine stage still uses the loudest slice of
  /// the full take, so the cap costs no accuracy.
  private static let syncFullRangeNeedleSteps = 6000
  /// Refine correlates the loudest contiguous ~10s of the take.
  private static let syncRefineSliceSamples = 80_000
  /// Second peak must sit at least this far from the winner:
  /// 5 envelope steps = 50ms.
  private static let syncPeakExclusionEnvelopeSteps = 5

  private static func syncResult(
    status: String,
    songPositionAtFirstFrameSeconds: Double? = nil,
    intraFileAvOffsetSeconds: Double? = nil,
    confidence: Double? = nil,
    peakRatio: Double? = nil
  ) -> TakeSyncMeasurementRecord {
    let record = TakeSyncMeasurementRecord()
    record.status = status
    record.songPositionAtFirstFrameSeconds = songPositionAtFirstFrameSeconds
    record.intraFileAvOffsetSeconds = intraFileAvOffsetSeconds
    record.confidence = confidence
    record.peakRatio = peakRatio
    return record
  }

  static func measureTakeSync(
    takeUri: String,
    songUri: String,
    expectedSongPositionAtTakeStartSeconds: Double,
    searchWindowSeconds: Double
  ) async -> TakeSyncMeasurementRecord {
    // Sanitise inputs — garbage in is an 'error', not a crash.
    guard expectedSongPositionAtTakeStartSeconds.isFinite else {
      return syncResult(status: "error")
    }
    // A window request beyond the local clamp is the IMPORTED-video
    // search: the song may begin anywhere inside an imported file, so
    // the search recentres on the whole song once its duration is
    // known (step 4) instead of around the caller's estimate. Local
    // searches (recorded takes, whose start is known to within a
    // second or two) keep the ±10s clamp exactly as before.
    let fullRangeSearch = searchWindowSeconds.isFinite && searchWindowSeconds > 10
    var window: Double
    if searchWindowSeconds.isFinite {
      window = min(max(searchWindowSeconds, 0.25), 10)
    } else {
      window = 2
    }
    var expected = expectedSongPositionAtTakeStartSeconds

    do {
      // ---- 1. Track layout of the take file ----
      let takeAsset = AVURLAsset(url: resolveURL(takeUri))
      let takeVideoTracks = try await takeAsset.loadTracks(withMediaType: .video)
      let takeAudioTracks = try await takeAsset.loadTracks(withMediaType: .audio)
      guard let videoTrack = takeVideoTracks.first else {
        return syncResult(status: "error") // a take without video is not a take
      }
      guard let audioTrack = takeAudioTracks.first else {
        return syncResult(status: "noSongInMic")
      }
      let videoTimeRange = try await videoTrack.load(.timeRange)
      let audioTimeRange = try await audioTrack.load(.timeRange)
      let videoStart = CMTimeGetSeconds(videoTimeRange.start)
      let audioStart = CMTimeGetSeconds(audioTimeRange.start)
      let audioDuration = CMTimeGetSeconds(audioTimeRange.duration)
      guard videoStart.isFinite, audioStart.isFinite, audioDuration.isFinite, audioDuration > 0 else {
        return syncResult(status: "error")
      }
      let delta = audioStart - videoStart

      // ---- 2. Decode the take's mic audio (mono 8kHz PCM) ----
      // decodeStartSeconds is where sample 0 truly sits on the take's
      // asset timeline (the first returned buffer's PTS — the reader
      // may hand back samples slightly ahead of the requested range).
      let takePCM = try decodeMonoPCM(asset: takeAsset, track: audioTrack, range: audioTimeRange)
      guard takePCM.samples.count > 0 else {
        return syncResult(status: "error", intraFileAvOffsetSeconds: delta)
      }

      // ---- 3. Energy gate: did the mic hear anything at all? ----
      var takeSumSquares = 0.0
      for sample in takePCM.samples {
        takeSumSquares += Double(sample) * Double(sample)
      }
      let takeRMS = sqrt(takeSumSquares / Double(takePCM.samples.count))
      guard takeRMS >= syncSilenceRMSFloor else {
        return syncResult(status: "noSongInMic", intraFileAvOffsetSeconds: delta)
      }
      // Too little audio to correlate meaningfully — report, never apply.
      guard audioDuration >= 0.5 else {
        return syncResult(status: "lowConfidence", intraFileAvOffsetSeconds: delta)
      }

      // ---- 4. Decode the song region the search can touch ----
      let songAsset = AVURLAsset(url: resolveURL(songUri))
      let songAudioTracks = try await songAsset.loadTracks(withMediaType: .audio)
      guard let songTrack = songAudioTracks.first else {
        return syncResult(status: "error", intraFileAvOffsetSeconds: delta)
      }
      let songDuration = CMTimeGetSeconds(try await songAsset.load(.duration))
      guard songDuration.isFinite, songDuration > 0 else {
        return syncResult(status: "error", intraFileAvOffsetSeconds: delta)
      }
      if fullRangeSearch {
        // Centre the search on the whole song: every feasible
        // alignment is inside [0, songDuration], and step 4's range
        // math decodes the full song PCM below.
        expected = songDuration / 2
        window = songDuration / 2
      }
      // Candidate alignments put the take's audio start anywhere in
      // [expected − window, expected + window], and the take then runs
      // for its full duration — the decoded song range must cover all
      // of it (plus slack for the refine stage at the edges).
      let rangeStart = max(0, expected - window - 0.5)
      let rangeEnd = min(songDuration, expected + window + audioDuration + 0.5)
      guard rangeEnd > rangeStart else {
        // The expected position is nowhere near the song's contents.
        return syncResult(status: "outOfWindow", intraFileAvOffsetSeconds: delta)
      }
      let songRange = CMTimeRange(
        start: CMTime(seconds: rangeStart, preferredTimescale: 600),
        duration: CMTime(seconds: rangeEnd - rangeStart, preferredTimescale: 600)
      )
      let songPCM = try decodeMonoPCM(asset: songAsset, track: songTrack, range: songRange)
      guard songPCM.samples.count > 0 else {
        return syncResult(status: "error", intraFileAvOffsetSeconds: delta)
      }

      // ---- 5. Coarse stage: RMS-envelope correlation ----
      // Envelope index ↔ seconds is exact: hop = 80 samples at 8kHz
      // is precisely 10ms, so offset o (envelope steps) between the
      // take envelope and the song envelope maps to song position
      // songDecodeStart + o × 0.01.
      let takeEnvelope = rmsEnvelope(takePCM.samples)
      let coarseNeedle = fullRangeSearch
        ? Array(takeEnvelope.prefix(syncFullRangeNeedleSteps))
        : takeEnvelope
      let songEnvelope = rmsEnvelope(songPCM.samples)
      let hopSeconds = Double(syncEnvelopeHopSamples) / syncSampleRate
      let minOffset = Int(((expected - window - songPCM.startSeconds) / hopSeconds).rounded())
      let maxOffset = Int(((expected + window - songPCM.startSeconds) / hopSeconds).rounded())
      // Clamp to offsets that can overlap the decoded song at all —
      // a wild expected position must not turn the search into an
      // unbounded loop over empty offsets.
      let lowOffset = max(minOffset, 0)
      let highOffset = min(maxOffset, songEnvelope.count - 1)
      guard highOffset >= lowOffset else {
        return syncResult(status: "outOfWindow", intraFileAvOffsetSeconds: delta)
      }
      let curve = envelopeCorrelationCurve(
        needle: coarseNeedle,
        haystack: songEnvelope,
        offsets: lowOffset...highOffset
      )
      guard let coarseBest = curve.max(by: { $0.rho < $1.rho }), coarseBest.rho > 0 else {
        return syncResult(status: "outOfWindow", intraFileAvOffsetSeconds: delta)
      }
      let coarsePosition = songPCM.startSeconds + Double(coarseBest.offset) * hopSeconds

      // Peak uniqueness across the WHOLE search window (from the
      // coarse curve): the winner vs the best competitor at least
      // 50ms (5 envelope steps) away. A repeating beat inside the
      // window shows up here even when the local match is strong.
      var secondPeak = 0.0
      for point in curve where abs(point.offset - coarseBest.offset) >= syncPeakExclusionEnvelopeSteps {
        secondPeak = max(secondPeak, point.rho)
      }
      let peakRatio: Double
      if secondPeak <= 0 {
        peakRatio = coarseBest.rho > 0 ? 100 : 0
      } else {
        peakRatio = min(100, coarseBest.rho / secondPeak)
      }

      // ---- 6. Refine stage: raw-PCM correlation, ±120ms ----
      // The loudest contiguous ~10s slice of the take carries the most
      // alignment signal per MAC.
      let sliceLength = min(syncRefineSliceSamples, takePCM.samples.count)
      let sliceStart = loudestSliceStart(takePCM.samples, length: sliceLength)
      let slice = Array(takePCM.samples[sliceStart..<(sliceStart + sliceLength)])
      var sliceSum = 0.0
      var sliceSumSquares = 0.0
      for sample in slice {
        sliceSum += Double(sample)
        sliceSumSquares += Double(sample) * Double(sample)
      }
      let sliceMean = sliceSum / Double(sliceLength)
      let sliceVariance = sliceSumSquares - Double(sliceLength) * sliceMean * sliceMean
      guard sliceVariance > 0 else {
        return syncResult(
          status: "lowConfidence",
          intraFileAvOffsetSeconds: delta,
          confidence: 0,
          peakRatio: peakRatio
        )
      }

      // Lag ℓ = the song sample index aligning with take sample 0.
      // The coarse peak gives it directly; refine searches ±120ms.
      let coarseLag = Int(((coarsePosition - songPCM.startSeconds) * syncSampleRate).rounded())
      let lagMin = max(-sliceStart, coarseLag - syncRefineHalfWindowSamples)
      let lagMax = min(
        songPCM.samples.count - sliceStart - sliceLength,
        coarseLag + syncRefineHalfWindowSamples
      )
      guard lagMax >= lagMin else {
        return syncResult(status: "error", intraFileAvOffsetSeconds: delta)
      }

      // Prefix sums over just the song region the refine can touch,
      // so each lag's song mean/variance is O(1) and only Σxy costs
      // O(sliceLength) per lag.
      let regionStart = lagMin + sliceStart
      let regionCount = (lagMax + sliceStart + sliceLength) - regionStart
      var prefixSum = [Double](repeating: 0, count: regionCount + 1)
      var prefixSumSquares = [Double](repeating: 0, count: regionCount + 1)
      for i in 0..<regionCount {
        let value = Double(songPCM.samples[regionStart + i])
        prefixSum[i + 1] = prefixSum[i] + value
        prefixSumSquares[i + 1] = prefixSumSquares[i] + value * value
      }

      var bestLag = coarseLag
      var bestRho = -1.0
      let count = Double(sliceLength)
      for lag in lagMin...lagMax {
        let segmentStart = lag + sliceStart - regionStart
        let songSum = prefixSum[segmentStart + sliceLength] - prefixSum[segmentStart]
        let songSumSquares = prefixSumSquares[segmentStart + sliceLength] - prefixSumSquares[segmentStart]
        let songMean = songSum / count
        let songVariance = songSumSquares - count * songMean * songMean
        guard songVariance > 0 else { continue }
        var sumXY = 0.0
        let songBase = lag + sliceStart
        for j in 0..<sliceLength {
          sumXY += Double(slice[j]) * Double(songPCM.samples[songBase + j])
        }
        let numerator = sumXY - count * sliceMean * songMean
        let rho = numerator / sqrt(sliceVariance * songVariance)
        if rho > bestRho {
          bestRho = rho
          bestLag = lag
        }
      }
      guard bestRho >= 0 else {
        return syncResult(
          status: "lowConfidence",
          intraFileAvOffsetSeconds: delta,
          confidence: 0,
          peakRatio: peakRatio
        )
      }

      // Song position at take sample 0 — i.e. at asset time
      // takePCM.startSeconds — then shifted to the first VIDEO frame:
      // S0 = P_A0 + (videoStart − takeDecodeStart). In the normal case
      // takeDecodeStart == audioStart and this is exactly P_A0 − δ.
      let positionAtTakeStart = songPCM.startSeconds + Double(bestLag) / syncSampleRate
      let songPositionAtFirstFrame =
        positionAtTakeStart + (videoStart - takePCM.startSeconds)

      // ---- 7. Gates ----
      if positionAtTakeStart < expected - window || positionAtTakeStart > expected + window {
        return syncResult(
          status: "outOfWindow",
          intraFileAvOffsetSeconds: delta,
          confidence: bestRho,
          peakRatio: peakRatio
        )
      }
      if bestRho < syncConfidenceFloor || peakRatio < syncPeakRatioFloor {
        return syncResult(
          status: "lowConfidence",
          intraFileAvOffsetSeconds: delta,
          confidence: bestRho,
          peakRatio: peakRatio
        )
      }
      return syncResult(
        status: "measured",
        songPositionAtFirstFrameSeconds: songPositionAtFirstFrame,
        intraFileAvOffsetSeconds: delta,
        confidence: bestRho,
        peakRatio: peakRatio
      )
    } catch {
      return syncResult(status: "error")
    }
  }

  /// A decoded mono PCM buffer plus where its first sample sits on the
  /// source asset's timeline (the first returned buffer's PTS).
  private struct DecodedPCM {
    let samples: [Float]
    let startSeconds: Double
  }

  /// Decode one audio track to mono Float32 PCM at 8kHz via
  /// AVAssetReader (16-bit LinearPCM out, Int16 → Float conversion).
  private static func decodeMonoPCM(
    asset: AVAsset,
    track: AVAssetTrack,
    range: CMTimeRange
  ) throws -> DecodedPCM {
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = range
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: Int(syncSampleRate),
      AVNumberOfChannelsKey: 1,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw compositorError("Could not add the audio reader output for sync measurement.")
    }
    reader.add(output)
    guard reader.startReading() else {
      throw compositorError(
        "Could not start reading audio for sync measurement: \(reader.error?.localizedDescription ?? "unknown error")"
      )
    }

    var samples: [Float] = []
    let estimatedSamples = Int(CMTimeGetSeconds(range.duration) * syncSampleRate) + 1
    if estimatedSamples > 0 {
      samples.reserveCapacity(estimatedSamples)
    }
    var startSeconds = CMTimeGetSeconds(range.start)
    var sawFirstBuffer = false

    while let sampleBuffer = output.copyNextSampleBuffer() {
      if !sawFirstBuffer {
        sawFirstBuffer = true
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if pts.isFinite {
          startSeconds = pts
        }
      }
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let byteLength = CMBlockBufferGetDataLength(blockBuffer)
      let sampleCount = byteLength / 2 // 16-bit mono
      guard sampleCount > 0 else { continue }
      var int16Samples = [Int16](repeating: 0, count: sampleCount)
      let copyStatus = int16Samples.withUnsafeMutableBytes { pointer -> OSStatus in
        guard let baseAddress = pointer.baseAddress else { return OSStatus(-1) }
        return CMBlockBufferCopyDataBytes(
          blockBuffer,
          atOffset: 0,
          dataLength: sampleCount * 2,
          destination: baseAddress
        )
      }
      guard copyStatus == noErr else {
        throw compositorError("Could not copy decoded audio samples for sync measurement.")
      }
      for value in int16Samples {
        samples.append(Float(value) / 32768.0)
      }
    }
    if reader.status == .failed {
      throw compositorError(
        "Audio decoding failed during sync measurement: \(reader.error?.localizedDescription ?? "unknown error")"
      )
    }
    return DecodedPCM(samples: samples, startSeconds: startSeconds)
  }

  /// RMS envelope at 100Hz hops (80 samples at 8kHz), ~25ms windows.
  private static func rmsEnvelope(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty else { return [] }
    let count = (samples.count - 1) / syncEnvelopeHopSamples + 1
    var envelope = [Float]()
    envelope.reserveCapacity(count)
    for index in 0..<count {
      let start = index * syncEnvelopeHopSamples
      let end = min(samples.count, start + syncEnvelopeWindowSamples)
      var sumSquares = 0.0
      for j in start..<end {
        sumSquares += Double(samples[j]) * Double(samples[j])
      }
      envelope.append(Float(sqrt(sumSquares / Double(max(1, end - start)))))
    }
    return envelope
  }

  /// Zero-mean normalised cross-correlation of `needle` against
  /// `haystack` for each integer offset (needle[0] aligns with
  /// haystack[offset]). The needle is truncated at the haystack's end;
  /// offsets keeping less than 80% of the needle are skipped.
  private static func envelopeCorrelationCurve(
    needle: [Float],
    haystack: [Float],
    offsets: ClosedRange<Int>
  ) -> [(offset: Int, rho: Double)] {
    guard !needle.isEmpty, !haystack.isEmpty else { return [] }
    var curve: [(offset: Int, rho: Double)] = []
    for offset in offsets {
      let available = haystack.count - offset
      guard offset >= 0, available > 0 else { continue }
      let length = min(needle.count, available)
      guard Double(length) >= 0.8 * Double(needle.count) else { continue }
      // One pass per offset gathers both sides' stats plus Σxy — the
      // needle may be truncated at the haystack's end, so its stats
      // are computed over the same `length` samples it contributes.
      var nSum = 0.0
      var nSumSquares = 0.0
      var hSum = 0.0
      var hSumSquares = 0.0
      var sumXY = 0.0
      for j in 0..<length {
        let n = Double(needle[j])
        let h = Double(haystack[offset + j])
        nSum += n
        nSumSquares += n * n
        hSum += h
        hSumSquares += h * h
        sumXY += n * h
      }
      let count = Double(length)
      let nMean = nSum / count
      let hMean = hSum / count
      let nVariance = nSumSquares - count * nMean * nMean
      let hVariance = hSumSquares - count * hMean * hMean
      guard nVariance > 0, hVariance > 0 else { continue }
      let rho = (sumXY - count * nMean * hMean) / sqrt(nVariance * hVariance)
      if rho.isFinite {
        curve.append((offset: offset, rho: rho))
      }
    }
    return curve
  }

  /// Start index of the highest-energy contiguous `length`-sample
  /// window (evaluated at envelope-hop steps — 10ms precision is
  /// plenty for choosing WHERE to refine, never for the result).
  private static func loudestSliceStart(_ samples: [Float], length: Int) -> Int {
    guard samples.count > length, length > 0 else { return 0 }
    var windowSum = 0.0
    for j in 0..<length {
      windowSum += Double(samples[j]) * Double(samples[j])
    }
    var bestStart = 0
    var bestSum = windowSum
    var start = syncEnvelopeHopSamples
    while start + length <= samples.count {
      for j in (start - syncEnvelopeHopSamples)..<start {
        windowSum -= Double(samples[j]) * Double(samples[j])
      }
      for j in (start + length - syncEnvelopeHopSamples)..<(start + length) {
        windowSum += Double(samples[j]) * Double(samples[j])
      }
      if windowSum > bestSum {
        bestSum = windowSum
        bestStart = start
      }
      start += syncEnvelopeHopSamples
    }
    return bestStart
  }

  // MARK: Waveform peaks (real decoded peaks)
  //
  // The Record screen's track strip and the audio-region picker draw
  // the song's waveform from these peaks. Decoded with the same
  // AVAssetReader setup as the sync measurement (8kHz mono 16-bit
  // LinearPCM), but STREAMING: each sample folds into a per-bucket
  // max-abs accumulator as it arrives, so only one sample buffer plus
  // `buckets` floats are ever held — a long song is never fully
  // decoded into memory. Peaks are normalised by the global maximum
  // and floored so quiet sections still render as tiny bars.
  //
  // Every failure (no audio track, unreadable/undecodable file) returns
  // nil rather than throwing: the JS side falls back to its
  // deterministic stand-in bars.

  /// Floor for normalised peaks — quiet sections stay visible.
  private static let waveformPeakFloor: Double = 0.06
  /// Decode rate for peak extraction. Peaks are bucket maxima over
  /// ≥100ms spans at the bucket counts the UI requests, so the sync
  /// measurement's 8kHz costs nothing visually and keeps long songs
  /// fast.
  private static let waveformSampleRate: Double = 8000

  static func waveformPeaks(uri: String, buckets: Int) async -> WaveformPeaksRecord? {
    let bucketCount = min(max(buckets, 8), 1024)
    do {
      let asset = AVURLAsset(url: resolveURL(uri))
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      guard let track = audioTracks.first else { return nil }
      let timeRange = try await track.load(.timeRange)
      let duration = CMTimeGetSeconds(timeRange.duration)
      guard duration.isFinite, duration > 0 else { return nil }

      let reader = try AVAssetReader(asset: asset)
      reader.timeRange = timeRange
      let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: Int(waveformSampleRate),
        AVNumberOfChannelsKey: 1,
      ]
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { return nil }
      reader.add(output)
      guard reader.startReading() else { return nil }

      // Bucket b covers decoded samples [b × samplesPerBucket,
      // (b+1) × samplesPerBucket) — sample 0 sits at the track
      // timeRange start, so a running counter maps directly onto
      // buckets spanning the track duration.
      var maxima = [Float](repeating: 0, count: bucketCount)
      let samplesPerBucket = duration * waveformSampleRate / Double(bucketCount)
      var decodedSamples = 0
      while let sampleBuffer = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
        let byteLength = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = byteLength / 2 // 16-bit mono
        guard sampleCount > 0 else { continue }
        var int16Samples = [Int16](repeating: 0, count: sampleCount)
        let copyStatus = int16Samples.withUnsafeMutableBytes { pointer -> OSStatus in
          guard let baseAddress = pointer.baseAddress else { return OSStatus(-1) }
          return CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: sampleCount * 2,
            destination: baseAddress
          )
        }
        guard copyStatus == noErr else { return nil }
        for value in int16Samples {
          let bucket = min(bucketCount - 1, Int(Double(decodedSamples) / samplesPerBucket))
          // Convert BEFORE abs: |Int16.min| overflows in Int16.
          let magnitude = abs(Float(value) / 32768.0)
          if magnitude > maxima[bucket] {
            maxima[bucket] = magnitude
          }
          decodedSamples += 1
        }
      }
      if reader.status == .failed { return nil }
      guard decodedSamples > 0 else { return nil }

      let globalMax = maxima.max() ?? 0
      let peaks: [Double] = maxima.map { raw in
        let normalised = globalMax > 0 ? Double(raw) / Double(globalMax) : 0
        return max(waveformPeakFloor, normalised)
      }
      let record = WaveformPeaksRecord()
      record.peaks = peaks
      record.durationSeconds = duration
      return record
    } catch {
      return nil
    }
  }
}

// MARK: - Export session registry (progress + cancellation)

private final class ExportSessionStore {
  static let shared = ExportSessionStore()

  private let lock = NSLock()
  private var sessions: [String: AVAssetExportSession] = [:]

  func register(_ exportId: String, session: AVAssetExportSession) {
    lock.lock()
    sessions[exportId] = session
    lock.unlock()
  }

  func unregister(_ exportId: String) {
    lock.lock()
    sessions[exportId] = nil
    lock.unlock()
  }

  func cancel(_ exportId: String) {
    lock.lock()
    let session = sessions[exportId]
    lock.unlock()
    session?.cancelExport()
  }
}

// MARK: - Native preview (registry of AVPlayers over shared-builder compositions)

private final class PreviewEntry {
  let id: String
  let player: AVPlayer
  let item: AVPlayerItem
  let durationSeconds: Double
  var timeObserver: Any?
  var statusObservation: NSKeyValueObservation?
  var rateObservation: NSKeyValueObservation?
  var endObserver: NSObjectProtocol?
  var lastStatus: String = ""
  var didEnd = false

  init(id: String, player: AVPlayer, item: AVPlayerItem, durationSeconds: Double) {
    self.id = id
    self.player = player
    self.item = item
    self.durationSeconds = durationSeconds
  }
}

private final class WeakPreviewViewBox {
  weak var view: MvmtPreviewView?
  init(_ view: MvmtPreviewView) {
    self.view = view
  }
}

private final class PreviewStore {
  static let shared = PreviewStore()

  /// Set by the module (OnCreate) to the module's sendEvent — events
  /// must outlive any single function call, so they route through here.
  var eventSink: ((String, [String: Any?]) -> Void)?

  private let lock = NSLock()
  private var entries: [String: PreviewEntry] = [:]
  private var views: [String: [ObjectIdentifier: WeakPreviewViewBox]] = [:]

  // MARK: Lifecycle

  func create(request: CompositeRequestRecord) async throws -> String {
    let built = try await MvmtCompositorEngine.buildComposition(request, forExport: false)
    let durationSeconds = CMTimeGetSeconds(built.duration)
    let previewId = await MainActor.run { () -> String in
      let item = AVPlayerItem(asset: built.composition)
      // Guarded: -[AVPlayerItem setVideoComposition:] validates the
      // composition against the asset and can THROW an uncaught
      // NSException doing it (the animation-tool composition did
      // exactly that on device — crash log
      // MVMTStudio-2026-11-09-220942; the tool no longer ships in
      // previews, but no composition a bad take can produce may ever
      // abort the app again). On a caught exception the preview
      // falls back to NO video composition: the stitched asset
      // still plays — degraded framing, working preview.
      avTry { item.videoComposition = built.videoComposition }
      item.audioMix = built.audioMix
      let player = AVPlayer(playerItem: item)
      let id = UUID().uuidString
      let entry = PreviewEntry(
        id: id,
        player: player,
        item: item,
        durationSeconds: durationSeconds.isFinite ? durationSeconds : 0
      )
      lock.lock()
      entries[id] = entry
      lock.unlock()
      attachObservers(entry)
      return id
    }
    notifyViews(previewId)
    return previewId
  }

  func setPaused(previewId: String, paused: Bool) throws {
    guard let entry = entry(for: previewId) else {
      throw compositorError("No preview exists with id \(previewId).")
    }
    if paused {
      entry.player.pause()
    } else {
      if entry.didEnd {
        // Standard player behaviour: pressing play after the end
        // restarts from the beginning.
        entry.didEnd = false
        entry.player.seek(to: CMTime.zero)
      }
      entry.player.play()
    }
  }

  func seek(previewId: String, seconds: Double) throws {
    guard let entry = entry(for: previewId) else {
      throw compositorError("No preview exists with id \(previewId).")
    }
    let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    // Tolerance-zero seek: cut-accurate positioning.
    entry.player.seek(to: time, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
    if seconds < entry.durationSeconds {
      entry.didEnd = false
    }
  }

  func release(previewId: String) {
    lock.lock()
    let entry = entries[previewId]
    entries[previewId] = nil
    lock.unlock()
    guard let entry else { return }
    entry.player.pause()
    if let timeObserver = entry.timeObserver {
      entry.player.removeTimeObserver(timeObserver)
      entry.timeObserver = nil
    }
    entry.statusObservation?.invalidate()
    entry.statusObservation = nil
    entry.rateObservation?.invalidate()
    entry.rateObservation = nil
    if let endObserver = entry.endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      entry.endObserver = nil
    }
    notifyViews(previewId)
  }

  // MARK: Lookup (used by the view + controls)

  func entry(for previewId: String) -> PreviewEntry? {
    lock.lock()
    let entry = entries[previewId]
    lock.unlock()
    return entry
  }

  func player(for previewId: String) -> AVPlayer? {
    entry(for: previewId)?.player
  }

  // MARK: View attachment registry

  func registerView(_ view: MvmtPreviewView, for previewId: String) {
    lock.lock()
    var boxes = views[previewId] ?? [:]
    boxes = boxes.filter { $0.value.view != nil }
    boxes[ObjectIdentifier(view)] = WeakPreviewViewBox(view)
    views[previewId] = boxes
    lock.unlock()
  }

  func unregisterView(_ view: MvmtPreviewView, for previewId: String) {
    lock.lock()
    if var boxes = views[previewId] {
      boxes[ObjectIdentifier(view)] = nil
      views[previewId] = boxes.isEmpty ? nil : boxes
    }
    lock.unlock()
  }

  private func notifyViews(_ previewId: String) {
    lock.lock()
    let live = (views[previewId] ?? [:]).values.compactMap { $0.view }
    lock.unlock()
    guard !live.isEmpty else { return }
    DispatchQueue.main.async {
      live.forEach { $0.refreshAttachment() }
    }
  }

  // MARK: Observers + status events

  private func attachObservers(_ entry: PreviewEntry) {
    emitStatus(entry, status: "loading")

    entry.statusObservation = entry.item.observe(\.status, options: [.new, .initial]) { [weak self, weak entry] item, _ in
      guard let self, let entry else { return }
      switch item.status {
      case .readyToPlay:
        self.emitStatus(entry, status: "ready")
      case .failed:
        self.emitStatus(
          entry,
          status: "error",
          message: item.error?.localizedDescription ?? "The preview failed to load."
        )
      default:
        break
      }
    }

    entry.rateObservation = entry.player.observe(\.rate, options: [.new]) { [weak self, weak entry] player, _ in
      guard let self, let entry, !entry.didEnd else { return }
      // Only meaningful once the item is ready — suppress the initial
      // rate-0 at creation (status is still "loading").
      if entry.lastStatus == "ready" || entry.lastStatus == "playing" || entry.lastStatus == "paused" {
        self.emitStatus(entry, status: player.rate != 0 ? "playing" : "paused")
      }
    }

    entry.endObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
      object: entry.item,
      queue: OperationQueue.main
    ) { [weak self, weak entry] _ in
      guard let self, let entry else { return }
      entry.didEnd = true
      self.emitStatus(entry, status: "ended")
    }

    // Position is INFORMATIONAL ONLY — playback never depends on JS.
    entry.timeObserver = entry.player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 4),
      queue: DispatchQueue.main
    ) { [weak self, weak entry] time in
      guard let self, let entry else { return }
      let position = CMTimeGetSeconds(time)
      self.eventSink?("onPreviewProgress", [
        "previewId": entry.id,
        "positionSeconds": position.isFinite ? position : 0,
        "durationSeconds": entry.durationSeconds,
        "playing": entry.player.rate != 0,
      ])
    }
  }

  private func emitStatus(_ entry: PreviewEntry, status: String, message: String? = nil) {
    if status == entry.lastStatus, status != "error" {
      return
    }
    entry.lastStatus = status
    var body: [String: Any?] = [
      "previewId": entry.id,
      "status": status,
    ]
    if let message {
      body["message"] = message
    }
    eventSink?("onPreviewStatus", body)
  }
}

// MARK: - Preview view (AVPlayerLayer host)

public final class MvmtPreviewView: ExpoView {
  private let playerLayer = AVPlayerLayer()

  /// Set from the module's Prop("previewId"). Re-attaches the layer to
  /// the registered player whenever it changes.
  var previewId: String? {
    didSet {
      if let oldValue, oldValue != previewId {
        PreviewStore.shared.unregisterView(self, for: oldValue)
      }
      if let previewId {
        PreviewStore.shared.registerView(self, for: previewId)
      }
      refreshAttachment()
    }
  }

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = UIColor.black
    clipsToBounds = true
    playerLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
    layer.addSublayer(playerLayer)
  }

  deinit {
    if let previewId {
      PreviewStore.shared.unregisterView(self, for: previewId)
    }
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
  }

  /// Point the layer at the player registered for `previewId` (or
  /// detach when there is none) and size it to the view's bounds.
  func refreshAttachment() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.refreshAttachment()
      }
      return
    }
    playerLayer.player = previewId.flatMap { PreviewStore.shared.player(for: $0) }
    playerLayer.frame = bounds
  }
}

// MARK: - Native capture (song-synced recorder)
//
// WHY THIS EXISTS: the JS-side sync offset for an expo-camera take is
// a player position sampled BEFORE recordAsync is called — blind to
// the camera's variable spin-up, which is the dominant per-take
// lip-sync error. This coordinator removes the guesswork by owning
// BOTH clocks during recording:
//
//   - an AVPlayer playing the master song (seeked with ZERO
//     tolerances to the requested start before capture rolls), and
//   - an AVCaptureSession whose video sample buffers carry
//     presentation timestamps on the host clock.
//
// The first appended frame's PTS is converted to a song position
// through the player item's own host-time mapping
// (`time(forHostTime:)`), so the result is a MEASUREMENT, not an
// estimate: `CaptureResult.firstFrameSongPositionSeconds`.
//
// The preview (`MvmtCaptureView`) binds an
// AVCaptureVideoPreviewLayer to the SAME session, so what you see is
// exactly what records. Written files are .mp4 (H.264 + AAC) in the
// caches directory, portrait 1080×1920: the video connection's
// rotation is set to portrait, so sample buffers ARRIVE portrait
// (unlike expo-camera's movie-file output, which stores landscape
// buffers plus a rotation matrix — both shapes are handled by the
// compositor, which always applies the track's preferredTransform).
//
// The coordinator deliberately does NOT touch AVAudioSession's
// category: record.tsx configures playAndRecord via expo-audio before
// recording, and the capture session is told
// `automaticallyConfiguresApplicationAudioSession = false` so it
// cannot stomp that. The internal song player simply plays within
// whatever session the app has configured.

/// Capture quality as chosen in Settings. The raw values are the JS
/// contract shared with the module's `setCaptureQuality` ('1080p30' |
/// '1080p60' | '4k60'). '1080p30' is the regression-safe default: the
/// session preset steers the device format and nothing is forced —
/// the exact configuration verified smooth on device. The 60fps
/// qualities force an exact-dimension device format (see
/// applyCaptureFormatLocked).
private enum CaptureQuality: String {
  case p1080at30 = "1080p30"
  case p1080at60 = "1080p60"
  case p4kAt60 = "4k60"

  /// Exact sensor dimensions for the format-forcing qualities; nil
  /// means preset-steered (no device format is pinned).
  var exactDimensions: (width: Int32, height: Int32)? {
    switch self {
    case .p1080at30: return nil
    case .p1080at60: return (width: 1920, height: 1080)
    case .p4kAt60: return (width: 3840, height: 2160)
    }
  }

  var framesPerSecond: Double {
    switch self {
    case .p1080at30: return 30
    case .p1080at60, .p4kAt60: return 60
    }
  }

  /// Writer video bitrate (bps) for a take of the given size at the
  /// given cadence — the tuned "Balanced" table (Jaizon, 2026-11-10):
  /// HEVC at these rates matches the old H.264 look at ~40% fewer
  /// bits (the old bpp formula produced ≈10/20/45 Mbps). Keyed on the
  /// DELIVERED pixels × fps — not the requested quality — because a
  /// format fallback can hand the writer a different cadence than
  /// the quality asked for. Unlisted shapes scale the 1080p60 figure
  /// by their pixel-throughput ratio.
  static func writerVideoBitrate(pixelCount: Double, framesPerSecond: Double) -> Int {
    let hdPixels = 1920.0 * 1080.0
    let uhdPixels = 3840.0 * 2160.0
    let isHD = abs(pixelCount - hdPixels) < hdPixels * 0.05
    let isUHD = abs(pixelCount - uhdPixels) < uhdPixels * 0.05
    if isHD, framesPerSecond < 45 {
      return 8_000_000 // 1080p30
    }
    if isHD {
      return 14_000_000 // 1080p60
    }
    if isUHD, framesPerSecond >= 45 {
      return 30_000_000 // 4K60
    }
    let reference = hdPixels * 60.0
    let scaled = 14_000_000.0 * (pixelCount * framesPerSecond) / reference
    return Int(min(60_000_000.0, max(1_000_000.0, scaled)))
  }
}

private struct CaptureConfiguration {
  var facing: AVCaptureDevice.Position = .back
  var torch: Bool = false
  /// Expo-style zoom 0..1 (mapped to a device factor when applied).
  var zoom: Double = 0
  var mirrored: Bool = false
  var quality: CaptureQuality = .p1080at30
  /// Stabilization preference (Settings, default ON): the capture
  /// connections run .auto when true, .off when false.
  var stabilization: Bool = true
  /// Exposure-lock preference (Settings, default ON): exposure +
  /// white balance lock for the duration of each take.
  var lockExposureWhileRecording: Bool = true
}

private final class CaptureCoordinator: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate
{
  static let shared = CaptureCoordinator()

  /// The one capture session — created once, reconfigured in place.
  /// The preview view binds its layer to this exact object.
  let session = AVCaptureSession()

  /// Serial queue for ALL session configuration, sample-buffer
  /// handling and writer appends, so no capture state needs locks.
  /// Sample-buffer delegate callbacks arrive on `sampleBufferQueue`
  /// and are forwarded onto this queue in arrival order (see the
  /// delegate methods) — the delegate never runs handler work itself.
  private let queue = DispatchQueue(label: "au.mvmtstudio.capture")

  /// DEDICATED serial queue for the capture outputs' sample-buffer
  /// delegate. Round 3's preview crawled at ~5fps while this shared
  /// the control queue above: every control operation (session
  /// reconfiguration, player seeks, measurements) ran BETWEEN buffer
  /// callbacks on the session's delivery path, and with
  /// `alwaysDiscardsLateVideoFrames = false` the backlogged output
  /// back-pressured the whole session — preview included. The
  /// delegate now does exactly one thing per buffer (an async hop
  /// onto `queue`), so delivery can never be stalled by control work;
  /// the shared serial delegate queue also preserves the video/audio
  /// arrival order the handlers rely on.
  private let sampleBufferQueue = DispatchQueue(label: "au.mvmtstudio.capture.samples")

  // MARK: Configuration (set via the preview view's props)

  private var configuration = CaptureConfiguration()
  private var outputsConfigured = false
  private var sessionConfigured = false
  /// The quality whose format selection was last applied to the
  /// CURRENT device (nil = nothing applied yet). configureSessionLocked
  /// re-runs selection when this differs from `configuration.quality`
  /// or when the input was just swapped (a facing flip hands the
  /// session a different device that needs its own selection).
  private var appliedFormatQuality: CaptureQuality?
  /// Frame rate the active configuration delivers (30 on the preset
  /// path — and after any forced-format fallback — 60 when a 60fps
  /// format is in force). Read by startWriterLocked to scale the
  /// encoder bitrate to the real cadence.
  private var activeFramesPerSecond: Double = 30
  private var configuredPosition: AVCaptureDevice.Position?
  private var videoDevice: AVCaptureDevice?
  private var videoInput: AVCaptureDeviceInput?
  private var audioInput: AVCaptureDeviceInput?
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private weak var previewLayer: AVCaptureVideoPreviewLayer?
  private var activePreviewViews: Set<ObjectIdentifier> = []
  /// Retained NotificationCenter tokens for the session-lifecycle
  /// observers (see registerSessionObservers) — a block observer is
  /// removed when its token is released, so the singleton holds the
  /// tokens for its whole lifetime.
  private var sessionObserverTokens: [NSObjectProtocol] = []

  // MARK: Recording state (queue-owned)

  private enum State {
    case idle
    case preparing // startCapture in flight; song seek pending — buffers dropped
    case recording // armed: samples are being appended
    case finishing
    case finished
  }

  private var state: State = .idle
  /// True while THIS capture holds the device's exposure / white
  /// balance locked (see lockExposureForCaptureLocked) — cleanup
  /// restores continuous auto only when a lock was actually taken.
  private var exposureLockedForCapture = false
  private var writer: AVAssetWriter?
  private var videoWriterInput: AVAssetWriterInput?
  private var audioWriterInput: AVAssetWriterInput?
  private var writerStarted = false
  private var firstVideoPTS: CMTime?
  private var firstFrameSongPosition: Double?
  private var outputURL: URL?
  private var songPlayer: AVPlayer?
  private var songItem: AVPlayerItem?
  /// The position the song player was seeked to for this capture —
  /// the finish-time refinement requires the item to have advanced
  /// genuinely beyond it before trusting a late anchor (a position
  /// still clamped AT the target is the preroll signature).
  private var songSeekStartSeconds: Double = 0
  /// Resolved URL of the ACTIVE take's song (nil for a songless
  /// take) — cleanup compares it against the standing player's URL
  /// to decide whether the finished player is kept warm.
  private var activeSongURL: URL?
  // MARK: Standing (pre-warmed) song player (queue-owned)
  //
  // Cold-start fix (Jaizon: "the first few takes suck — after 2
  // takes the app catches up"): preparePlayerLocked used to build a
  // FRESH AVPlayer+AVPlayerItem per take, so early takes paid the
  // full cold cost (asset open, item load, preroll, seek) inside the
  // record press. The standing player is created ahead of time via
  // prepareSong (JS calls it when Record is focused with a track),
  // loaded and prerolled PAUSED; a take ADOPTS it when the URI
  // matches, and cleanup keeps/promotes the finished player here so
  // the next take starts warm. It never plays outside a take and
  // never touches the audio session category.
  private var warmedPlayer: AVPlayer?
  private var warmedItem: AVPlayerItem?
  private var warmedURL: URL?
  /// Format description of the latest pre-roll audio buffer, kept so
  /// the audio writer input can be created the moment the writer
  /// starts (audio samples themselves before the first frame drop).
  private var pendingAudioFormat: CMFormatDescription?
  private var maxDurationSeconds: Double = 0
  private var startContinuation: CheckedContinuation<Void, Error>?
  private var stopContinuations: [CheckedContinuation<CaptureResultRecord, Error>] = []
  private var finishedResult: CaptureResultRecord?
  private var finishedError: Error?
  private var startTimeoutItem: DispatchWorkItem?
  private var seekArmItem: DispatchWorkItem?
  /// KVO token watching the current take's song item for
  /// .readyToPlay when the zero-tolerance seek must wait for
  /// readiness (see issueSeekWhenReadyLocked). Invalidated when the
  /// seek is issued and wherever seekArmItem is torn down — no
  /// dangling observers.
  private var songStatusObservation: NSKeyValueObservation?

  // MARK: Availability

  var isAvailable: Bool {
    AVCaptureDevice.default(for: .video) != nil
  }

  // MARK: View registration + prop entry points (called on main)

  func registerPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
    queue.async { [weak self] in
      self?.previewLayer = layer
      self?.applyConnectionSettingsLocked()
      self?.updateSessionRunningLocked()
    }
  }

  func unregisterPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
    queue.async { [weak self] in
      if self?.previewLayer === layer {
        self?.previewLayer = nil
      }
    }
  }

  func setPreviewActive(_ active: Bool, viewID: ObjectIdentifier) {
    queue.async { [weak self] in
      guard let self else { return }
      if active {
        self.activePreviewViews.insert(viewID)
      } else {
        self.activePreviewViews.remove(viewID)
      }
      self.updateSessionRunningLocked()
    }
  }

  func setFacing(_ position: AVCaptureDevice.Position) {
    queue.async { [weak self] in
      guard let self, self.configuration.facing != position else { return }
      self.configuration.facing = position
      // Swapping the camera mid-capture would break the writer's
      // timeline; it applies from the next capture. (The record UI
      // doesn't offer a flip while recording anyway.)
      if self.state != .recording, self.state != .preparing {
        try? self.configureSessionLocked()
        self.updateSessionRunningLocked()
      }
    }
  }

  /// Applies a Settings capture-quality change ('1080p30' |
  /// '1080p60' | '4k60'). Unknown values resolve to the '1080p30'
  /// default rather than failing: a JS/native version skew must
  /// never break recording. Like a facing change, a quality change
  /// never reconfigures mid-capture — it applies from the next one.
  func setQuality(_ qualityRawValue: String) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }
        let quality = CaptureQuality(rawValue: qualityRawValue) ?? .p1080at30
        if self.configuration.quality != quality {
          self.configuration.quality = quality
          if self.state != .recording, self.state != .preparing {
            try? self.configureSessionLocked()
            self.updateSessionRunningLocked()
          }
        }
        continuation.resume()
      }
    }
  }

  /// Applies the Settings stabilization toggle. The mode itself is
  /// (re)asserted by applyConnectionSettingsLocked; like the other
  /// preferences this never reconfigures mid-capture — a change made
  /// while recording lands on the connection from the next take.
  func setStabilization(_ enabled: Bool) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }
        if self.configuration.stabilization != enabled {
          self.configuration.stabilization = enabled
          if self.state != .recording, self.state != .preparing {
            self.applyConnectionSettingsLocked()
          }
        }
        continuation.resume()
      }
    }
  }

  /// Applies the Settings exposure-lock toggle. Just stores the
  /// preference: beginCaptureLocked reads it when a take arms and
  /// cleanupCaptureLocked restores continuous auto when it ends.
  func setExposureLock(_ enabled: Bool) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume()
          return
        }
        self.configuration.lockExposureWhileRecording = enabled
        continuation.resume()
      }
    }
  }

  func setMirrored(_ mirrored: Bool) {
    queue.async { [weak self] in
      guard let self, self.configuration.mirrored != mirrored else { return }
      self.configuration.mirrored = mirrored
      if self.state != .recording, self.state != .preparing {
        self.applyConnectionSettingsLocked()
      }
    }
  }

  func setTorch(_ torch: Bool) {
    queue.async { [weak self] in
      guard let self, self.configuration.torch != torch else { return }
      self.configuration.torch = torch
      self.applyDeviceSettingsLocked()
    }
  }

  func setZoom(_ zoom: Double) {
    queue.async { [weak self] in
      guard let self, self.configuration.zoom != zoom else { return }
      self.configuration.zoom = zoom
      self.applyDeviceSettingsLocked()
    }
  }

  // MARK: Session configuration (queue only)

  private func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
      return device
    }
    return AVCaptureDevice.default(for: .video)
  }

  /// (Re)builds inputs/outputs to match `configuration`. Idempotent;
  /// safe to call whenever the session is stopped or running (but not
  /// mid-capture — callers guard that).
  private func configureSessionLocked() throws {
    if !outputsConfigured {
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      ]
      // Late-frame discarding follows the capture state: TRUE while
      // idle (preview frames nobody records must never backlog the
      // session — a queued idle frame is pure back-pressure), FALSE
      // while a capture is in flight (a dropped frame is a timing
      // hole in the take). beginCaptureLocked flips it off;
      // cleanupCaptureLocked restores it.
      videoOutput.alwaysDiscardsLateVideoFrames = true
      videoOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
      audioOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
      outputsConfigured = true
    }

    session.beginConfiguration()
    // The app (expo-audio) owns the audio session category.
    session.automaticallyConfiguresApplicationAudioSession = false

    var inputSwapped = false
    if configuredPosition != configuration.facing || videoInput == nil {
      if let oldInput = videoInput {
        session.removeInput(oldInput)
        videoInput = nil
        videoDevice = nil
        configuredPosition = nil
      }
      // Collected, not thrown inside the configuration block, so
      // commitConfiguration runs exactly once below.
      var deviceError: Error?
      if let device = captureDevice(for: configuration.facing) {
        do {
          let input = try AVCaptureDeviceInput(device: device)
          if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            videoDevice = device
            configuredPosition = configuration.facing
            inputSwapped = true
          } else {
            deviceError = compositorError("The capture session rejected the camera input.")
          }
        } catch {
          deviceError = compositorError(
            "Could not open the camera: \(error.localizedDescription)"
          )
        }
      } else {
        deviceError = compositorError(
          "No \(configuration.facing == .front ? "front" : "back") camera is available for native capture."
        )
      }
      if let deviceError {
        session.commitConfiguration()
        throw deviceError
      }
    }

    // Format selection for the configured quality — runs inside this
    // begin/commit block when the input was just (re)added (a new
    // device needs its own selection) or when the applied selection
    // is stale (the quality changed under the same device).
    if inputSwapped || appliedFormatQuality != configuration.quality {
      applyCaptureFormatLocked()
    }

    if audioInput == nil, let audioDevice = AVCaptureDevice.default(for: .audio) {
      if let input = try? AVCaptureDeviceInput(device: audioDevice), session.canAddInput(input) {
        session.addInput(input)
        audioInput = input
      }
    }

    if session.outputs.first(where: { $0 === videoOutput }) == nil, session.canAddOutput(videoOutput) {
      session.addOutput(videoOutput)
    }
    if session.outputs.first(where: { $0 === audioOutput }) == nil, session.canAddOutput(audioOutput) {
      session.addOutput(audioOutput)
    }
    session.commitConfiguration()
    sessionConfigured = true

    applyConnectionSettingsLocked()
    applyDeviceSettingsLocked()
  }

  /// The preset-steered configuration — '1080p30', and the silent
  /// fallback for the forcing qualities when this device offers no
  /// qualifying format. This is the exact configuration verified
  /// smooth on device before any format forcing existed.
  private func applyPresetSteeringLocked() {
    if session.canSetSessionPreset(.hd1920x1080) {
      session.sessionPreset = .hd1920x1080
    } else if session.canSetSessionPreset(.high) {
      session.sessionPreset = .high
    }
  }

  /// Applies `configuration.quality` to the current device. Runs
  /// inside configureSessionLocked's begin/commit block.
  ///
  /// History that shapes this code: Round 3 forced a 60fps format
  /// and the preview crawled at ~5fps through two picker variants;
  /// Round 4 removed forcing entirely. Forcing is back ONLY as an
  /// explicit Settings choice (1080p60 / 4K60), and the pipeline
  /// cause of the crawl is fixed separately (dedicated delegate
  /// queue + idle frame discarding), so the format itself is no
  /// longer dragging control-queue work onto the delivery path.
  /// Every failure here degrades to the preset path — a quality
  /// preference must never break recording.
  private func applyCaptureFormatLocked() {
    let quality = configuration.quality
    appliedFormatQuality = quality
    activeFramesPerSecond = 30
    guard quality.exactDimensions != nil else {
      // '1080p30': EXACTLY the pre-quality path — preset steering,
      // no device format pinned, no .inputPriority.
      applyPresetSteeringLocked()
      return
    }
    guard let device = videoDevice,
      let format = Self.bestCaptureFormat(for: device, quality: quality)
    else {
      // No qualifying format on this device: preset path, silently.
      applyPresetSteeringLocked()
      return
    }
    // ORDER IS LOAD-BEARING: .inputPriority FIRST. Assigning
    // activeFormat on a device feeding a session that runs a
    // dimensional preset throws NSInvalidArgumentException (the
    // Round 3 launch crash) — the session must defer to the input
    // before the device format is touched.
    session.sessionPreset = .inputPriority
    let frameDuration = CMTime(value: 1, timescale: 60)
    var lockError: Error?
    var deviceLocked = false
    let exception = avTry {
      do {
        try device.lockForConfiguration()
        deviceLocked = true
        device.activeFormat = format
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
      } catch {
        lockError = error
      }
    }
    // Unlocked OUTSIDE the guard: if a setter raised mid-block, the
    // device must not be left locked for every later configuration.
    if deviceLocked {
      device.unlockForConfiguration()
    }
    if exception != nil || lockError != nil {
      // The device refused the format: back to the preset path
      // rather than a half-forced session.
      applyPresetSteeringLocked()
      return
    }
    activeFramesPerSecond = quality.framesPerSecond
  }

  /// The device format for a format-forcing quality: EXACT
  /// dimensions, a frame-rate range covering the target fps.
  /// Candidates are RANKED, never first-matched (the Round 3 picker
  /// grabbed a slow-motion/10-bit variant): lowest top frame rate
  /// that covers the target first (the everyday format tops out at
  /// the target; slo-mo readout modes top at 120/240), then the
  /// exact pixel format the data output consumes (420f — zero
  /// per-frame conversion), then 420v, then anything else.
  private static func bestCaptureFormat(
    for device: AVCaptureDevice,
    quality: CaptureQuality
  ) -> AVCaptureDevice.Format? {
    guard let dimensions = quality.exactDimensions else { return nil }
    let targetFps = quality.framesPerSecond
    var best: AVCaptureDevice.Format?
    var bestRank: (Int, Int)?
    for format in device.formats {
      let formatDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      guard formatDimensions.width == dimensions.width,
        formatDimensions.height == dimensions.height
      else { continue }
      // The tightest range that still covers the target fps.
      let covering = format.videoSupportedFrameRateRanges
        .filter { $0.minFrameRate <= targetFps && $0.maxFrameRate >= targetFps - 0.1 }
        .min { $0.maxFrameRate < $1.maxFrameRate }
      guard let range = covering else { continue }
      let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      let subtypeRank =
        subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ? 0
        : subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 2
      let rank = (Int(range.maxFrameRate.rounded()), subtypeRank)
      if let current = bestRank, rank >= current { continue }
      best = format
      bestRank = rank
    }
    return best
  }

  /// Portrait rotation + mirroring on the writer (data output)
  /// connection and, identically, on the preview layer's connection —
  /// what you see is what records. Mirroring follows the `mirrored`
  /// prop exactly (auto-mirroring is disabled so the prop is the
  /// single source of truth, for preview AND the written file).
  private func applyConnectionSettingsLocked() {
    let mirrored = configuration.facing == .front && configuration.mirrored
    if let connection = videoOutput.connection(with: .video) {
      setPortraitRotation(on: connection)
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
      }
      applyStabilization(on: connection)
    }
    if let layer = previewLayer {
      let layerConnection = layer.connection
      DispatchQueue.main.async {
        if let layerConnection {
          self.setPortraitRotation(on: layerConnection)
          if layerConnection.isVideoMirroringSupported {
            layerConnection.automaticallyAdjustsVideoMirroring = false
            layerConnection.isVideoMirrored = mirrored
          }
          self.applyStabilization(on: layerConnection)
        }
      }
    }
  }

  /// Stabilization from the Settings preference: .auto (the device
  /// picks the strongest mode the active format supports) or .off,
  /// applied wherever the connection supports it. The writer
  /// connection's mode is what the recorded file gets; the preview
  /// layer's connection is set identically so the preview doesn't
  /// promise steadiness the file won't have (or vice versa).
  private func applyStabilization(on connection: AVCaptureConnection) {
    guard connection.isVideoStabilizationSupported else { return }
    let mode: AVCaptureVideoStabilizationMode = configuration.stabilization ? .auto : .off
    if connection.preferredVideoStabilizationMode != mode {
      connection.preferredVideoStabilizationMode = mode
    }
  }

  private func setPortraitRotation(on connection: AVCaptureConnection) {
    // Portrait via the ORIENTATION API, which is camera-aware: the
    // framework maps .portrait to the correct rotation angle for the
    // active camera. A flat videoRotationAngle of 90 is only right
    // for the back camera — the front sensor is mounted rotated the
    // opposite way, and 90 left the front camera sideways (Jaizon's
    // device report, 2026-11-09). videoOrientation is deprecated in
    // iOS 17 in favour of videoRotationAngle, but it is still
    // honoured and still the only camera-aware way to say "portrait".
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    } else if #available(iOS 17.0, *), connection.isVideoRotationAngleSupported(90) {
      connection.videoRotationAngle = 90
    }
  }

  /// Torch + zoom are device properties — safe to apply live, even
  /// mid-capture, unlike input swaps.
  private func applyDeviceSettingsLocked() {
    guard let device = videoDevice else { return }
    do {
      try device.lockForConfiguration()
    } catch {
      return
    }
    if device.hasTorch {
      let wantTorch = configuration.torch && configuration.facing == .back
      let mode: AVCaptureDevice.TorchMode = wantTorch ? .on : .off
      if device.torchMode != mode {
        device.torchMode = mode
      }
    }
    // Expo-style zoom 0..1 → factor 1..6, clamped to the device.
    let requested = 1.0 + max(0, min(1, configuration.zoom)) * 5.0
    let factor = min(requested, Double(device.activeFormat.videoMaxZoomFactor))
    if abs(Double(device.videoZoomFactor) - factor) > 0.01 {
      device.videoZoomFactor = CGFloat(factor)
    }
    device.unlockForConfiguration()
  }

  // MARK: Session recovery (interruptions / runtime errors / foreground)

  override init() {
    super.init()
    registerSessionObservers()
  }

  /// The coordinator never observed the session's lifecycle
  /// notifications, so an interruption during launch (expo-audio
  /// activating the audio session, system churn while the app
  /// auto-navigates into Record) left the session "running" but
  /// delivering nothing — the preview froze on a still frame until
  /// pressing record happened to call startRunning again. These
  /// observers close that hole. Every callback hops onto the capture
  /// queue and funnels into recoverSessionLocked, which stays behind
  /// the same shouldRun gate as everything else — a hidden screen
  /// never starts the camera.
  private func registerSessionObservers() {
    let center = NotificationCenter.default
    sessionObserverTokens.append(
      center.addObserver(
        forName: .AVCaptureSessionInterruptionEnded,
        object: session,
        queue: nil
      ) { [weak self] _ in
        self?.queue.async { self?.recoverSessionLocked() }
      }
    )
    sessionObserverTokens.append(
      center.addObserver(
        forName: .AVCaptureSessionRuntimeError,
        object: session,
        queue: nil
      ) { [weak self] notification in
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        self?.queue.async { self?.handleRuntimeErrorLocked(error) }
      }
    )
    sessionObserverTokens.append(
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.queue.async { self?.recoverSessionLocked() }
      }
    )
  }

  /// Shared recovery for interruptions ending, runtime errors and
  /// foreground returns. The unconditional startRunning() after the
  /// update is the point — across an interruption `session.isRunning`
  /// stays true while nothing is delivered, so the update's
  /// `if !isRunning` check alone leaves a frozen session frozen.
  /// startRunning() is the documented post-interruption recovery,
  /// and a no-op on a session that is already running healthily.
  private func recoverSessionLocked() {
    let shouldRun =
      !activePreviewViews.isEmpty || state == .preparing || state == .recording
    guard shouldRun else { return }
    updateSessionRunningLocked()
    session.startRunning()
  }

  /// Runtime errors are treated as recoverable: drop the configured
  /// flag so the next update reconfigures, then recover. For a media
  /// services reset every pre-reset capture object is dead, so the
  /// stale input/output references are dropped too — otherwise the
  /// reconfigure would trust them and rebuild nothing.
  private func handleRuntimeErrorLocked(_ error: NSError?) {
    sessionConfigured = false
    if let error,
      error.domain == AVFoundationErrorDomain,
      // AVFoundationErrorMediaServicesWereReset (-11819) — the named
      // Swift enum isn't exposed in the current SDK, so compare the
      // code directly (CI caught this).
      error.code == -11819
    {
      if let oldInput = videoInput {
        session.removeInput(oldInput)
      }
      if let oldInput = audioInput {
        session.removeInput(oldInput)
      }
      if session.outputs.contains(where: { $0 === videoOutput }) {
        session.removeOutput(videoOutput)
      }
      if session.outputs.contains(where: { $0 === audioOutput }) {
        session.removeOutput(audioOutput)
      }
      videoInput = nil
      audioInput = nil
      videoDevice = nil
      configuredPosition = nil
      outputsConfigured = false
      // The rebuilt input is a fresh device object: format selection
      // for the configured quality must run again on it.
      appliedFormatQuality = nil
    }
    recoverSessionLocked()
  }

  private func updateSessionRunningLocked() {
    let shouldRun =
      !activePreviewViews.isEmpty || state == .preparing || state == .recording
    if shouldRun {
      if !sessionConfigured {
        try? configureSessionLocked()
      }
      if !session.isRunning {
        session.startRunning()
      }
    } else if session.isRunning {
      session.stopRunning()
    }
  }

  // MARK: Capture lifecycle

  /// Pre-warms the standing song player for `songUri` (nil tears it
  /// down). Fire-and-forget by design: the queue work is enqueued
  /// and this returns — the preroll completes asynchronously, and a
  /// record press that beats it still works (the item is simply
  /// less warm). No permission is needed and nothing plays.
  func prepareSong(songUri: String?) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [weak self] in
        self?.prepareSongLocked(songUri: songUri)
        continuation.resume()
      }
    }
  }

  private func prepareSongLocked(songUri: String?) {
    guard let songUri, !songUri.isEmpty else {
      // No track: tear the standing player down. If it happens to be
      // the active take's player (track cleared mid-take), the take
      // keeps its own references and finishes normally — only the
      // standing reference is dropped.
      if let standing = warmedPlayer, standing !== songPlayer {
        standing.pause()
      }
      warmedPlayer = nil
      warmedItem = nil
      warmedURL = nil
      return
    }
    let url = MvmtCompositorEngine.resolveURL(songUri)
    if warmedURL == url, let standing = warmedPlayer {
      // Already standing for this song — just keep it warm. (Unless
      // it is mid-take right now: a rate-0 preroll must never touch
      // the playing player.)
      // Deliberately NO preroll here (see the note at the player
      // creation below): the standing item keeps loading on its own.
      _ = standing
      return
    }
    // Replace the standing player. Same mid-take caveat as the
    // teardown above: an old standing player that is mid-take is
    // left playing for its take; only the standing reference moves.
    if let old = warmedPlayer, old !== songPlayer {
      old.pause()
    }
    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    warmedItem = item
    warmedPlayer = player
    warmedURL = url
    // The item is created standing and PAUSED: AVFoundation loads
    // its asset asynchronously as soon as it is attached to a
    // player, which is most of the warm-up — playback never starts
    // and the audio session category is never touched (the app owns
    // it). Deliberately NO preroll(atRate:) anywhere in this module:
    // on Jaizon's device it threw an uncaught NSException from
    // inside AVPlayer (cancelPendingPrerolls) at app open and
    // aborted the process — crash log MVMTStudio-2026-11-09-183251.
    // The residual spin-up at take start is already neutralised:
    // the sync anchor is measured late and the length clock starts
    // at the first frame.
    _ = player
  }

  func start(_ args: CaptureStartArgsRecord) async throws {
    try await ensurePermission(for: .video)
    try await ensurePermission(for: .audio)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: compositorError("The capture engine is gone."))
          return
        }
        guard self.state == .idle || self.state == .finished else {
          continuation.resume(
            throwing: compositorError("A capture is already in progress.")
          )
          return
        }
        self.beginCaptureLocked(args: args, continuation: continuation)
      }
    }
  }

  func stop() async throws -> CaptureResultRecord {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<CaptureResultRecord, Error>) in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: compositorError("The capture engine is gone."))
          return
        }
        switch self.state {
        case .finished:
          if let result = self.finishedResult {
            continuation.resume(returning: result)
          } else {
            continuation.resume(
              throwing: self.finishedError
                ?? compositorError("The capture failed.")
            )
          }
        case .recording, .preparing:
          self.stopContinuations.append(continuation)
          self.beginFinishLocked()
        case .finishing:
          self.stopContinuations.append(continuation)
        case .idle:
          continuation.resume(
            throwing: compositorError("No capture is in progress.")
          )
        }
      }
    }
  }

  private func ensurePermission(for mediaType: AVMediaType) async throws {
    let kind = mediaType == .video ? "Camera" : "Microphone"
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
      return
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: mediaType)
      if !granted {
        throw compositorError("\(kind) permission was not granted — native capture unavailable.")
      }
    default:
      throw compositorError("\(kind) permission is denied — native capture unavailable.")
    }
  }

  private func beginCaptureLocked(
    args: CaptureStartArgsRecord,
    continuation: CheckedContinuation<Void, Error>
  ) {
    // Reset per-capture state.
    finishedResult = nil
    finishedError = nil
    firstFrameSongPosition = nil
    firstVideoPTS = nil
    songSeekStartSeconds = 0
    activeSongURL = nil
    writerStarted = false
    videoWriterInput = nil
    audioWriterInput = nil
    pendingAudioFormat = nil
    maxDurationSeconds = args.maxDurationSeconds.isFinite ? args.maxDurationSeconds : 0

    do {
      try configureSessionLocked()
    } catch {
      state = .idle
      continuation.resume(throwing: error)
      return
    }

    guard
      let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else {
      state = .idle
      continuation.resume(throwing: compositorError("Could not locate the caches directory."))
      return
    }
    let url = cachesDirectory.appendingPathComponent("mvmt-capture-\(UUID().uuidString).mp4")
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
    outputURL = url
    // The bridged Swift error covers the documented failure modes;
    // avTry additionally catches any NSException the writer's
    // initialiser raises, so creation can only ever fail the start
    // cleanly (the JS side shows its notice), never abort the app.
    var writerCreateError: Error?
    let writerException = avTry {
      do {
        self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
      } catch {
        writerCreateError = error
      }
    }
    if let writerException {
      state = .idle
      continuation.resume(
        throwing: exceptionError("The recording file could not be created", writerException)
      )
      return
    }
    if let writerCreateError {
      state = .idle
      continuation.resume(throwing: writerCreateError)
      return
    }

    // Exposure lock (Settings, default ON): freeze exposure + white
    // balance at their armed values for the whole take, so the
    // picture can't breathe mid-performance. Armed HERE — after the
    // session is configured and the writer exists, the last point
    // where every exit still funnels through cleanupCaptureLocked
    // (which restores continuous auto). Best-effort by design: a
    // device that refuses simply records unlocked.
    lockExposureForCaptureLocked()

    state = .preparing
    // From here to cleanupCaptureLocked every delivered frame is a
    // potential timing hole in the take: stop discarding late frames
    // for the duration of the capture.
    videoOutput.alwaysDiscardsLateVideoFrames = false
    startContinuation = continuation
    if !session.isRunning {
      session.startRunning()
    }
    preparePlayerLocked(songUri: args.songUri, songStartSeconds: args.songStartSeconds)

    // Safety net: if the capture never arms or never delivers a
    // frame, fail the start so the JS side can fall back instead of
    // hanging on a black preview.
    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.state == .preparing || (self.state == .recording && !self.writerStarted) {
        self.abortCaptureLocked(
          error: compositorError("The camera did not start delivering frames.")
        )
      }
    }
    startTimeoutItem = timeout
    queue.asyncAfter(deadline: .now() + 10, execute: timeout)
  }

  /// Sets up the internal song player and seeks it (ZERO tolerances —
  /// the seek must land on the exact requested position; this player
  /// is the song clock for the whole capture). The seek waits for the
  /// item to be .readyToPlay (see issueSeekWhenReadyLocked): a seek
  /// issued against a still-loading item is unreliable on device.
  /// Capture "arms"
  /// (transitions to .recording, samples start appending) only once
  /// the seek has completed and playback has started, or immediately
  /// when there is no song. A failed song never blocks the recording
  /// itself — the take is still captured, its first-frame song
  /// position just stays nil (the file-based measurement remains as
  /// the safety net, exactly as before).
  private func preparePlayerLocked(songUri: String?, songStartSeconds: Double) {
    songPlayer = nil
    songItem = nil
    activeSongURL = nil
    songSeekStartSeconds = max(0, songStartSeconds)
    guard let songUri, !songUri.isEmpty else {
      // No song clock to wait for — arm immediately.
      state = .recording
      return
    }
    let url = MvmtCompositorEngine.resolveURL(songUri)
    activeSongURL = url
    let item: AVPlayerItem
    let player: AVPlayer
    if warmedURL == url, let standing = warmedPlayer, let standingItem = warmedItem {
      // ADOPT the pre-warmed standing player: the cold costs (asset
      // open, item load, preroll) were paid when the Record screen
      // was focused, not inside this record press. The seek + play
      // below is exactly the fresh-player path.
      item = standingItem
      player = standing
    } else {
      item = AVPlayerItem(url: url)
      player = AVPlayer(playerItem: item)
    }
    songItem = item
    songPlayer = player

    let target = CMTime(seconds: max(0, songStartSeconds), preferredTimescale: 600)

    // Outer bound: if the seek never lands, arm anyway (measurement
    // stays nil) rather than hanging the recording — and PLAY unless
    // the item failed. The old timeout armed WITHOUT playing, so a
    // stalled seek produced a take recorded in silence.
    let armTimeout = DispatchWorkItem { [weak self] in
      guard let self, self.state == .preparing else { return }
      if item.status != .failed {
        player.play()
      }
      self.state = .recording
    }
    seekArmItem = armTimeout
    queue.asyncAfter(deadline: .now() + 5, execute: armTimeout)

    issueSeekWhenReadyLocked(item: item, player: player, target: target)
  }

  /// Issues the take's zero-tolerance seek — but only once the item
  /// is .readyToPlay. A seek issued against a not-yet-ready item is
  /// unreliable on device: the FIRST take of a session adopts the
  /// standing player prepareSong created moments earlier, its item
  /// still loading, and the take played from 0 instead of the picked
  /// part (later takes adopt the promoted previous player, long
  /// since ready — which is why only the first take was wrong). Not
  /// ready yet → a KVO observation on the item's status issues the
  /// seek the moment it turns ready; a failed item arms without
  /// playing (the failed-item behaviour the seek completion has
  /// always had). The 5s arm timeout in preparePlayerLocked remains
  /// the outer bound either way.
  private func issueSeekWhenReadyLocked(item: AVPlayerItem, player: AVPlayer, target: CMTime) {
    tearDownSongStatusObservationLocked()
    switch item.status {
    case .readyToPlay:
      issueSeekLocked(item: item, player: player, target: target)
    case .failed:
      // A failed song never blocks the recording: arm silent.
      seekArmItem?.cancel()
      seekArmItem = nil
      state = .recording
    default:
      // .initial is load-bearing (Jaizon, 2026-11-10: the first-take
      // bug came BACK intermittently after the readiness gate shipped):
      // without it, an item that turns .readyToPlay in the gap between
      // the status switch above and this registration never notifies —
      // the seek is never issued, the 5s arm timeout plays the item
      // from 0, and the take starts at the top of the song instead of
      // the picked part. Fresh standing items (first take of a
      // session, first take after a track change) are exactly the ones
      // still loading here, which is why the bug was intermittent and
      // first-take-shaped. .initial delivers the current status
      // synchronously at registration; the closure's guards make a
      // duplicate delivery harmless.
      songStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
        guard let self else { return }
        // Status changes arrive on an arbitrary thread — hop onto
        // the capture queue like every other capture callback.
        self.queue.async {
          guard self.state == .preparing, self.songItem === observedItem else { return }
          switch observedItem.status {
          case .readyToPlay:
            self.issueSeekLocked(item: observedItem, player: player, target: target)
          case .failed:
            self.tearDownSongStatusObservationLocked()
            self.seekArmItem?.cancel()
            self.seekArmItem = nil
            self.state = .recording
          default:
            break
          }
        }
      }
    }
  }

  /// The zero-tolerance seek itself, plus its completion: cancel the
  /// arm timeout, play (unless the item failed) and arm. A seek whose
  /// completion reports finished == false was superseded before it
  /// landed — re-issue the same seek ONCE before playing, so the
  /// take still starts at the picked position.
  private func issueSeekLocked(item: AVPlayerItem, player: AVPlayer, target: CMTime, isRetry: Bool = false) {
    // The seek supersedes the readiness wait.
    tearDownSongStatusObservationLocked()
    item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      guard let self else { return }
      self.queue.async {
        guard self.state == .preparing else { return }
        if !finished, !isRetry {
          self.issueSeekLocked(item: item, player: player, target: target, isRetry: true)
          return
        }
        self.seekArmItem?.cancel()
        self.seekArmItem = nil
        // Play even if the precise seek reports failure: the
        // finish-time anchor measures wherever the song actually
        // is. Only a FAILED item stays silent.
        if item.status != .failed {
          player.play()
        }
        self.state = .recording
      }
    }
  }

  private func tearDownSongStatusObservationLocked() {
    songStatusObservation?.invalidate()
    songStatusObservation = nil
  }

  /// The anchor algebra shared by the first-frame estimate and the
  /// finish-time refinement: the song's position at the first frame
  /// is the item's position at some anchor instant, shifted by how
  /// far the first frame's PTS sits from that same instant — both
  /// read on the SAME clock (the capture session's master clock; see
  /// sessionNowLocked).
  ///
  /// Why the anchor must be LATE (refineSongPositionAtFinishLocked):
  /// at the first frame the player may still be prerolling — play()
  /// was called milliseconds earlier on a cold, zero-tolerance-seeked
  /// item, so currentTime() can sit clamped at the seek target while
  /// real time flows (timeControlStatus is
  /// .waitingToPlayAtSpecifiedRate; `rate` reads 1.0 throughout, so
  /// it does NOT prove the item is advancing). A pair sampled then
  /// bakes the entire preroll stall into the stored position — on
  /// Jaizon's iPhone ≈0.5s, heard as the video sitting uniformly
  /// behind the song on every take. Once playback is provably
  /// advancing, the item position grows 1:1 with the session clock,
  /// so a pair sampled at finish projects back to the first frame
  /// exactly and the stall term vanishes; using the session's master
  /// clock for both PTS and "now" (with an audio input present that
  /// clock may be the audio device's clock, not the host clock)
  /// removes the cross-clock term as well.
  static func anchoredSongPosition(
    anchorPosSeconds: Double,
    anchorClockSeconds: Double,
    firstFramePTSSeconds: Double
  ) -> Double {
    anchorPosSeconds + (firstFramePTSSeconds - anchorClockSeconds)
  }

  /// "Now" on the capture session's own master clock — the clock the
  /// sample-buffer PTS live on. Falls back to the host clock only if
  /// the session has no master clock of its own.
  private func sessionNowLocked() -> CMTime {
    CMClockGetTime(session.masterClock ?? CMClockGetHostTimeClock())
  }

  /// PROVISIONAL measurement, taken in the first frame's callback:
  /// an anchor pair — the item's current position and session-clock
  /// now; the frame's song position is the item position shifted by
  /// (framePTS − now). This pair is sampled milliseconds after
  /// play(), when the item may not be advancing yet (see
  /// anchoredSongPosition), so beginFinishLocked OVERRIDES it with
  /// the late anchor whenever that is available; it remains the
  /// fallback when it is not. Only used when the item is actually
  /// playing (rate ≠ 0); a paused/failed player yields nil — the
  /// position is never fabricated.
  private func measureFirstFrameLocked(pts: CMTime) {
    guard let item = songItem else {
      firstFrameSongPosition = nil
      return
    }
    guard let player = songPlayer, player.rate != 0 else {
      firstFrameSongPosition = nil
      return
    }
    let itemNow = item.currentTime()
    guard itemNow.isValid, itemNow.isNumeric else {
      firstFrameSongPosition = nil
      return
    }
    let now = sessionNowLocked()
    let position = Self.anchoredSongPosition(
      anchorPosSeconds: CMTimeGetSeconds(itemNow),
      anchorClockSeconds: CMTimeGetSeconds(now),
      firstFramePTSSeconds: CMTimeGetSeconds(pts)
    )
    firstFrameSongPosition = position.isFinite ? position : nil
  }

  /// THE authoritative measurement, sampled at finish — before the
  /// player pauses — once playback is provably advancing. Projects
  /// the item's current position back to the first frame's PTS on
  /// the session clock and overrides the provisional first-frame
  /// value. Silently keeps the fallback whenever the late anchor is
  /// unavailable: no song/item, no first frame yet, the player not
  /// playing (item ended or paused early — e.g. the song is shorter
  /// than the take, where the clamped end position would corrupt
  /// the projection), or the item never advanced past the seek
  /// target (preroll never completed, so there is nothing honest
  /// to project from).
  private func refineSongPositionAtFinishLocked() {
    guard
      let item = songItem,
      let player = songPlayer,
      let firstPTS = firstVideoPTS
    else { return }
    // Primary gate: the player reports itself playing.
    // timeControlStatus lags on some OS versions, so a non-zero rate
    // also counts — the advance check below is the real proof.
    guard player.timeControlStatus == .playing || player.rate != 0 else { return }
    let itemNow = item.currentTime()
    guard itemNow.isValid, itemNow.isNumeric else { return }
    let itemSeconds = CMTimeGetSeconds(itemNow)
    // The item must have genuinely advanced beyond the seek target —
    // a position still clamped AT the target is the preroll
    // signature this refinement exists to escape.
    guard itemSeconds.isFinite, itemSeconds > songSeekStartSeconds else { return }
    // If the item has reached (or passed) its own end it may have
    // stopped advancing while the clock ran on — a projection from a
    // clamped end position would be just as wrong as the preroll.
    let itemDuration = item.duration
    if itemDuration.isValid, itemDuration.isNumeric {
      let durationSeconds = CMTimeGetSeconds(itemDuration)
      if durationSeconds.isFinite, itemSeconds >= durationSeconds - 0.05 {
        return
      }
    }
    let now = sessionNowLocked()
    let candidate = Self.anchoredSongPosition(
      anchorPosSeconds: itemSeconds,
      anchorClockSeconds: CMTimeGetSeconds(now),
      firstFramePTSSeconds: CMTimeGetSeconds(firstPTS)
    )
    if candidate.isFinite {
      firstFrameSongPosition = candidate
    }
  }

  // MARK: Writer plumbing (queue only, driven by the delegates)

  /// Creates a video writer input inside avTry: the initialiser
  /// validates the settings against the sourceFormatHint and can
  /// raise an NSException (see the ban-list note in
  /// startWriterLocked) — a raise reads as nil here, so the caller
  /// can fall back or abort the take cleanly, never the process.
  private func makeVideoWriterInput(
    settings: [String: Any],
    formatDescription: CMFormatDescription
  ) -> AVAssetWriterInput? {
    var created: AVAssetWriterInput?
    avTry {
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: settings,
        sourceFormatHint: formatDescription
      )
      input.expectsMediaDataInRealTime = true
      created = input
    }
    return created
  }

  /// Creates the writer inputs from the first video buffer's own
  /// format description (post-rotation dimensions — ground truth,
  /// not a guess from the device format), starts the writer session
  /// at that frame's PTS (the file timeline begins at the first
  /// frame), measures the first frame, and resolves startCapture:
  /// capture is now actually rolling.
  private func startWriterLocked(firstVideoBuffer: CMSampleBuffer, pts: CMTime) -> Bool {
    guard
      let writer,
      let formatDescription = CMSampleBufferGetFormatDescription(firstVideoBuffer)
    else {
      abortCaptureLocked(error: compositorError("The video stream had no format description."))
      return false
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
    let pixelCount = Double(dimensions.width) * Double(dimensions.height)
    // Bitrate: the tuned "Balanced" table (see
    // CaptureQuality.writerVideoBitrate) — 8/14/30 Mbps by delivered
    // size × cadence, derived from THIS buffer's dimensions and the
    // configured frame rate, never from the requested quality alone.
    let targetBitRate = CaptureQuality.writerVideoBitrate(
      pixelCount: pixelCount,
      framesPerSecond: activeFramesPerSecond
    )
    // Deliberately NO AVVideoExpectedSourceFrameRateKey in either
    // settings dict below: with a sourceFormatHint attached,
    // AVAssetWriterInput's initialiser validates the settings and
    // THREW an uncaught NSException on device the moment record was
    // pressed (crash log MVMTStudio-2026-11-09-213806). It was only
    // an encoder hint — the real cadence lives in the sample
    // timestamps. Input creation goes through makeVideoWriterInput
    // (avTry): whatever the initialiser validates, a rejection falls
    // back or aborts this take cleanly, never the process.
    //
    // HEVC first (Balanced update): the same settings shape as the
    // proven H.264 path minus the profile-level key — optional for
    // HEVC, and a wrong constant is exactly the kind of thing the
    // initialiser validates-and-throws over. ANY failure (exception,
    // nil, the writer refusing the input) falls back to the legacy
    // H.264 settings — the bpp formula (≈0.16 bpp at 1080p, ≈0.09
    // above four megapixels) that recorded every take before this
    // update — so a device that can't encode HEVC in this pipeline
    // records exactly as it always has.
    let hevcSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: Int(dimensions.width),
      AVVideoHeightKey: Int(dimensions.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: targetBitRate
      ],
    ]
    var createdVideoInput = makeVideoWriterInput(
      settings: hevcSettings,
      formatDescription: formatDescription
    )
    if let input = createdVideoInput, !writer.canAdd(input) {
      createdVideoInput = nil
    }
    if createdVideoInput == nil {
      let bitsPerPixel = pixelCount > 4_000_000 ? 0.09 : 0.16
      let legacyBitRate = Int(pixelCount * activeFramesPerSecond * bitsPerPixel)
      let h264Settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(dimensions.width),
        AVVideoHeightKey: Int(dimensions.height),
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: legacyBitRate,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
      ]
      createdVideoInput = makeVideoWriterInput(
        settings: h264Settings,
        formatDescription: formatDescription
      )
      if let input = createdVideoInput, !writer.canAdd(input) {
        createdVideoInput = nil
      }
    }
    guard let videoInput = createdVideoInput else {
      abortCaptureLocked(error: compositorError("The video writer input could not be created."))
      return false
    }
    writer.add(videoInput)
    videoWriterInput = videoInput

    if let audioFormat = pendingAudioFormat {
      addAudioInputLocked(formatDescription: audioFormat)
    }

    guard writer.startWriting() else {
      abortCaptureLocked(
        error: writer.error
          ?? compositorError("The writer could not start.")
      )
      return false
    }
    writer.startSession(atSourceTime: pts)
    writerStarted = true
    firstVideoPTS = pts
    measureFirstFrameLocked(pts: pts)

    startTimeoutItem?.cancel()
    startTimeoutItem = nil
    startContinuation?.resume()
    startContinuation = nil
    return true
  }

  private func addAudioInputLocked(formatDescription: CMFormatDescription) {
    guard audioWriterInput == nil, let writer else { return }
    var sampleRate = 44100.0
    var channels = 1
    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
      if asbd.pointee.mSampleRate > 0 {
        sampleRate = asbd.pointee.mSampleRate
      }
      channels = max(1, Int(asbd.pointee.mChannelsPerFrame))
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channels,
      AVEncoderBitRateKey: 128_000,
    ]
    // Guarded like the video input above (avTry): if this
    // initialiser raises, createdInput stays nil and the take
    // degrades to video-only instead of aborting the app.
    var createdInput: AVAssetWriterInput?
    avTry {
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: settings,
        sourceFormatHint: formatDescription
      )
      input.expectsMediaDataInRealTime = true
      createdInput = input
    }
    if let input = createdInput, writer.canAdd(input) {
      writer.add(input)
      audioWriterInput = input
    }
    // If the writer refuses the input the take is video-only; the
    // file-based sync fallback then reports noSongInMic, honestly.
  }

  private func handleVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard state == .recording else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if !writerStarted {
      guard startWriterLocked(firstVideoBuffer: sampleBuffer, pts: pts) else { return }
    }
    // Native max-duration safety stop.
    if let first = firstVideoPTS, maxDurationSeconds > 0 {
      let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, first))
      if elapsed.isFinite, elapsed >= maxDurationSeconds {
        beginFinishLocked()
        return
      }
    }
    guard let input = videoWriterInput, input.isReadyForMoreMediaData else { return }
    if !input.append(sampleBuffer) {
      // A failed append mid-recording: finish now and keep the
      // partial file rather than losing the take.
      beginFinishLocked()
    }
  }

  private func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard state == .recording else { return }
    if !writerStarted {
      // Remember the format so the audio input can be created when
      // the writer starts; the samples themselves precede the first
      // frame and are dropped by design.
      if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
        pendingAudioFormat = format
      }
      return
    }
    guard let first = firstVideoPTS else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard CMTimeCompare(pts, first) >= 0 else { return }
    if audioWriterInput == nil,
      let format = CMSampleBufferGetFormatDescription(sampleBuffer)
    {
      addAudioInputLocked(formatDescription: format)
    }
    guard let input = audioWriterInput, input.isReadyForMoreMediaData else { return }
    input.append(sampleBuffer)
  }

  // MARK: Sample buffer delegates (callbacks arrive on `sampleBufferQueue`)

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    // The ONLY work done on the delegate queue is this hop: buffer
    // handling runs on the control queue exactly as it always has
    // (the handlers read/write coordinator state directly), just no
    // longer ON the session's delivery path. Both outputs share the
    // one serial delegate queue and hop onto the one serial control
    // queue, so buffers are handled in arrival order.
    queue.async { [weak self] in
      guard let self else { return }
      if output === self.videoOutput {
        self.handleVideoBuffer(sampleBuffer)
      } else if output === self.audioOutput {
        self.handleAudioBuffer(sampleBuffer)
      }
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    // Dropped frames are the system's call under load; nothing to do.
  }

  // MARK: Finishing

  private func beginFinishLocked() {
    guard state == .recording || state == .preparing else { return }
    state = .finishing
    startTimeoutItem?.cancel()
    startTimeoutItem = nil
    seekArmItem?.cancel()
    seekArmItem = nil
    tearDownSongStatusObservationLocked()
    // Authoritative sync measurement BEFORE the song player pauses:
    // re-anchor the first-frame position from the provably-advancing
    // player (see refineSongPositionAtFinishLocked).
    refineSongPositionAtFinishLocked()
    songPlayer?.pause()
    if session.isRunning {
      session.stopRunning()
    }

    guard let writer, let url = outputURL, writerStarted else {
      // Stopped (or auto-stopped) before the first frame: nothing
      // usable exists. Reject a still-pending start promise too.
      if let continuation = startContinuation {
        startContinuation = nil
        continuation.resume(
          throwing: compositorError("The capture was stopped before recording started.")
        )
      }
      writer?.cancelWriting()
      if let url = outputURL {
        try? FileManager.default.removeItem(at: url)
      }
      completeFinishLocked(
        result: nil,
        error: compositorError("No frames were captured.")
      )
      return
    }

    let firstFrameSnapshot = firstFrameSongPosition
    videoWriterInput?.markAsFinished()
    audioWriterInput?.markAsFinished()
    writer.finishWriting { [weak self] in
      guard let self else { return }
      Task {
        let outcome = await self.measureCaptureOutcome(
          url: url,
          firstFrameSongPosition: firstFrameSnapshot
        )
        self.queue.async {
          if let record = outcome.record {
            self.completeFinishLocked(result: record, error: nil)
          } else {
            self.completeFinishLocked(
              result: nil,
              error: outcome.error
                ?? compositorError("The recorded file could not be read.")
            )
          }
        }
      }
    }
  }

  private func abortCaptureLocked(error: Error) {
    startTimeoutItem?.cancel()
    startTimeoutItem = nil
    seekArmItem?.cancel()
    seekArmItem = nil
    tearDownSongStatusObservationLocked()
    if let continuation = startContinuation {
      startContinuation = nil
      continuation.resume(throwing: error)
    }
    songPlayer?.pause()
    if session.isRunning {
      session.stopRunning()
    }
    writer?.cancelWriting()
    if let url = outputURL {
      try? FileManager.default.removeItem(at: url)
    }
    state = .finished
    finishedResult = nil
    finishedError = error
    let waiters = stopContinuations
    stopContinuations = []
    for waiter in waiters {
      waiter.resume(throwing: error)
    }
    cleanupCaptureLocked()
  }

  private func completeFinishLocked(result: CaptureResultRecord?, error: Error?) {
    state = .finished
    finishedResult = result
    finishedError = error
    let waiters = stopContinuations
    stopContinuations = []
    for waiter in waiters {
      if let result {
        waiter.resume(returning: result)
      } else {
        waiter.resume(
          throwing: error ?? compositorError("The capture failed.")
        )
      }
    }
    cleanupCaptureLocked()
  }

  /// Locks the active device's exposure + white balance for the
  /// take being armed (see beginCaptureLocked). Guarded like every
  /// device-configuration site in this coordinator: lockForConfiguration
  /// + the mode assignments run inside avTry, the device is unlocked
  /// outside the guard, and ANY failure leaves the take unlocked —
  /// an enhancement must never fail a recording.
  private func lockExposureForCaptureLocked() {
    exposureLockedForCapture = false
    guard configuration.lockExposureWhileRecording, let device = videoDevice else { return }
    var deviceLocked = false
    var applied = false
    let exception = avTry {
      do {
        try device.lockForConfiguration()
        deviceLocked = true
        if device.isExposureModeSupported(.locked) {
          device.exposureMode = .locked
          applied = true
        }
        if device.isWhiteBalanceModeSupported(.locked) {
          device.whiteBalanceMode = .locked
          applied = true
        }
      } catch {
        // lockForConfiguration refused — the take proceeds unlocked.
      }
    }
    if deviceLocked {
      device.unlockForConfiguration()
    }
    exposureLockedForCapture = exception == nil && applied
  }

  /// Restores continuous auto exposure / white balance after a take
  /// that held them locked. Same guard discipline as the lock.
  private func restoreExposureLocked() {
    guard exposureLockedForCapture else { return }
    exposureLockedForCapture = false
    guard let device = videoDevice else { return }
    var deviceLocked = false
    avTry {
      do {
        try device.lockForConfiguration()
        deviceLocked = true
        if device.isExposureModeSupported(.continuousAutoExposure) {
          device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
          device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
      } catch {
        // Nothing to restore against a device that won't configure.
      }
    }
    if deviceLocked {
      device.unlockForConfiguration()
    }
  }

  private func cleanupCaptureLocked() {
    // Undo the take's exposure lock first, while the device that was
    // locked is still the configured one.
    restoreExposureLocked()
    // The capture is over (finish and abort both funnel here): idle
    // frames may be discarded late again, so the preview can never
    // backlog the session between takes.
    videoOutput.alwaysDiscardsLateVideoFrames = true
    // Song player teardown, with the pre-warm rules (this is the
    // ONLY place the active player is released — finish and abort
    // both funnel through here):
    // - The finished player IS the standing player (adopted at
    //   prepare, or promoted by an earlier take): the standing slot
    //   already holds it — paused, loaded, warm for the next take.
    // - No competing standing player (none set, or a stale one for
    //   this same song): PROMOTE the finished player to standing —
    //   it just played the song, so it is definitionally warm. This
    //   is what makes takes after the first fast even when
    //   prepareSong was never called.
    // - A DIFFERENT song is already standing (the track changed,
    //   possibly mid-take): the finished player is discarded.
    let finishedPlayer = songPlayer
    let finishedItem = songItem
    let finishedURL = activeSongURL
    songPlayer = nil
    songItem = nil
    activeSongURL = nil
    finishedPlayer?.pause()
    if let finishedPlayer, let finishedItem, let finishedURL,
      finishedPlayer !== warmedPlayer,
      warmedURL == nil || warmedURL == finishedURL
    {
      warmedPlayer = finishedPlayer
      warmedItem = finishedItem
      warmedURL = finishedURL
    }
    writer = nil
    videoWriterInput = nil
    audioWriterInput = nil
    writerStarted = false
    firstVideoPTS = nil
    pendingAudioFormat = nil
    outputURL = nil
    updateSessionRunningLocked()
  }

  /// Measures the finished file (duration, display size, intra-file
  /// A/V offset) — the same facts `inspect` reports, read back from
  /// the written asset so a partially-written file that is still a
  /// valid movie resolves with real values instead of failing.
  private func measureCaptureOutcome(
    url: URL,
    firstFrameSongPosition: Double?
  ) async -> (record: CaptureResultRecord?, error: Error?) {
    let asset = AVURLAsset(url: url)
    do {
      let duration = try await asset.load(.duration)
      let durationSeconds = CMTimeGetSeconds(duration)
      guard durationSeconds.isFinite, durationSeconds > 0 else {
        return (nil, compositorError("The recorded file is empty."))
      }
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard let videoTrack = videoTracks.first else {
        return (nil, compositorError("The recorded file has no video track."))
      }
      let naturalSize = try await videoTrack.load(.naturalSize)
      let preferredTransform = try await videoTrack.load(.preferredTransform)
      let display = naturalSize.applying(preferredTransform)
      let videoTimeRange = try await videoTrack.load(.timeRange)

      var delta: Double?
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      if let audioTrack = audioTracks.first {
        let audioTimeRange = try await audioTrack.load(.timeRange)
        let value =
          CMTimeGetSeconds(audioTimeRange.start) - CMTimeGetSeconds(videoTimeRange.start)
        if value.isFinite {
          delta = value
        }
      }

      let record = CaptureResultRecord()
      record.uri = url.absoluteString
      record.durationSeconds = durationSeconds
      record.width = Int(abs(display.width).rounded())
      record.height = Int(abs(display.height).rounded())
      record.firstFrameSongPositionSeconds = firstFrameSongPosition
      record.intraFileAvOffsetSeconds = delta
      return (record, nil)
    } catch {
      return (nil, error)
    }
  }
}

// MARK: - Capture view (AVCaptureVideoPreviewLayer host)
//
// Binds to CaptureCoordinator's ONE session: the preview IS the
// recording surface. Props are the current capture configuration —
// startCapture uses whatever the view most recently set.

public final class MvmtCaptureView: ExpoView {
  private let previewLayer = AVCaptureVideoPreviewLayer()

  var facing: String = "back" {
    didSet {
      CaptureCoordinator.shared.setFacing(facing == "front" ? .front : .back)
    }
  }

  var torch: Bool = false {
    didSet {
      CaptureCoordinator.shared.setTorch(torch)
    }
  }

  /// Expo-style zoom 0..1 (the coordinator maps it to a device factor).
  var zoom: Double = 0 {
    didSet {
      CaptureCoordinator.shared.setZoom(zoom)
    }
  }

  var mirrored: Bool = false {
    didSet {
      CaptureCoordinator.shared.setMirrored(mirrored)
    }
  }

  /// Keeps the capture session running (preview live) while true.
  var active: Bool = false {
    didSet {
      CaptureCoordinator.shared.setPreviewActive(active, viewID: ObjectIdentifier(self))
    }
  }

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = UIColor.black
    clipsToBounds = true
    previewLayer.session = CaptureCoordinator.shared.session
    previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
    layer.addSublayer(previewLayer)
    CaptureCoordinator.shared.registerPreviewLayer(previewLayer)
  }

  deinit {
    CaptureCoordinator.shared.setPreviewActive(false, viewID: ObjectIdentifier(self))
    CaptureCoordinator.shared.unregisterPreviewLayer(previewLayer)
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    previewLayer.frame = bounds
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    // If the `active` prop landed before the view was in a window,
    // re-assert it now so the session starts — the camera must be
    // live the moment the Record screen is on screen.
    if window != nil, active {
      CaptureCoordinator.shared.setPreviewActive(true, viewID: ObjectIdentifier(self))
    }
  }
}

// MARK: - Module definition

public class MvmtCompositorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("MvmtCompositor")

    Events("onExportProgress", "onPreviewProgress", "onPreviewStatus")

    OnCreate {
      // Preview/export events must outlive individual function calls,
      // so the stores emit through this sink (weakly held module).
      PreviewStore.shared.eventSink = { [weak self] name, body in
        self?.sendEvent(name, body)
      }
    }

    AsyncFunction("renderVideo") { (request: CompositeRequestRecord) -> CompositeResultRecord in
      let exportId = request.exportId
      return try await MvmtCompositorEngine.render(request) { progress in
        if let exportId {
          self.sendEvent("onExportProgress", [
            "exportId": exportId,
            "progress": progress,
          ])
        }
      }
    }

    AsyncFunction("cancelExport") { (exportId: String) in
      ExportSessionStore.shared.cancel(exportId)
    }

    AsyncFunction("inspectAsset") { (uri: String) -> AssetInfoRecord in
      try await MvmtCompositorEngine.inspect(uri)
    }

    AsyncFunction("measureTakeSync") { (takeUri: String, songUri: String, expectedSongPositionAtTakeStartSeconds: Double, searchWindowSeconds: Double) -> TakeSyncMeasurementRecord in
      await MvmtCompositorEngine.measureTakeSync(
        takeUri: takeUri,
        songUri: songUri,
        expectedSongPositionAtTakeStartSeconds: expectedSongPositionAtTakeStartSeconds,
        searchWindowSeconds: searchWindowSeconds
      )
    }

    AsyncFunction("waveformPeaks") { (uri: String, buckets: Int) -> WaveformPeaksRecord? in
      await MvmtCompositorEngine.waveformPeaks(uri: uri, buckets: buckets)
    }

    AsyncFunction("prepareEqSong") { (uri: String) -> String in
      await MvmtCompositorEngine.prepareEqSong(uri)
    }

    AsyncFunction("prepareMixMasterSong") { (
      uri: String,
      correctiveEnabled: Bool,
      correctiveIntensity: Double,
      masterEnabled: Bool,
      masterIntensity: Double
    ) -> String in
      await MvmtCompositorEngine.prepareMixMasterSong(
        uri,
        correctiveEnabled: correctiveEnabled,
        correctiveIntensity: correctiveIntensity,
        masterEnabled: masterEnabled,
        masterIntensity: masterIntensity
      )
    }

    AsyncFunction("getMixMasterProfile") { (
      uri: String,
      correctiveEnabled: Bool,
      correctiveIntensity: Double,
      masterEnabled: Bool,
      masterIntensity: Double
    ) -> String? in
      await MvmtCompositorEngine.mixMasterProfile(
        uri,
        correctiveEnabled: correctiveEnabled,
        correctiveIntensity: correctiveIntensity,
        masterEnabled: masterEnabled,
        masterIntensity: masterIntensity
      )
    }

    AsyncFunction("exportMixMasterAac") { (sourceUri: String, destinationUri: String) -> String? in
      await MvmtCompositorEngine.exportMixMasterAac(
        sourceUri: sourceUri,
        destinationUri: destinationUri
      )
    }

    Function("isCaptureAvailable") { () -> Bool in
      CaptureCoordinator.shared.isAvailable
    }

    AsyncFunction("startCapture") { (args: CaptureStartArgsRecord) in
      try await CaptureCoordinator.shared.start(args)
    }

    AsyncFunction("stopCapture") { () -> CaptureResultRecord in
      try await CaptureCoordinator.shared.stop()
    }

    AsyncFunction("prepareSong") { (songUri: String?) in
      await CaptureCoordinator.shared.prepareSong(songUri: songUri)
    }

    AsyncFunction("setCaptureQuality") { (quality: String) in
      await CaptureCoordinator.shared.setQuality(quality)
    }

    AsyncFunction("setCaptureStabilization") { (enabled: Bool) in
      await CaptureCoordinator.shared.setStabilization(enabled)
    }

    AsyncFunction("setCaptureExposureLock") { (enabled: Bool) in
      await CaptureCoordinator.shared.setExposureLock(enabled)
    }

    AsyncFunction("createPreview") { (request: CompositeRequestRecord) -> String in
      try await PreviewStore.shared.create(request: request)
    }

    AsyncFunction("setPreviewPaused") { (previewId: String, paused: Bool) in
      try await MainActor.run {
        try PreviewStore.shared.setPaused(previewId: previewId, paused: paused)
      }
    }

    AsyncFunction("seekPreview") { (previewId: String, seconds: Double) in
      try await MainActor.run {
        try PreviewStore.shared.seek(previewId: previewId, seconds: seconds)
      }
    }

    AsyncFunction("releasePreview") { (previewId: String) in
      await MainActor.run {
        PreviewStore.shared.release(previewId: previewId)
      }
    }

    // ---- Extra Styles 2.0 (docs/EXTRA-STYLES-2.0.md §6.6) ----
    // The scene engine's bridge surface. Scene data crosses once
    // at preparation; per-frame evaluation is native-only. The
    // throwing functions reject on failure (the TS wrappers turn
    // that into null/false); the nullable ones return null instead.
    AsyncFunction("getExtraStyleCatalog") { () -> String in
      ExtraStylesEngine.catalogJSON()
    }

    AsyncFunction("prepareExtraStyleScene") { (input: ExtraStyleSceneBuildInputRecord) -> String in
      try ExtraStylesEngine.prepareScene(input)
    }

    AsyncFunction("updateExtraStyleParams") { (handle: String, paramsJson: String) in
      try ExtraStylesEngine.updateParams(handle: handle, paramsJson: paramsJson)
    }

    AsyncFunction("prepareAudioAutomation") { (uri: String) -> String? in
      await ExtraStylesAudio.prepareAutomation(uri: uri)
    }

    AsyncFunction("prepareSubjectMasks") { (takeUri: String) -> String? in
      await ExtraStylesMasks.prepareMasks(takeUri: takeUri)
    }

    AsyncFunction("renderExtraStylePreviewFrame") { (handle: String, frame: Int, width: Double, height: Double) -> String? in
      ExtraStylesEngine.renderPreviewFrame(handle: handle, frame: frame, width: width, height: height)
    }

    AsyncFunction("renderExtraStylePreviewClip") { (handle: String, width: Double, height: Double, videoUri: String, durationSeconds: Double, fps: Double) -> String? in
      await ExtraStylesEngine.renderPreviewClip(
        handle: handle, width: width, height: height,
        videoUri: videoUri, durationSeconds: durationSeconds, fps: fps
      )
    }

    AsyncFunction("releaseExtraStyleScene") { (handle: String) in
      ExtraStylesEngine.releaseScene(handle: handle)
    }

    AsyncFunction("getExtraStyleProfile") { () -> String in
      ExtraStyleProfiler.shared.snapshotJSON()
    }

    AsyncFunction("benchmarkExtraStyleNodes") { () -> String in
      ExtraStylesMetalSpike.benchmarkJSON()
    }

    View(MvmtPreviewView.self) {
      ViewName("MvmtPreviewView")
      Prop("previewId") { (view: MvmtPreviewView, previewId: String?) in
        view.previewId = previewId
      }
    }

    View(MvmtCaptureView.self) {
      ViewName("MvmtCaptureView")
      Prop("facing") { (view: MvmtCaptureView, facing: String?) in
        view.facing = facing ?? "back"
      }
      Prop("torch") { (view: MvmtCaptureView, torch: Bool?) in
        view.torch = torch ?? false
      }
      Prop("zoom") { (view: MvmtCaptureView, zoom: Double?) in
        view.zoom = zoom ?? 0
      }
      Prop("mirrored") { (view: MvmtCaptureView, mirrored: Bool?) in
        view.mirrored = mirrored ?? false
      }
      Prop("active") { (view: MvmtCaptureView, active: Bool?) in
        view.active = active ?? false
      }
    }
  }
}
