import AVFoundation
import CoreImage
import Foundation
import UniformTypeIdentifiers
import Vision

// MARK: - Subject masks (docs §10)
//
// Precompute: Vision person segmentation + face detection at 2 fps,
// cached per take (Application Support/MVMTStudio/masks/<key>/).
// Runtime: ExtraStyleMaskProvider loads the mask PNGs, blends
// adjacent samples by time fraction, and hands the renderer a
// CGImage mask (pre-inverted when a style asks for it — Core
// Graphics has no invert-clip).
//
// No tracking promises: masks are per-sample snapshots, linearly
// blended — a fast-moving person smears slightly between samples,
// which is the documented behaviour, not a bug. Face boxes are
// nearest-sample (they change slowly at 2 fps).

enum ExtraStylesMasks {
  static let recipeVersion = 1
  static let maskWidth = 270
  static let maskHeight = 480
  static let maxSamples = 240

  // -- Entry point (bridge) --

  /// Precompute masks for a take and return the SubjectMaskIndex
  /// JSON, or nil when it cannot be computed. Cached per take; a
  /// cache hit returns the stored index without running Vision.
  static func prepareMasks(takeUri: String) async -> String? {
    let url = ExtraStyleEngineSupport.resolveURL(takeUri)
    guard let key = cacheKey(for: url) else { return nil }
    if let cached = readIndex(key: key) { return cached }
    guard let json = await compute(url: url, takeKey: key) else { return nil }
    return json
  }

  // -- Cache --

  private static func cacheKey(for url: URL) -> String? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      let mtime = attributes[.modificationDate] as? Date
    else { return nil }
    return "\(url.path)|\(size.int64Value)|\(mtime.timeIntervalSince1970)|\(recipeVersion)"
  }

  private static func cacheDirectory(key: String) -> URL? {
    guard
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    else { return nil }
    let directory = support
      .appendingPathComponent("MVMTStudio/masks", isDirectory: true)
      .appendingPathComponent(extraStyleFnv1aHex(key), isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func readIndex(key: String) -> String? {
    guard let directory = cacheDirectory(key: key),
      let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
      let text = String(data: data, encoding: .utf8),
      let jsonData = text.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: jsonData),
      let dict = value as? [String: Any],
      (dict["version"] as? NSNumber)?.intValue == recipeVersion,
      ((dict["maskUris"] as? [Any])?.isEmpty == false)
    else { return nil }
    return text
  }

  // -- Precompute --

  private static func compute(url: URL, takeKey: String) async -> String? {
    let asset = AVURLAsset(url: url)
    guard
      let duration = try? await asset.load(.duration),
      duration.seconds > 0
    else { return nil }
    let durationSeconds = duration.seconds
    // 2 fps, capped at 240 samples (a 120 s take).
    let interval = max(0.5, durationSeconds / Double(maxSamples))
    let sampleCount = min(maxSamples, Int(floor(durationSeconds / interval)) + 1)
    guard sampleCount > 0 else { return nil }
    guard let directory = cacheDirectory(key: takeKey) else { return nil }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: maskWidth, height: maskHeight)
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var sampleTimes: [Double] = []
    var maskUris: [String] = []
    var faces: [[String: Any]] = []
    for sample in 0..<sampleCount {
      let timeSeconds = min(durationSeconds - 0.01, Double(sample) * interval)
      let time = CMTime(seconds: timeSeconds, preferredTimescale: 600)
      guard
        let cgImage = try? generator.copyCGImage(at: time, actualTime: nil)
      else { continue }
      let (maskURL, faceBoxes) = processFrame(
        cgImage: cgImage, sampleIndex: sample, directory: directory, ciContext: ciContext)
      guard let maskURL else { continue }
      sampleTimes.append(timeSeconds)
      maskUris.append(maskURL.absoluteString)
      faces.append([
        "timeSeconds": timeSeconds,
        "boxes": faceBoxes.map { [$0[0], $0[1], $0[2], $0[3]] },
      ])
    }
    guard !maskUris.isEmpty else { return nil }
    let index: [String: Any] = [
      "version": recipeVersion,
      "takeKey": takeKey,
      "sampleTimesSeconds": sampleTimes,
      "maskUris": maskUris,
      "faces": faces,
    ]
    let json = extraStyleJSONString(index)
    try? json.write(
      to: directory.appendingPathComponent("index.json"),
      atomically: true, encoding: .utf8)
    return json
  }

  /// Run Vision on one frame and write its mask PNG. Returns the
  /// mask file URL and the frame's face boxes (y-down 0..1 canvas
  /// fractions). A Vision failure on one frame skips that frame —
  /// the index just has fewer samples, never a failure.
  private static func processFrame(
    cgImage: CGImage,
    sampleIndex: Int,
    directory: URL,
    ciContext: CIContext
  ) -> (URL?, [[Double]]) {
    let segmentation = VNGeneratePersonSegmentationRequest()
    segmentation.qualityLevel = .accurate
    segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    let faceRequest = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([segmentation, faceRequest])
    } catch {
      return (nil, [])
    }
    guard
      let observation = segmentation.results?.first,
      let pixelBuffer = observation.pixelBuffer
    else { return (nil, []) }
    // Mask → 270×480 grayscale PNG (aspect-fit, centred; the
    // canvas is portrait 9:16 and takes conform to it, so the fit
    // is exact for normal takes).
    let maskCI = CIImage(cvPixelBuffer: pixelBuffer)
    let scale = min(
      Double(maskWidth) / maskCI.extent.width,
      Double(maskHeight) / maskCI.extent.height
    )
    let scaled = maskCI.transformed(
      by: CGAffineTransform(scaleX: scale, y: scale))
    let offsetX = (Double(maskWidth) - scaled.extent.width) / 2
    let offsetY = (Double(maskHeight) - scaled.extent.height) / 2
    let placed = scaled.transformed(
      by: CGAffineTransform(translationX: offsetX, y: offsetY))
    guard
      let gray = ciContext.createCGImage(
        placed,
        from: CGRect(x: 0, y: 0, width: maskWidth, height: maskHeight),
        format: .L8,
        colorSpace: CGColorSpaceCreateDeviceGray()
      )
    else { return (nil, []) }
    let fileURL = directory.appendingPathComponent(
      String(format: "mask-%03d.png", sampleIndex))
    guard
      let destination = CGImageDestinationCreateWithURL(
        fileURL as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return (nil, []) }
    CGImageDestinationAddImage(destination, gray, nil)
    guard CGImageDestinationFinalize(destination) else { return (nil, []) }
    // Faces: Vision boxes are normalised, y-UP — flip to y-down
    // canvas fractions.
    var boxes: [[Double]] = []
    for face in faceRequest.results ?? [] {
      let box = face.boundingBox
      boxes.append([
        Double(box.origin.x),
        Double(1 - box.origin.y - box.size.height),
        Double(box.size.width),
        Double(box.size.height),
      ])
    }
    return (fileURL, boxes)
  }
}

