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

  /// Output frame rate / composition frameDuration. Default 30.
  @Field
  var frameRate: Double? = nil

  /// Caller-chosen id for onExportProgress events + cancelExport.
  @Field
  var exportId: String? = nil
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

    return BuiltComposition(
      composition: composition,
      videoComposition: videoComposition,
      audioMix: audioMix,
      duration: totalDuration
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
  }
}
