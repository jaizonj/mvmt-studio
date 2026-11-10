import Foundation

/// An ordinary, promise-rejectable whisper error (mirrors the
/// compositor module's `compositorError`).
func whisperError(_ message: String) -> NSError {
  NSError(
    domain: "MvmtWhisper",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: message]
  )
}

/// Owns the on-device Whisper "small" model file: where it lives,
/// whether it is fully downloaded, and the single in-flight download
/// that fetches it.
///
/// The model is NOT bundled with the app (it is 487,601,967 bytes —
/// bundling it would take the IPA from ~17 MB to ~500 MB). It is
/// downloaded once, on the first lyrics detection, into
/// `Application Support/MvmtWhisper/` and reused forever after.
///
/// Readiness is exact: the file must exist at its full published byte
/// count. A truncated or error-page download can never pass, and no
/// separate checksum pass is needed for the state check. (Published
/// SHA-256 for reference: see INTEGRATION.md.)
final class WhisperModelStore: NSObject, URLSessionDownloadDelegate {
  static let shared = WhisperModelStore()

  enum State: String {
    case absent
    case downloading
    case ready
    case failed
  }

  /// Whisper small (multilingual), ggml format, from the official
  /// whisper.cpp Hugging Face repo.
  static let modelDownloadURL = URL(
    string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
  )!

  /// Exact published size of ggml-small.bin — the readiness check.
  static let modelByteCount: Int64 = 487_601_967

  static var modelDirectory: URL {
    // Application Support always exists on iOS; the force unwrap is
    // the same one FileManager documentation blesses for this search.
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return base.appendingPathComponent("MvmtWhisper", isDirectory: true)
  }

  static var modelFileURL: URL {
    modelDirectory.appendingPathComponent("ggml-small.bin")
  }

  /// Download progress sink, 0...1 — wired to the module's
  /// `onModelDownloadProgress` event by MvmtWhisperModule.
  var onProgress: ((Double) -> Void)?

  /// Serial queue guarding every piece of mutable state below.
  private let queue = DispatchQueue(label: "au.mvmtstudio.whisper.model")
  private var downloadTask: URLSessionDownloadTask?
  private var waiters: [CheckedContinuation<Void, Error>] = []
  private var lastDownloadFailed = false

  private lazy var session: URLSession = {
    // A dedicated SERIAL delegate queue — callbacks never land on the
    // main thread, and state funnelled through `queue` stays race-free.
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    return URLSession(
      configuration: .default,
      delegate: self,
      delegateQueue: delegateQueue
    )
  }()

  // MARK: - State

  /// True only when the complete model file is on disk.
  var isModelOnDisk: Bool {
    let url = Self.modelFileURL
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attrs[.size] as? NSNumber
    else {
      return false
    }
    return size.int64Value == Self.modelByteCount
  }

  func state() -> State {
    if isModelOnDisk {
      return .ready
    }
    return queue.sync {
      if downloadTask != nil {
        return .downloading
      }
      return lastDownloadFailed ? .failed : .absent
    }
  }

  // MARK: - Download

  /// Resolves when the model is fully on disk; throws on failure.
  /// Concurrent callers share the one in-flight download.
  func ensureModel() async throws {
    if isModelOnDisk {
      return
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        if self.isModelOnDisk {
          continuation.resume()
          return
        }
        self.waiters.append(continuation)
        guard self.downloadTask == nil else {
          // A download is already running — this caller just waits
          // on the same one.
          return
        }
        self.lastDownloadFailed = false
        self.prepareModelDirectory()
        let task = self.session.downloadTask(with: Self.modelDownloadURL)
        self.downloadTask = task
        task.resume()
      }
    }
  }

  private func prepareModelDirectory() {
    let dir = Self.modelDirectory
    try? FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true
    )
    // The model is re-downloadable, so it does not belong in iCloud
    // backups (Apple's rule for exactly this kind of content).
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableDir = dir
    try? mutableDir.setResourceValues(values)
  }

  /// Settles every waiter and resets the in-flight state. Call on
  /// `queue` only.
  private func finishDownload(with error: Error?) {
    let pending = waiters
    waiters = []
    downloadTask = nil
    lastDownloadFailed = error != nil
    for waiter in pending {
      if let error {
        waiter.resume(throwing: error)
      } else {
        waiter.resume()
      }
    }
  }

  // MARK: - URLSessionDownloadDelegate

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    // HF answers through a redirect to a CDN; if the expected total
    // ever comes back unknown (-1), fall back to the known published
    // size so progress still runs 0...1.
    let expected = totalBytesExpectedToWrite > 0
      ? totalBytesExpectedToWrite
      : Self.modelByteCount
    let progress = min(1, max(0, Double(totalBytesWritten) / Double(expected)))
    onProgress?(progress)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // Move the finished file into place FIRST (this delegate callback
    // must not return before the temp file is dealt with — the system
    // deletes it as soon as we return), then settle the waiters.
    let destination = Self.modelFileURL
    var moveError: Error?
    do {
      prepareModelDirectory()
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: location, to: destination)
    } catch {
      moveError = error
    }

    queue.async {
      if let moveError {
        self.finishDownload(
          with: whisperError("The model download could not be saved: \(moveError.localizedDescription)")
        )
        return
      }
      // The byte-count gate: an HTTP error page or a truncated CDN
      // transfer lands here as a wrong-sized file and fails honestly
      // instead of poisoning every later transcription.
      guard self.isModelOnDisk else {
        try? FileManager.default.removeItem(at: destination)
        self.finishDownload(
          with: whisperError("The model download was incomplete. Check your connection and try again.")
        )
        return
      }
      self.onProgress?(1)
      self.finishDownload(with: nil)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    // Success is settled in didFinishDownloadingTo; this fires after
    // it (with a nil error) as well as for genuine failures.
    guard let error else {
      return
    }
    queue.async {
      self.finishDownload(with: error)
    }
  }
}