// MARK: - Runtime mask provider

/// Loads a take's mask PNGs on demand and blends adjacent samples
/// by time fraction. The renderer asks per node per frame; the
/// provider keeps a 4-slot byte cache (each sample is 270×480
/// bytes) so repeated frames are cheap.
final class ExtraStyleMaskProvider {
  let index: ExtraStyleSubjectMaskIndex
  private let lock = NSLock()
  private var byteCache: [Int: [UInt8]] = [:]
  private var byteCacheOrder: [Int] = []

  init(index: ExtraStyleSubjectMaskIndex) {
    self.index = index
  }

  /// The mask at a time (grayscale CGImage, 270×480), or nil when
  /// no mask is available. `inverted` returns 1 − value,
  /// pre-computed — there is no invert-clip in Core Graphics.
  func maskImage(at seconds: Double, inverted: Bool) -> CGImage? {
    let times = index.sampleTimesSeconds
    guard !times.isEmpty, !index.maskUris.isEmpty else { return nil }
    // Bracketing samples + time fraction.
    var lower = 0
    for (offset, time) in times.enumerated() where time <= seconds {
      lower = offset
    }
    let upper = min(lower + 1, times.count - 1)
    let fraction: Double
    if upper == lower || times[upper] <= times[lower] {
      fraction = 0
    } else {
      fraction = max(0, min(1, (seconds - times[lower]) / (times[upper] - times[lower])))
    }
    guard let lowerBytes = maskBytes(sampleIndex: lower) else { return nil }
    let count = ExtraStylesMasks.maskWidth * ExtraStylesMasks.maskHeight
    var blended = [UInt8](repeating: 0, count: count)
    if fraction <= 0 || upper == lower {
      for i in 0..<count {
        blended[i] = inverted ? 255 - lowerBytes[i] : lowerBytes[i]
      }
    } else if let upperBytes = maskBytes(sampleIndex: upper) {
      for i in 0..<count {
        let value = Double(lowerBytes[i]) + (Double(upperBytes[i]) - Double(lowerBytes[i])) * fraction
        let byte = UInt8(max(0, min(255, Int(value.rounded()))))
        blended[i] = inverted ? 255 - byte : byte
      }
    } else {
      for i in 0..<count {
        blended[i] = inverted ? 255 - lowerBytes[i] : lowerBytes[i]
      }
    }
    let data = Data(blended)
    guard
      let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: ExtraStylesMasks.maskWidth,
        height: ExtraStylesMasks.maskHeight,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: ExtraStylesMasks.maskWidth,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else { return nil }
    return image
  }

  /// One sample's mask as grayscale bytes (270×480), via a small
  /// LRU byte cache. The PNGs are written grayscale already, so
  /// the draw is a no-op scale.
  private func maskBytes(sampleIndex: Int) -> [UInt8]? {
    lock.lock()
    if let cached = byteCache[sampleIndex] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    guard sampleIndex < index.maskUris.count else { return nil }
    let url = ExtraStyleEngineSupport.resolveURL(index.maskUris[sampleIndex])
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(
        data: nil,
        width: ExtraStylesMasks.maskWidth,
        height: ExtraStylesMasks.maskHeight,
        bitsPerComponent: 8,
        bytesPerRow: ExtraStylesMasks.maskWidth,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return nil }
    context.draw(
      image,
      in: CGRect(
        x: 0, y: 0,
        width: ExtraStylesMasks.maskWidth,
        height: ExtraStylesMasks.maskHeight
      )
    )
    guard let data = context.data else { return nil }
    let bytes = Array(
      UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: UInt8.self),
        count: ExtraStylesMasks.maskWidth * ExtraStylesMasks.maskHeight
      )
    )
    lock.lock()
    byteCache[sampleIndex] = bytes
    byteCacheOrder.append(sampleIndex)
    while byteCacheOrder.count > 4, let oldest = byteCacheOrder.first {
      byteCacheOrder.removeFirst()
      byteCache.removeValue(forKey: oldest)
    }
    lock.unlock()
    return bytes
  }
}
