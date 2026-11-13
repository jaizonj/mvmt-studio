import AVFoundation
import Foundation
import whisper

// MARK: - avTry (the project's AVFoundation exception pattern)
//
// Several AVFoundation APIs validate by RAISING an NSException, which
// Swift cannot catch — an uncaught one aborts the app. Throw-prone
// calls are routed through the ObjC guard, exactly as in the
// compositor module (duplicated here because pods cannot share
// sources).

/// Runs `block` inside an ObjC @try/@catch. Returns the NSException
/// it raised, or nil when it completed normally.
@discardableResult
private func avTry(_ block: @escaping () -> Void) -> NSException? {
  MvmtWhisperExceptionGuard.catching(block)
}

/// An ordinary whisper error describing a caught AVFoundation
/// exception, for guarded sites whose failure path is a thrown error.
private func exceptionError(_ context: String, _ exception: NSException) -> NSError {
  whisperError("\(context) (\(exception.name.rawValue): \(exception.reason ?? "no reason given"))")
}

// MARK: - Result types (plain Swift values; the module maps to Records)

struct WhisperWord {
  var text: String
  var startSeconds: Double
  var endSeconds: Double
}

struct WhisperSegment {
  var text: String
  var startSeconds: Double
  var endSeconds: Double
  var words: [WhisperWord]
}

struct WhisperTranscription {
  /// Detected language code (e.g. "en"), from the model itself.
  var language: String
  var segments: [WhisperSegment]
}

// MARK: - Engine

/// Wraps whisper.cpp (the vendored whisper.xcframework) behind one
/// async call. All whisper state lives on a single serial queue: a
/// whisper_context is not safe for concurrent use, and model load +
/// transcription are inherently one-at-a-time jobs on a phone anyway.
///
/// Word timing comes from DTW token timestamps, enabled at context
/// creation (`dtw_token_timestamps` + the SMALL alignment-heads
/// preset, matching the model we ship) — the accurate path, and the
/// reason the karaoke animations can trust word boundaries. Token
/// t0/t1 remain as a per-token fallback when DTW has no value.
final class WhisperEngine {
  static let shared = WhisperEngine()

  /// Transcription progress sink, 0...1 — wired to the module's
  /// `onTranscribeProgress` event by MvmtWhisperModule.
  var onProgress: ((Double) -> Void)?

  private let queue = DispatchQueue(label: "au.mvmtstudio.whisper.engine")
  private var context: OpaquePointer?

