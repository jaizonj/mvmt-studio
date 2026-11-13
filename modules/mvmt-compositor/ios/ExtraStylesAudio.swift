import Accelerate
import AVFoundation
import Foundation

// MARK: - Audio automation (docs §9)
//
// One decode + one FFT pass per song, cached on disk keyed by
// (path, size, mtime, recipe version). The artifact is the
// AudioAutomation JSON the TS side samples at a frame — onset
// envelope, tempo + beat grid, 10-band energies, K-weighted
// loudness. Nothing here runs per frame; the evaluator only reads
// the stored curves.
//
// Beat detection did not exist in the app before this file: the
// pipeline is spectral-flux onset → autocorrelation tempo →
// Ellis-style dynamic-programming beat tracking, confidence-gated
// at 0.5 with the onset envelope as the fallback (§9.2). A style
// never renders a wrong beat as if it were confident.
//
// DEVIATION (recorded, §9.2): band energies are STFT bin-summed
// per band (the same 10 band edges Auto EQ uses), in the SAME
// single FFT pass — not a separate RBJ filter bank. Cheaper, one
// pass, same band definitions; the per-band normalisation makes
// the two agree on what a "band" is.

// K-weighting biquad (ITU-R BS.1770: high-shelf pre-filter, then
// the RLB high-pass), copied from the module's file-private
// KWeightingFilter (MvmtCompositorModule.swift) — same 48 kHz
// coefficients, same "applied at the asset's native rate"
// approximation (well under half a LU of error at 44.1 kHz).
private final class ExtraStyleKWeightingFilter {
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

enum ExtraStylesAudio {
  static let recipeVersion = 1
  static let outputHopSeconds = 0.1
  static let bandCentersHz: [Double] = [125, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000, 12000]
  /// STFT window / hop (samples at the asset's native rate —
  /// ~0.01 s hop at 44.1/48 kHz).
  static let fftSize = 2048
  static let fftHop = 512
  /// Beat-confidence gate (docs §9.2, same as the TS threshold).
  static let beatConfidenceThreshold = 0.5

  // -- Entry point (bridge) --

  /// Analyse a song and return the AudioAutomation JSON, or nil
  /// when it cannot be analysed. Cached per song; a cache hit
  /// returns the stored JSON without decoding.
  static func prepareAutomation(uri: String) async -> String? {
    let url = ExtraStyleEngineSupport.resolveURL(uri)
    guard let key = cacheKey(for: url) else { return nil }
    if let cached = readCache(key: key) { return cached }
    guard let json = await analyze(url: url, songKey: key) else { return nil }
    writeCache(key: key, json: json)
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

  private static func cacheFileURL(key: String) -> URL? {
    guard
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    else { return nil }
    let directory = support.appendingPathComponent(
      "MVMTStudio/automation", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("automation-\(extraStyleFnv1aHex(key)).json")
  }

  private static func readCache(key: String) -> String? {
    guard let url = cacheFileURL(key: key),
      let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8),
      let jsonData = text.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: jsonData),
      let dict = value as? [String: Any],
      (dict["version"] as? NSNumber)?.intValue == recipeVersion,
      ((dict["onsetEnvelope"] as? [String: Any])?["values"] as? [Any]) != nil
    else { return nil }
    return text
  }

  private static func writeCache(key: String, json: String) {
    guard let url = cacheFileURL(key: key) else { return }
    try? json.write(to: url, atomically: true, encoding: .utf8)
  }

  // -- Decode (one pass, mono Float32 at the native rate) --

