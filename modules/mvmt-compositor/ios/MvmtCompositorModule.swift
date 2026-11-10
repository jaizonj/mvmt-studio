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
// native preview (PreviewStore.create), so what you preview is exactly
// what renders. Nothing else in the app builds compositions.

private enum MvmtCompositorEngine {
  /// File paths may arrive as `file://` URIs or plain paths.
  static func resolveURL(_ raw: String) -> URL {
    if raw.hasPrefix("/") {
      return URL(fileURLWithPath: raw)
    }
    return URL(string: raw) ?? URL(fileURLWithPath: raw)
  }

  // MARK: Shared builder

  static func buildComposition(_ request: CompositeRequestRecord) async throws -> BuiltComposition {
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
    // Render grid: at least 60fps (Jaizon: capture defaults to 60fps,
    // renders should keep every captured frame). The EDL's 30fps cut
    // times are CMTime values — they land on the same instants on the
    // finer grid (30 divides 60), so this changes only the sampling
    // cadence, never the edit.
    let renderFrameRate = max(frameRate, 60)

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

      try compositionVideoTrack.insertTimeRange(range, of: sourceVideoTrack, at: cursor)

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
          try targetTrack.insertTimeRange(range, of: sourceAudioTrack, at: cursor)
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
        try targetTrack.insertTimeRange(
          CMTimeRange(start: start, duration: length),
          of: sourceMasterTrack,
          at: .zero
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
    videoComposition.frameDuration = CMTime(seconds: 1.0 / renderFrameRate, preferredTimescale: timescale)
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

    // ---- Optional watermark: the logo lockup flipping between the
    // top-left and bottom-right corners every 5 seconds. It rides on
    // THIS videoComposition — the same object preview assigns to its
    // player item and export assigns to its session — so the preview
    // shows exactly what renders. A missing/unloadable image degrades
    // to no watermark: a render must never fail over branding.
    if request.watermarkEnabled == true,
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
    let built = try await buildComposition(request)

    guard
      let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else {
      throw compositorError("Could not locate the caches directory.")
    }
    let outputURL = cachesDirectory.appendingPathComponent("mvmt-export-\(UUID().uuidString).mp4")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }

    guard
      let exporter = AVAssetExportSession(
        asset: built.composition,
        presetName: AVAssetExportPresetHighestQuality
      )
    else {
      throw compositorError("Could not create the export session.")
    }
    exporter.outputURL = outputURL
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = false
    exporter.videoComposition = built.videoComposition
    if let audioMix = built.audioMix {
      exporter.audioMix = audioMix
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
    let built = try await MvmtCompositorEngine.buildComposition(request)
    let durationSeconds = CMTimeGetSeconds(built.duration)
    let previewId = await MainActor.run { () -> String in
      let item = AVPlayerItem(asset: built.composition)
      item.videoComposition = built.videoComposition
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

private struct CaptureConfiguration {
  var facing: AVCaptureDevice.Position = .back
  var torch: Bool = false
  /// Expo-style zoom 0..1 (mapped to a device factor when applied).
  var zoom: Double = 0
  var mirrored: Bool = false
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
  /// handling and writer appends (delegate callbacks land here too),
  /// so no capture state needs locks.
  private let queue = DispatchQueue(label: "au.mvmtstudio.capture")

  // MARK: Configuration (set via the preview view's props)

  private var configuration = CaptureConfiguration()
  private var outputsConfigured = false
  private var sessionConfigured = false
  /// True when the active device was switched to a 60fps format by
  /// configureSessionLocked (the capture default — see
  /// applySixtyFpsFormatLocked). Read by the writer plumbing to tag
  /// the video input's expected source frame rate.
  private var captureIsSixtyFps = false
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

  /// The device's best 60fps format (capture defaults to 60fps —
  /// Jaizon): exact 1920×1080 with a frame-rate range covering 60
  /// wins outright; otherwise the largest format at or under 1080p
  /// whose ranges cover 60. Nil when the device cannot do 60 at all —
  /// the caller then leaves the session-preset behaviour untouched.
  private static func bestSixtyFpsFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
    func coversSixty(_ format: AVCaptureDevice.Format) -> Bool {
      format.videoSupportedFrameRateRanges.contains { range in
        range.minFrameRate <= 60 && range.maxFrameRate >= 59.9
      }
    }
    var best: AVCaptureDevice.Format?
    var bestArea: Int64 = -1
    for format in device.formats where coversSixty(format) {
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      guard dims.width > 0, dims.height > 0 else { continue }
      if dims.width == 1920, dims.height == 1080 {
        return format
      }
      let area = Int64(dims.width) * Int64(dims.height)
      if dims.width <= 1920, dims.height <= 1080, area > bestArea {
        best = format
        bestArea = area
      }
    }
    return best
  }

  /// Switches the just-connected device to its 60fps format and pins
  /// its frame duration to exactly 1/60. Called from the input-swap
  /// block in configureSessionLocked, so each camera (front included)
  /// gets its OWN device's format when the facing flips. Re-applying
  /// to an already-configured device is a no-op — resetting the
  /// active format mid-stream would glitch the running preview.
  private func applySixtyFpsFormatLocked(to device: AVCaptureDevice) {
    captureIsSixtyFps = false
    guard let format = Self.bestSixtyFpsFormat(for: device) else { return }
    let frameDuration = CMTime(value: 1, timescale: 60)
    let targetDims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    let currentDims = CMVideoFormatDescriptionGetDimensions(
      device.activeFormat.formatDescription
    )
    let alreadySixty =
      currentDims.width == targetDims.width && currentDims.height == targetDims.height
      && CMTimeCompare(device.activeVideoMinFrameDuration, frameDuration) == 0
      && CMTimeCompare(device.activeVideoMaxFrameDuration, frameDuration) == 0
    if alreadySixty {
      // Re-assert inputPriority in case another configure pass moved
      // the preset — the device's format is the source of truth.
      session.sessionPreset = .inputPriority
      captureIsSixtyFps = true
      return
    }
    // ORDER IS LOAD-BEARING: the session preset must be
    // .inputPriority BEFORE activeFormat is assigned. Setting
    // activeFormat on a device that is an input to a session
    // running a dimensional preset throws NSInvalidArgumentException
    // — the launch crash on the first build that touched
    // activeFormat (the input is added to the session before this
    // runs, and the session was steering by preset until now).
    session.sessionPreset = .inputPriority
    do {
      try device.lockForConfiguration()
      device.activeFormat = format
      device.activeVideoMinFrameDuration = frameDuration
      device.activeVideoMaxFrameDuration = frameDuration
      device.unlockForConfiguration()
      captureIsSixtyFps = true
    } catch {
      // Leave the preset defaults — capture still works, just at
      // whatever format the session preset picks.
      captureIsSixtyFps = false
    }
  }

  /// (Re)builds inputs/outputs to match `configuration`. Idempotent;
  /// safe to call whenever the session is stopped or running (but not
  /// mid-capture — callers guard that).
  private func configureSessionLocked() throws {
    if !outputsConfigured {
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      ]
      // Real-time recorder: process every frame the sensor delivers
      // rather than silently discarding late ones (a dropped frame is
      // a timing hole in the take).
      videoOutput.alwaysDiscardsLateVideoFrames = false
      videoOutput.setSampleBufferDelegate(self, queue: queue)
      audioOutput.setSampleBufferDelegate(self, queue: queue)
      outputsConfigured = true
    }

    session.beginConfiguration()
    // The app (expo-audio) owns the audio session category.
    session.automaticallyConfiguresApplicationAudioSession = false
    // Once a device has been switched to a 60fps format the session
    // preset is .inputPriority (set by applySixtyFpsFormatLocked) —
    // re-assigning a dimensional preset here could make the session
    // re-pick the input's (30fps) format at commit time and silently
    // undo the 60fps default, so the preset is only steered while no
    // 60fps format is in force.
    if !captureIsSixtyFps {
      if session.canSetSessionPreset(.hd1920x1080) {
        session.sessionPreset = .hd1920x1080
      } else if session.canSetSessionPreset(.high) {
        session.sessionPreset = .high
      }
    }

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
            applySixtyFpsFormatLocked(to: device)
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
    // captureIsSixtyFps is deliberately NOT cleared here: after a
    // plain runtime error the device keeps its 60fps format, and
    // after a reset the reconfigure re-derives the flag via
    // applySixtyFpsFormatLocked when the inputs are rebuilt.
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
      if standing !== songPlayer {
        standing.preroll(atRate: 0, completionHandler: nil)
      }
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
    // Load + preroll PAUSED at rate 0: the item becomes
    // ready-to-play without ever starting playback, and the audio
    // session category is never touched (the app owns it).
    player.preroll(atRate: 0, completionHandler: nil)
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
    do {
      writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    } catch {
      state = .idle
      continuation.resume(throwing: error)
      return
    }

    state = .preparing
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
  /// is the song clock for the whole capture). Capture "arms"
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
    item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        guard self.state == .preparing else { return }
        self.seekArmItem?.cancel()
        self.seekArmItem = nil
        // Play even if the precise seek reports failure (e.g. it was
        // superseded): the first-frame conversion measures wherever
        // the song actually is. Only a FAILED item stays silent.
        if item.status != .failed {
          player.play()
        }
        self.state = .recording
      }
    }
    // If the seek never lands, arm anyway (measurement stays nil)
    // rather than hanging the recording.
    let armTimeout = DispatchWorkItem { [weak self] in
      guard let self, self.state == .preparing else { return }
      self.state = .recording
    }
    seekArmItem = armTimeout
    queue.asyncAfter(deadline: .now() + 5, execute: armTimeout)
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
    var videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(dimensions.width),
      AVVideoHeightKey: Int(dimensions.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 10_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
    if captureIsSixtyFps {
      // Harmless metadata that lets the encoder size its queues for
      // the real cadence when the session is running a 60fps format.
      videoSettings[AVVideoExpectedSourceFrameRateKey] = 60
    }
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: videoSettings,
      sourceFormatHint: formatDescription
    )
    videoInput.expectsMediaDataInRealTime = true
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
    let input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: settings,
      sourceFormatHint: formatDescription
    )
    input.expectsMediaDataInRealTime = true
    if writer.canAdd(input) {
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

  // MARK: Sample buffer delegates (callbacks arrive on `queue`)

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output === videoOutput {
      handleVideoBuffer(sampleBuffer)
    } else if output === audioOutput {
      handleAudioBuffer(sampleBuffer)
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
