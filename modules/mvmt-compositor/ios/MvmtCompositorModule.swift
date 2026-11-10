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

// MARK: - Shared composition builder output

private struct BuiltComposition {
  let composition: AVMutableComposition
  let videoComposition: AVMutableVideoComposition
  let audioMix: AVMutableAudioMix?
  let duration: CMTime
}

// MARK: - Engine (AVFoundation)
//
// ONE builder — buildComposition — powers BOTH export (render) and
// native preview (PreviewStore.create), so what you preview is what
// renders. Nothing else in the app builds compositions. ONE carve-out:
// the watermark animation tool is attached for EXPORT builds only
// (the forExport flag) — assigning a videoComposition that carries an
// animation tool to a preview player item throws on device
// (crash log MVMTStudio-2026-11-09-220942); the app overlays the logo
// in previews at the JS layer instead.

private enum MvmtCompositorEngine {
  /// File paths may arrive as `file://` URIs or plain paths.
  static func resolveURL(_ raw: String) -> URL {
    if raw.hasPrefix("/") {
      return URL(fileURLWithPath: raw)
    }
    return URL(string: raw) ?? URL(fileURLWithPath: raw)
  }

  // MARK: Shared builder

  static func buildComposition(_ request: CompositeRequestRecord, forExport: Bool) async throws -> BuiltComposition {
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

      try insertTimeRangeGuarded(
        into: compositionVideoTrack, range, of: sourceVideoTrack, at: cursor,
        "Clip \(index + 1)'s video could not be added to the composition"
      )

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
      segmentRanges.append(CMTimeRange(start: cursor, duration: range.duration))
      segmentTransforms.append(transform)

      // Clip's own audio, only when wanted (the app mutes takes by
      // default — song-only is the product default).
      if !clip.muted, clip.volume > 0 {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let sourceAudioTrack = audioTracks.first {
          let targetTrack = try clipAudioTrack()
          try insertTimeRangeGuarded(
            into: targetTrack, range, of: sourceAudioTrack, at: cursor,
            "Clip \(index + 1)'s audio could not be added to the composition"
          )
          if clipAudioMixParameters == nil {
            clipAudioMixParameters = AVMutableAudioMixInputParameters(track: targetTrack)
          }
          // Volume keyframe at this segment's start; held until the next
          // audible segment sets its own.
          clipAudioMixParameters?.setVolume(Float(max(0, min(1, clip.volume))), at: cursor)
        }
      }

      cursor = CMTimeAdd(cursor, range.duration)
    }

    let totalDuration = cursor