  private static func decodeMonoFloats(url: URL) async -> (samples: [Float], sampleRate: Double)? {
    let asset = AVURLAsset(url: url)
    guard let track = (try? await asset.loadTracks(withMediaType: .audio))?.first else {
      return nil
    }
    var sampleRate = 44_100.0
    if let descriptions = try? await track.load(.formatDescriptions),
      let first = descriptions.first,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)
    {
      sampleRate = asbd.pointee.mSampleRate
    }
    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?
    let setupException = extraStyleAvTry {
      do {
        let createdReader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
          AVNumberOfChannelsKey: 1,
        ]
        let createdOutput = AVAssetReaderTrackOutput(
          track: track, outputSettings: outputSettings)
        createdOutput.alwaysCopiesSampleData = false
        if createdReader.canAdd(createdOutput) {
          createdReader.add(createdOutput)
          reader = createdReader
          output = createdOutput
        }
      } catch {
        // Unreadable — the guard below reads nil as "unanalysable".
      }
    }
    guard setupException == nil, let reader, let output, reader.startReading() else {
      return nil
    }
    var samples: [Float] = []
    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let byteLength = CMBlockBufferGetDataLength(blockBuffer)
      let floatCount = byteLength / 4
      guard floatCount > 0 else { continue }
      var floats = [Float](repeating: 0, count: floatCount)
      let copyStatus = floats.withUnsafeMutableBytes { pointer -> OSStatus in
        guard let baseAddress = pointer.baseAddress else { return OSStatus(-1) }
        return CMBlockBufferCopyDataBytes(
          blockBuffer, atOffset: 0, dataLength: floatCount * 4, destination: baseAddress)
      }
      guard copyStatus == noErr else { return nil }
      samples.append(contentsOf: floats)
    }
    guard reader.status == .completed, !samples.isEmpty else { return nil }
    return (samples, sampleRate)
  }

  // -- Analysis --

  private static func analyze(url: URL, songKey: String) async -> String? {
    guard let (samples, sampleRate) = await decodeMonoFloats(url: url) else {
      return nil
    }
    let durationSeconds = Double(samples.count) / sampleRate
    let stftHopSeconds = Double(fftHop) / sampleRate

    // One STFT pass: magnitudes per frame, flux, band energies.
    let frames = stftMagnitudes(samples: samples, sampleRate: sampleRate)
    guard !frames.isEmpty else { return nil }

    // Spectral flux (positive magnitude differences, DC skipped).
    var flux: [Double] = []
    flux.reserveCapacity(frames.count)
    var previous = frames[0]
    flux.append(0)
    for index in 1..<frames.count {
      let magnitudes = frames[index]
      var sum: Double = 0
      for bin in 1..<magnitudes.count {
        let delta = Double(magnitudes[bin]) - Double(previous[bin])
        if delta > 0 { sum += delta }
      }
      flux.append(sum)
      previous = magnitudes
    }

    // Band energies per STFT frame (magnitude² summed per band).
    let bandEdges = bandEdgeFrequencies()
    let bandBins = bandEdges.map { edge -> (Int, Int) in
      let lo = max(0, Int(floor(edge.0 * Double(fftSize) / sampleRate)))
      let hi = max(lo, min(fftSize / 2, Int(ceil(edge.1 * Double(fftSize) / sampleRate))))
      return (lo, hi)
    }
    var bandFrames: [[Double]] = []
    bandFrames.reserveCapacity(frames.count)
    for magnitudes in frames {
      var energies: [Double] = []
      energies.reserveCapacity(bandCentersHz.count)
      for (lo, hi) in bandBins {
        var sum: Double = 0
        for bin in lo..<hi {
          let value = Double(magnitudes[bin])
          sum += value * value
        }
        energies.append(sum)
      }
      bandFrames.append(energies)
    }
    // Per-band normalisation (each band 0..1 by its own max).
    for band in 0..<bandCentersHz.count {
      let maxEnergy = bandFrames.map { $0[band] }.max() ?? 0
      guard maxEnergy > 1e-12 else { continue }
      for frame in 0..<bandFrames.count {
        bandFrames[frame][band] /= maxEnergy
      }
    }

    // K-weighted loudness per 0.1 s hop (time domain, same pass
    // over the decoded samples — the decode is the expensive part,
    // and it already happened).
    let loudness = loudnessCurve(samples: samples, sampleRate: sampleRate)

    // Downsample the STFT-resolution curves to the 0.1 s hop:
    // onset takes the MAX in each hop (onsets are peaks), bands
    // take the MEAN.
    let hopCount = max(1, Int(ceil(durationSeconds / outputHopSeconds)))
    var onsetValues: [Double] = []
    onsetValues.reserveCapacity(hopCount)
    var bandValues: [[Double]] = []
    bandValues.reserveCapacity(hopCount)
    let framesPerHop = outputHopSeconds / stftHopSeconds
    for hop in 0..<hopCount {
      let start = Double(hop) * framesPerHop
      let end = Double(hop + 1) * framesPerHop
      let firstFrame = max(0, Int(floor(start)))
      let lastFrame = min(frames.count - 1, max(firstFrame, Int(ceil(end)) - 1))
      var onsetMax: Double = 0
      var bandSums = [Double](repeating: 0, count: bandCentersHz.count)
      var count = 0
      for frame in firstFrame...lastFrame {
        onsetMax = max(onsetMax, flux[frame])
        for band in 0..<bandCentersHz.count {
          bandSums[band] += bandFrames[frame][band]
        }
        count += 1
      }
      onsetValues.append(onsetMax)
      bandValues.append(
        count > 0
          ? bandSums.map { $0 / Double(count) }
          : [Double](repeating: 0, count: bandCentersHz.count))
    }
    // Normalise the onset envelope by its global max.
    if let maxOnset = onsetValues.max(), maxOnset > 1e-12 {
      onsetValues = onsetValues.map { $0 / maxOnset }
    }

    // Tempo + beats from the STFT-resolution flux.
    let (tempoBpm, beats, beatConfidence) = beatGrid(
      flux: flux, hopSeconds: stftHopSeconds, durationSeconds: durationSeconds)

    let artifact: [String: Any] = [
      "version": recipeVersion,
      "songKey": songKey,
      "sampleRate": sampleRate,
      "durationSeconds": durationSeconds,
      "onsetEnvelope": ["hopSeconds": outputHopSeconds, "values": onsetValues],
      "tempoBpm": tempoBpm,
      "beats": beats.map { beat in
        [
          "timeSeconds": beat.timeSeconds,
          "isDownbeat": beat.isDownbeat,
          "strength": beat.strength,
        ] as [String: Any]
      },
      "beatConfidence": beatConfidence,
      "bandEnergies": [
        "hopSeconds": outputHopSeconds,
        "bandsHz": bandCentersHz,
        "values": bandValues,
      ],
      "loudnessCurve": ["hopSeconds": outputHopSeconds, "values": loudness],
    ]
    return extraStyleJSONString(artifact)
  }

  // -- STFT (classic vDSP C API; magnitudes only) --

  private static func stftMagnitudes(samples: [Float], sampleRate: Double) -> [[Float]] {
    let windowSize = fftSize
    let hop = fftHop
    guard samples.count >= windowSize else { return [] }
    // Hann window, computed once.
    var window = [Float](repeating: 0, count: windowSize)
    for n in 0..<windowSize {
      window[n] = Float(0.5 * (1 - cos(2 * Double.pi * Double(n) / Double(windowSize - 1))))
    }
    let log2n = vDSP_Length(11) // 2^11 = 2048
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
    defer { vDSP_destroy_fftsetup(setup) }
    let frameCount = (samples.count - windowSize) / hop + 1
    var frames: [[Float]] = []
    frames.reserveCapacity(frameCount)
    var real = [Float](repeating: 0, count: windowSize / 2)
    var imag = [Float](repeating: 0, count: windowSize / 2)
    var magnitudes = [Float](repeating: 0, count: windowSize / 2 + 1)
    for frame in 0..<frameCount {
      let start = frame * hop
      // Window, then pack as split complex: realp = first half,
      // imagp = second half (the packed real-FFT layout zrip
      // expects).
      for n in 0..<windowSize / 2 {
        real[n] = samples[start + n] * window[n]
        imag[n] = samples[start + windowSize / 2 + n] * window[windowSize / 2 + n]
      }
      real.withUnsafeMutableBufferPointer { realPointer in
        imag.withUnsafeMutableBufferPointer { imagPointer in
          var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
          vDSP_fft_zrip(setup, &split, 1, log2n, FFT_FORWARD)
          magnitudes.withUnsafeMutableBufferPointer { magnitudePointer in
            vDSP_zvabs(&split, 1, magnitudePointer.baseAddress!, 1, vDSP_Length(windowSize / 2 + 1))
          }
        }
      }
      frames.append(magnitudes)
    }
    return frames
  }

  // -- Band edges (geometric around the centres) --

  private static func bandEdgeFrequencies() -> [(Double, Double)] {
    var edges: [(Double, Double)] = []
    let centers = bandCentersHz
    var lower = centers[0] / sqrt(2)
    for index in 0..<centers.count {
      let upper: Double
      if index + 1 < centers.count {
        upper = sqrt(centers[index] * centers[index + 1])
      } else {
        upper = centers[index] * sqrt(2)
      }
      edges.append((lower, upper))
      lower = upper
    }
    return edges
  }

  // -- K-weighted loudness curve (dB per 0.1 s hop, −60..0) --

  private static func loudnessCurve(samples: [Float], sampleRate: Double) -> [Double] {
    let hopSamples = max(1, Int((outputHopSeconds * sampleRate).rounded()))
    let hopCount = max(1, Int(ceil(Double(samples.count) / Double(hopSamples))))
    var values: [Double] = []
    values.reserveCapacity(hopCount)
    let filter = ExtraStyleKWeightingFilter()
    for hop in 0..<hopCount {
      let start = hop * hopSamples
      let end = min(samples.count, start + hopSamples)
      guard end > start else { values.append(-60); continue }
      var sumSquares: Double = 0
      for index in start..<end {
        let weighted = filter.process(Double(samples[index]))
        sumSquares += weighted * weighted
      }
      let meanSquare = sumSquares / Double(end - start)
      // Mono LUFS-like: −0.691 + 10·log10(mean square), clamped
      // to the −60..0 range the TS reaction mapping expects.
      let db = meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -60
      values.append(max(-60, min(0, db)))
    }
    return values
  }

  // -- Tempo + beat grid --

  private static func beatGrid(
    flux: [Double],
    hopSeconds: Double,
    durationSeconds: Double
  ) -> (tempoBpm: Double, beats: [(timeSeconds: Double, isDownbeat: Bool, strength: Double)], confidence: Double) {
    guard flux.count > 100 else { return (0, [], 0) }
    // Normalise the flux to 0..1 first: the DP's tempo penalty
    // (λ = 0.5) is only meaningful on the same scale as the onset
    // values — raw flux magnitudes would drown it or be drowned.
    let fluxMax = flux.max() ?? 0
    guard fluxMax > 1e-12 else { return (0, [], 0) }
    let flux = flux.map { $0 / fluxMax }
    // Mean-removed flux for the autocorrelation.
    let mean = flux.reduce(0, +) / Double(flux.count)
    let centered = flux.map { $0 - mean }
    let energy = centered.reduce(0) { $0 + $1 * $1 }
    guard energy > 1e-12 else { return (0, [], 0) }
    // Lag range for 60–200 BPM.
    let minLag = max(1, Int((60 / 200 / hopSeconds).rounded()))
    let maxLag = min(flux.count / 2, Int((60 / 60 / hopSeconds).rounded()))
    guard maxLag > minLag else { return (0, [], 0) }
    var autocorr = [Double](repeating: 0, count: maxLag + 1)
    for lag in minLag...maxLag {
      var sum: Double = 0
      for index in 0..<(centered.count - lag) {
        sum += centered[index] * centered[index + lag]
      }
      autocorr[lag] = sum / energy
    }
    var peakLag = minLag
    var peakValue = autocorr[minLag]
    for lag in minLag...maxLag where autocorr[lag] > peakValue {
      peakValue = autocorr[lag]
      peakLag = lag
    }
    // Octave correction: if the half-period is nearly as strong,
    // the true tempo is twice as fast (the classic half-tempo
    // error — a beat every other onset).
    let halfLag = peakLag / 2
    if halfLag >= minLag, autocorr[halfLag] >= 0.85 * peakValue {
      peakLag = halfLag
      peakValue = autocorr[halfLag]
    }
    let periodSeconds = Double(peakLag) * hopSeconds
    let tempoBpm = 60 / periodSeconds
    let confidence = max(0, min(1, peakValue))
    // Ellis-style DP beat tracking: score[i] = onset[i] + best
    // predecessor in [0.5P, 2P] with a log-Gaussian tempo penalty
    // (λ = 0.5). Backtrack from the argmax over the final period.
    let periodFrames = Double(peakLag)
    let minDistance = max(1, Int((0.5 * periodFrames).rounded()))
    let maxDistance = max(minDistance + 1, Int((2 * periodFrames).rounded()))
    var scores = flux
    var predecessors = [Int](repeating: -1, count: flux.count)
    let lambda = 0.5
    for index in minDistance..<flux.count {
      var bestScore = -Double.infinity
      var bestPredecessor = -1
      let lo = max(0, index - maxDistance)
      let hi = index - minDistance
      if hi >= lo {
        for predecessor in lo...hi {
          let distance = Double(index - predecessor)
          let penalty = lambda * pow(log(distance / periodFrames), 2)
          let candidate = scores[predecessor] - penalty
          if candidate > bestScore {
            bestScore = candidate
            bestPredecessor = predecessor
          }
        }
      }
      if bestPredecessor >= 0 {
        scores[index] = flux[index] + bestScore
        predecessors[index] = bestPredecessor
      }
    }
    // Backtrack from the best score in the final period.
    var bestIndex = flux.count - 1
    var bestFinal = scores[bestIndex]
    let searchStart = max(0, flux.count - maxDistance)
    for index in searchStart..<flux.count where scores[index] > bestFinal {
      bestFinal = scores[index]
      bestIndex = index
    }
    var beatIndices: [Int] = []
    var cursor = bestIndex
    while cursor >= 0 {
      beatIndices.append(cursor)
      cursor = predecessors[cursor]
    }
    beatIndices.reverse()
    // Drop beats before the first confident onset (the DP can
    // anchor on a near-silent lead-in) and after the song end.
    let beats: [(Double, Bool, Double)] = beatIndices.compactMap { index in
      let time = Double(index) * hopSeconds
      guard time <= durationSeconds else { return nil }
      return (time, false, min(1, max(0, flux[index])))
    }
    guard !beats.isEmpty else { return (tempoBpm, [], confidence) }
    // Downbeats: every 4th beat from the first (no meter
    // detection — a 4/4 heuristic, documented, not a promise).
    let marked: [(Double, Bool, Double)] = beats.enumerated().map { offset, beat in
      (beat.0, offset % 4 == 0, beat.2)
    }
    return (tempoBpm, marked, confidence)
  }
}
