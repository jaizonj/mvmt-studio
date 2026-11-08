import AVFoundation
import ExpoModulesCore
import Foundation

// MARK: - JS <-> Swift records (mirror src/index.ts exactly)

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

// MARK: - Errors

private func compositorError(_ message: String) -> NSError {
  NSError(
    domain: "MvmtCompositor",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: message]
  )
}

// MARK: - Module definition

public class MvmtCompositorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("MvmtCompositor")

    AsyncFunction("renderVideo") { (request: CompositeRequestRecord) -> CompositeResultRecord in
      try await MvmtCompositorEngine.render(request)
    }
  }
}

// MARK: - Engine (AVFoundation)

private enum MvmtCompositorEngine {
  /// File paths may arrive as `file://` URIs or plain paths.
  static func resolveURL(_ raw: String) -> URL {
    if raw.hasPrefix("/") {
      return URL(fileURLWithPath: raw)
    }
    return URL(string: raw) ?? URL(fileURLWithPath: raw)
  }

  static func render(_ request: CompositeRequestRecord) async throws -> CompositeResultRecord {
    let clips = request.clips
    guard !clips.isEmpty else {
      throw compositorError("renderVideo requires at least one clip.")
    }
    for (index, clip) in clips.enumerated() where clip.durationSeconds <= 0 {
      throw compositorError("Clip \(index + 1) has a non-positive duration (\(clip.durationSeconds)s).")
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

    // Lazily created composition audio tracks: one shared by all audible
    // clip segments (they never overlap — the timeline is sequential),
    // and a separate one for the master track (it spans everything).
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
    var canvasDisplaySize = CGSize.zero
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

      let range = CMTimeRange(
        start: CMTime(seconds: max(0, clip.startSeconds), preferredTimescale: timescale),
        duration: CMTime(seconds: clip.durationSeconds, preferredTimescale: timescale)
      )

      try compositionVideoTrack.insertTimeRange(range, of: sourceVideoTrack, at: cursor)

      let naturalSize = try await sourceVideoTrack.load(.naturalSize)
      let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
      segmentRanges.append(CMTimeRange(start: cursor, duration: range.duration))
      segmentTransforms.append(preferredTransform)

      if index == 0 {
        // The FIRST clip defines the canvas: its display size (natural
        // size with its preferredTransform applied).
        let display = naturalSize.applying(preferredTransform)
        canvasDisplaySize = CGSize(width: abs(display.width), height: abs(display.height))
        compositionVideoTrack.preferredTransform = preferredTransform
      }

      // Clip's own audio, when wanted.
      if !clip.muted, clip.volume > 0 {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let sourceAudioTrack = audioTracks.first {
          let targetTrack = try clipAudioTrack()
          try targetTrack.insertTimeRange(range, of: sourceAudioTrack, at: cursor)
          if clipAudioMixParameters == nil {
            clipAudioMixParameters = AVMutableAudioMixInputParameters(track: targetTrack)
          }
          // Volume keyframe at this segment's start; held until the next
          // segment sets its own.
          clipAudioMixParameters?.setVolume(Float(max(0, min(1, clip.volume))), at: cursor)
        }
      }

      cursor = CMTimeAdd(cursor, range.duration)
    }

    let totalDuration = cursor

    // ---- Master audio track over the whole cut ----
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

    // ---- Video composition: per-segment layer instructions so every
    // clip's own preferredTransform is honoured on the shared canvas ----
    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = canvasDisplaySize
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
    videoComposition.instructions = segmentRanges.enumerated().map { index, range in
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = range
      let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
      layerInstruction.setTransform(segmentTransforms[index], at: range.start)
      instruction.layerInstructions = [layerInstruction]
      return instruction
    }

    // ---- Export ----
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
        asset: composition,
        presetName: AVAssetExportPresetHighestQuality
      )
    else {
      throw compositorError("Could not create the export session.")
    }
    exporter.outputURL = outputURL
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = false
    exporter.videoComposition = videoComposition
    if !audioMixParameters.isEmpty {
      let audioMix = AVMutableAudioMix()
      audioMix.inputParameters = audioMixParameters
      exporter.audioMix = audioMix
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      exporter.exportAsynchronously {
        switch exporter.status {
        case .completed:
          continuation.resume()
        case .failed, .cancelled:
          continuation.resume(
            throwing: exporter.error ?? compositorError("The video export failed.")
          )
        default:
          continuation.resume(throwing: compositorError("The video export ended unexpectedly."))
        }
      }
    }

    let durationSeconds = CMTimeGetSeconds(totalDuration)
    // NOTE: @Field-wrapped Record properties can't be set through the
    // memberwise initializer in this SDK (it expects Field<T> values),
    // so build the record empty and assign each field — the pattern
    // ExpoModulesCore supports for returning records.
    let result = CompositeResultRecord()
    result.uri = outputURL.absoluteString
    result.durationSeconds = durationSeconds.isFinite ? durationSeconds : 0
    result.width = Int(canvasDisplaySize.width.rounded())
    result.height = Int(canvasDisplaySize.height.rounded())
    return result
  }
}
