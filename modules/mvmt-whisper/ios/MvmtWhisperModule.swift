import ExpoModulesCore
import Foundation

// MARK: - JS <-> Swift records (mirror src/index.ts exactly)
//
// NOTE (project history): @Field-wrapped Record properties are
// populated by constructing the record empty and assigning each field
// — see the transcribe mapping below.

struct WhisperWordRecord: Record {
  @Field
  var text: String = ""

  @Field
  var startSeconds: Double = 0

  @Field
  var endSeconds: Double = 0
}

struct WhisperSegmentRecord: Record {
  @Field
  var text: String = ""

  @Field
  var startSeconds: Double = 0

  @Field
  var endSeconds: Double = 0

  @Field
  var words: [WhisperWordRecord] = []
}

struct WhisperTranscriptionRecord: Record {
  /// Detected language code (e.g. "en").
  @Field
  var language: String = ""

  @Field
  var segments: [WhisperSegmentRecord] = []
}

// MARK: - Module definition

public class MvmtWhisperModule: Module {
  public func definition() -> ModuleDefinition {
    Name("MvmtWhisper")

    Events("onModelDownloadProgress", "onTranscribeProgress")

    OnCreate {
      // Download/transcription events must outlive individual
      // function calls, so the store + engine emit through these
      // sinks (weakly held module), exactly like the compositor's
      // PreviewStore wiring.
      WhisperModelStore.shared.onProgress = { [weak self] progress in
        self?.sendEvent("onModelDownloadProgress", ["progress": progress])
      }
      WhisperEngine.shared.onProgress = { [weak self] progress in
        self?.sendEvent("onTranscribeProgress", ["progress": progress])
      }
    }

    /// Downloads the Whisper small model (~488 MB) if it is not
    /// already on disk. Progress arrives as onModelDownloadProgress
    /// events (0...1). Resolves immediately when the model is ready.
    AsyncFunction("ensureModel") {
      try await WhisperModelStore.shared.ensureModel()
    }

    /// 'absent' | 'downloading' | 'ready' | 'failed'
    AsyncFunction("modelState") { () -> String in
      WhisperModelStore.shared.state().rawValue
    }

    /// Transcribes a local audio file with word-level timestamps
    /// (DTW). All times are song-absolute seconds. Throws when the
    /// model has not been downloaded yet.
    AsyncFunction("transcribe") { (audioUri: String) -> WhisperTranscriptionRecord in
      guard WhisperModelStore.shared.state() == .ready else {
        throw whisperError("The lyrics model is not downloaded yet — call ensureModel first.")
      }
      let result = try await WhisperEngine.shared.transcribe(
        audioPath: MvmtWhisperModule.resolvePath(audioUri),
        modelPath: WhisperModelStore.modelFileURL.path
      )
      let record = WhisperTranscriptionRecord()
      record.language = result.language
      record.segments = result.segments.map { segment in
        let segmentRecord = WhisperSegmentRecord()
        segmentRecord.text = segment.text
        segmentRecord.startSeconds = segment.startSeconds
        segmentRecord.endSeconds = segment.endSeconds
        segmentRecord.words = segment.words.map { word in
          let wordRecord = WhisperWordRecord()
          wordRecord.text = word.text
          wordRecord.startSeconds = word.startSeconds
          wordRecord.endSeconds = word.endSeconds
          return wordRecord
        }
        return segmentRecord
      }
      return record
    }
  }

  /// Accepts a `file://` URI or a plain filesystem path.
  private static func resolvePath(_ uri: String) -> String {
    if uri.hasPrefix("file://") {
      return URL(string: uri)?.path ?? uri
    }
    return uri
  }
}