  func transcribe(audioPath: String, modelPath: String) async throws -> WhisperTranscription {
    // Decode first, off the engine queue: an AVAssetReader is a
    // self-contained, thread-safe-to-own pipeline, and a long decode
    // must not block the (serial) whisper queue.
    let samples = try Self.decodeToWhisperPCM(path: audioPath)
    guard !samples.isEmpty else {
      throw whisperError("The song file produced no audio to transcribe.")
    }
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          let result = try self.runWhisperLocked(samples: samples, modelPath: modelPath)
          continuation.resume(returning: result)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // MARK: Context

  /// The loaded whisper_context, created once and reused for the
  /// app's lifetime (model load reads ~490 MB and builds Metal
  /// pipelines — far too expensive to repeat per song).
  private func loadContextLocked(modelPath: String) throws -> OpaquePointer {
    if let context {
      return context
    }
    // GPU first (the vendored binary embeds its Metal library, so no
    // .metallib resource is needed); CPU as the honest fallback if a
    // future OS/device ever refuses the GPU context.
    let loaded = makeContext(modelPath: modelPath, useGPU: true)
      ?? makeContext(modelPath: modelPath, useGPU: false)
    guard let loaded else {
      throw whisperError("The lyrics model could not be loaded.")
    }
    context = loaded
    return loaded
  }

  private func makeContext(modelPath: String, useGPU: Bool) -> OpaquePointer? {
    var params = whisper_context_default_params()
    params.use_gpu = useGPU
    // DTW token timestamps with the alignment heads for the SMALL
    // model — the only model this app downloads (see WhisperModelStore).
    params.dtw_token_timestamps = true
    params.dtw_aheads_preset = WHISPER_AHEADS_SMALL
    return modelPath.withCString { path in
      whisper_init_from_file_with_params(path, params)
    }
  }

  // MARK: Transcription (engine queue only)

  private func runWhisperLocked(samples: [Float], modelPath: String) throws -> WhisperTranscription {
    let ctx = try loadContextLocked(modelPath: modelPath)

    // Beam search with temperature fallback (Jaizon's case: greedy
    // decoding at temperature 0 emitted "[upbeat music]" descriptive
    // annotations instead of transcribing the vocals). Beam search
    // keeps several hypotheses alive instead of committing to the
    // first token, and temperature_inc retries a failed window at
    // higher temperatures instead of giving up on it.
    // suppress_nst blocks non-speech tokens from being emitted at
    // all. Language stays "auto"; everything else unchanged.
    var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
    params.temperature_inc = 0.2
    params.suppress_nst = true
    params.n_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
    params.translate = false
    params.print_special = false
    params.print_progress = false
    params.print_realtime = false
    params.print_timestamps = false
    // Token timestamps on top of the context's DTW: DTW fills t_dtw,
    // the standard pass fills t0/t1 — each token uses DTW when present.
    params.token_timestamps = true
    params.progress_callback = { _, _, progress, userData in
      guard let userData else {
        return
      }
      let engine = Unmanaged<WhisperEngine>.fromOpaque(userData).takeUnretainedValue()
      engine.onProgress?(min(1, max(0, Double(progress) / 100)))
    }
    params.progress_callback_user_data = Unmanaged.passUnretained(self).toOpaque()

    // Language "auto": the small model is multilingual and detects the
    // song's language itself. (The C params default is "en", which
    // would silently force English on every song.)
    let status: Int32 = "auto".withCString { language in
      params.language = language
      return samples.withUnsafeBufferPointer { buffer in
        whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
      }
    }
    guard status == 0 else {
      throw whisperError("Transcription failed (whisper error \(status)).")
    }

    let language = String(cString: whisper_lang_str(whisper_full_lang_id(ctx)))
    return WhisperTranscription(
      language: language,
      segments: Self.readSegments(ctx: ctx)
    )
  }

  /// Reads segments + tokens out of a finished transcription and
  /// assembles words. Whisper timestamps are int64 counts of 10 ms;
  /// dividing by 100 gives seconds from the start of the decoded
  /// audio — i.e. song-absolute seconds, exactly what the lyrics
  /// editor pins lines to.
  private static func readSegments(ctx: OpaquePointer) -> [WhisperSegment] {
    var segments: [WhisperSegment] = []
    // Every special token in the vocab — control markers
    // (<|endoftext|>, <|startoftranscript|>, languages, …), the
    // [_BEG_] begin marker and the [_TT_n] timestamp family — has an
    // id at or above EOT; every real lyric token sits below it. The
    // id check is therefore the authoritative special-token filter.
    let eotToken = whisper_token_eot(ctx)
    let segmentCount = whisper_full_n_segments(ctx)
    for index in 0..<segmentCount {
      let segmentStart = Double(whisper_full_get_segment_t0(ctx, index)) / 100
      let segmentEnd = Double(whisper_full_get_segment_t1(ctx, index)) / 100

      var tokens: [(text: String, start: Double, end: Double)] = []
      // The segment's text is REBUILT from kept tokens only:
      // whisper_full_get_segment_text can carry bracket tokens
      // (a segment whose text read "me?[_TT_500]" shipped exactly
      // that into the lyrics), so it is never used directly.
      var keptText = ""
      let tokenCount = whisper_full_n_tokens(ctx, index)
      for tokenIndex in 0..<tokenCount {
        let tokenId = whisper_full_get_token_id(ctx, index, tokenIndex)
        let text = String(cString: whisper_full_get_token_text(ctx, index, tokenIndex))
        // Special tokens are not words and never reach the lyrics.
        // Belt and braces, any one of these excludes the token:
        // - id >= EOT (the vocab-level check above),
        // - the "[_" text prefix (the [_BEG_] / [_TT_n] family,
        //   caught even if a future vocab renumbers them),
        // - the legacy "<|" prefix for the <|…|> marker family.
        if tokenId >= eotToken || text.hasPrefix("[_") || text.hasPrefix("<|") {
          continue
        }
        let data = whisper_full_get_token_data(ctx, index, tokenIndex)
        let start = Double(data.t_dtw >= 0 ? data.t_dtw : data.t0) / 100
        let end = Double(data.t1) / 100
        tokens.append((text: text, start: start, end: end))
        keptText += text
      }

      let words = assembleWords(tokens: tokens)
      let rebuiltText = keptText.trimmingCharacters(in: .whitespacesAndNewlines)
      let text = rebuiltText.isEmpty
        ? words.map(\.text).joined(separator: " ")
        : rebuiltText
      if text.isEmpty && words.isEmpty {
        continue
      }
      segments.append(
        WhisperSegment(
          text: text,
          startSeconds: segmentStart,
          endSeconds: segmentEnd,
          words: words
        )
      )
    }
    return segments
  }

  /// Groups BPE tokens into words: a token whose text starts with a
  /// space opens a new word; the rest extend the open one. Word times
  /// are made monotonic (a word never starts before the previous one
  /// ends) so karaoke highlighting can sweep without flicker.
  private static func assembleWords(
    tokens: [(text: String, start: Double, end: Double)]
  ) -> [WhisperWord] {
    var words: [WhisperWord] = []
    var currentText: String?
    var currentStart = 0.0
    var currentEnd = 0.0

    func flush() {
      guard let raw = currentText else {
        return
      }
      let text = raw.trimmingCharacters(in: .whitespaces)
      if !text.isEmpty {
        var start = currentStart
        if let last = words.last, start < last.endSeconds {
          start = last.endSeconds
        }
        words.append(
          WhisperWord(
            text: text,
            startSeconds: start,
            endSeconds: max(currentEnd, start)
          )
        )
      }
      currentText = nil
    }

    for token in tokens {
      if token.text.hasPrefix(" ") || currentText == nil {
        flush()
        currentText = token.text
        currentStart = token.start
        currentEnd = token.end
      } else {
        currentText! += token.text
        currentEnd = max(currentEnd, token.end)
      }
    }
    flush()
    return words
  }

  // MARK: - Audio decode (16 kHz mono float PCM — whisper's input)

  /// Decodes any audio (or video) file to whisper's native format.
  /// Runs on the caller's thread; the reader is created and used
  /// entirely inside this call.
  private static func decodeToWhisperPCM(path: String) throws -> [Float] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))

    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?
    var swiftError: Error?

    // AVAssetReader / AVAssetReaderTrackOutput creation validates the
    // asset and can raise — route through the guard so a hostile or
    // corrupt file fails the transcription instead of the app.
    let exception = avTry {
      do {
        guard let track = asset.tracks(withMediaType: .audio).first else {
          swiftError = whisperError("The song file has no audio track.")
          return
        }
        let settings: [String: Any] = [
          AVFormatIDKey: Int(kAudioFormatLinearPCM),
          AVSampleRateKey: 16_000,
          AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        trackOutput.alwaysCopiesSampleData = false
        let assetReader = try AVAssetReader(asset: asset)
        guard assetReader.canAdd(trackOutput) else {
          swiftError = whisperError("The song file could not be decoded.")
          return
        }
        assetReader.add(trackOutput)
        reader = assetReader
        output = trackOutput
      } catch {
        swiftError = error
      }
    }
    if let exception {
      throw exceptionError("The song file could not be opened for decoding", exception)
    }
    if let swiftError {
      throw swiftError
    }
    guard let reader, let output else {
      throw whisperError("The song file could not be decoded.")
    }

    guard reader.startReading() else {
      throw reader.error ?? whisperError("The song file could not be decoded.")
    }

    var samples: [Float] = []
    // Pre-size for a typical song (~4 min) to avoid repeated growth;
    // appends handle anything longer.
    samples.reserveCapacity(16_000 * 240)
    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        continue
      }
      let length = CMBlockBufferGetDataLength(blockBuffer)
      let count = length / MemoryLayout<Float>.size
      guard count > 0 else {
        continue
      }
      var chunk = [Float](repeating: 0, count: count)
      CMBlockBufferCopyDataBytes(
        blockBuffer,
        atOffset: 0,
        dataLength: length,
        destination: &chunk
      )
      samples.append(contentsOf: chunk)
    }
    if reader.status == .failed {
      throw reader.error ?? whisperError("The song file could not be decoded.")
    }
    return samples
  }
}