    // ---- Master audio track over the whole cut (inserted once) ----
    var audioMixParameters: [AVMutableAudioMixInputParameters] = []
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
        let parameters = AVMutableAudioMixInputParameters(track: targetTrack)
        parameters.setVolume(Float(max(0, min(1, request.audioVolume))), at: .zero)
        audioMixParameters.append(parameters)
      }
    }

    // ---- Video composition: per-segment layer instructions carrying
    // the normalised canvas transforms ----
    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = canvasSize
    // The render grid is exactly the request's frame rate (the EDL's
    // 30fps grid) — the verified composition shape. (Round 3 sampled
    // at max(frameRate, 60); reverted with the Edit-screen crash fix.)
    videoComposition.frameDuration = CMTime(seconds: 1.0 / frameRate, preferredTimescale: timescale)
    videoComposition.instructions = segmentRanges.enumerated().map { index, range in
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = range
      let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
      layerInstruction.setTransform(segmentTransforms[index], at: range.start)
      instruction.layerInstructions = [layerInstruction]
      return instruction
    }

    var audioMix: AVMutableAudioMix?
    if !audioMixParameters.isEmpty {
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
    // must never fail over branding.
    if forExport,
      request.watermarkEnabled == true,
      let watermarkUri = request.watermarkImageUri, !watermarkUri.isEmpty,
      let tool = makeWatermarkAnimationTool(
        imageURL: resolveURL(watermarkUri),
        renderSize: canvasSize,
        durationSeconds: CMTimeGetSeconds(totalDuration)
      )
    {
      videoComposition.animationTool = tool
    }

    return BuiltComposition(
      composition: composition,
      videoComposition: videoComposition,
      audioMix: audioMix,
      duration: totalDuration
    )
  }

  /// Builds the watermark CoreAnimation tool: a parent layer holding
  /// the full-frame video layer plus the logo layer above it. The
  /// logo (27% of the render width, aspect preserved, 85% opacity)
  /// starts in the TOP-LEFT corner and flips to the BOTTOM-RIGHT
  /// every 5 seconds for the whole composition — discrete keyframes,
  /// so it teleports rather than sliding. CALayer coordinates are
  /// bottom-left origin, so "top-left" means y near the frame's top.
  /// Returns nil when the image cannot be loaded or the geometry is
  /// unusable — callers treat nil as "render without a watermark".
  private static func makeWatermarkAnimationTool(
    imageURL: URL,
    renderSize: CGSize,
    durationSeconds: Double
  ) -> AVVideoCompositionCoreAnimationTool? {
    guard
      renderSize.width > 0, renderSize.height > 0,
      durationSeconds.isFinite, durationSeconds > 0,
      let image = UIImage(contentsOfFile: imageURL.path),
      let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0
    else {
      return nil
    }

    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: renderSize)
    let videoLayer = CALayer()
    videoLayer.frame = parentLayer.bounds
    parentLayer.addSublayer(videoLayer)

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

    return AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: videoLayer,
      in: parentLayer
    )
  }

  // MARK: Export

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

    let progressTask: Task<Void, Never>? = (exportId != nil && onProgress != nil)
      ? Task {
          while !Task.isCancelled {
            let status = exporter.status
            if status != .waiting && status != .exporting {
              break
            }
            onProgress?(Double(exporter.progress))
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
      onProgress?(1.0)
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
    let outputDisplay = outputNaturalSize.applying(outputTransform)

    let result = CompositeResultRecord()
    result.uri = outputURL.absoluteString
    let measuredSeconds = CMTimeGetSeconds(measuredDuration)
    result.durationSeconds = measuredSeconds.isFinite ? measuredSeconds : 0
    result.width = Int(abs(outputDisplay.width).rounded())
    result.height = Int(abs(outputDisplay.height).rounded())
    return result
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
    let window: Double
    if searchWindowSeconds.isFinite {
      window = min(max(searchWindowSeconds, 0.25), 10)
    } else {
      window = 2
    }
    let expected = expectedSongPositionAtTakeStartSeconds

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
        needle: takeEnvelope,
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

    entry.statusObservation = entry.item.observe(\.status, options: [.new]) { [weak self, weak entry] item, _ in
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
}

private struct CaptureConfiguration {
  var facing: AVCaptureDevice.Position = .back
  var torch: Bool = false
  /// Expo-style zoom 0..1 (mapped to a device factor when applied).
  var zoom: Double = 0
  var mirrored: Bool = false
  var quality: CaptureQuality = .p1080at30
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
        }
      }
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
      songStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
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
    // Bitrate follows pixel throughput at the active frame rate:
    // ≈0.16 bits per pixel at 1080p (≈10 Mbps at 30fps — the proven
    // figure — and ≈20 Mbps at 60fps), easing to ≈0.09 above four
    // megapixels, where frames compress more efficiently per pixel
    // (≈45 Mbps at 4K60). Derived from THIS buffer's dimensions and
    // the configured cadence, never hardcoded per quality.
    let pixelCount = Double(dimensions.width) * Double(dimensions.height)
    let bitsPerPixel = pixelCount > 4_000_000 ? 0.09 : 0.16
    let averageBitRate = Int(pixelCount * activeFramesPerSecond * bitsPerPixel)
    var videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(dimensions.width),
      AVVideoHeightKey: Int(dimensions.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: averageBitRate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
    // Deliberately NO AVVideoExpectedSourceFrameRateKey here: with a
    // sourceFormatHint attached, AVAssetWriterInput's initialiser
    // validates the settings and THREW an uncaught NSException on
    // device the moment record was pressed (crash log
    // MVMTStudio-2026-11-09-213806). It was only an encoder hint —
    // the real cadence lives in the sample timestamps. The settings
    // below are exactly the shape that recorded fine in every
    // pre-60fps build. The initialiser is ALSO wrapped in avTry now:
    // whatever it validates, a rejection must abort this take
    // cleanly (the app's notice path), never the process.
    var createdVideoInput: AVAssetWriterInput?
    if let exception = avTry({
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: videoSettings,
        sourceFormatHint: formatDescription
      )
      input.expectsMediaDataInRealTime = true
      createdVideoInput = input
    }) {
      abortCaptureLocked(error: exceptionError("The video writer input was rejected", exception))
      return false
    }
    guard let videoInput = createdVideoInput else {
      abortCaptureLocked(error: compositorError("The video writer input could not be created."))
      return false
    }
    guard writer.canAdd(videoInput) else {
      abortCaptureLocked(error: compositorError("The writer rejected the video input."))
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

  private func cleanupCaptureLocked() {
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
