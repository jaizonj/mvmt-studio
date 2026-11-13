import CoreImage
import Foundation
import Metal

// MARK: - Metal spike (docs §6.5)
//
// Timeboxed benchmark: particle field + distortion wave at 2,000
// particles, Core Image vs Metal, measured on device. OFF the
// render path — it runs only when the bridge calls
// benchmarkExtraStyleNodes, and its verdict decides whether any
// Phase 4 node adopts Metal. It never throws: on a build without
// Metal it returns the CI baseline + a note.
//
// The CI baseline is the REAL renderer (a spike scene with a
// 500/s emitter, 4 s lifetime → 2,000 alive particles, plus a
// displacement node measured separately), not a synthetic
// micro-benchmark — the comparison is against the code the styles
// actually run.

enum ExtraStylesMetalSpike {
  static let particleCount = 2000
  static let iterations = 30

  static func benchmarkJSON() -> String {
    let canvas = CGSize(width: 1080, height: 1920)
    let ci = ciBaseline(canvas: canvas)
    guard let device = MTLCreateSystemDefaultDevice() else {
      return extraStyleJSONString([
        "metalAvailable": false,
        "note": "No Metal device on this build — CI baseline only; the verdict is Core Image until a device measurement says otherwise.",
        "ciParticleMs": ci.particleMs,
        "ciDistortionMs": ci.distortionMs,
        "ciHolds30fps": ci.particleMs + ci.distortionMs < 1000 / 30,
        "verdict": "core-image",
      ])
    }
    guard let metal = metalBaseline(device: device, canvas: canvas) else {
      return extraStyleJSONString([
        "metalAvailable": true,
        "device": device.name,
        "note": "Metal pipeline setup failed — CI baseline only.",
        "ciParticleMs": ci.particleMs,
        "ciDistortionMs": ci.distortionMs,
        "ciHolds30fps": ci.particleMs + ci.distortionMs < 1000 / 30,
        "verdict": "core-image",
      ])
    }
    let particleSpeedup = metal.particleMs > 0 ? ci.particleMs / metal.particleMs : 0
    let distortionSpeedup = metal.distortionMs > 0 ? ci.distortionMs / metal.distortionMs : 0
    let ciHolds30fps = ci.particleMs + ci.distortionMs < 1000 / 30
    // Adopt Metal per-node only on a ≥2× win, or when Core Image
    // cannot hold 30 fps for the combined node (§6.5).
    let verdict =
      (particleSpeedup >= 2 || distortionSpeedup >= 2 || !ciHolds30fps)
      ? "metal" : "core-image"
    return extraStyleJSONString([
      "metalAvailable": true,
      "device": device.name,
      "ciParticleMs": ci.particleMs,
      "ciDistortionMs": ci.distortionMs,
      "metalParticleMs": metal.particleMs,
      "metalDistortionMs": metal.distortionMs,
      "particleSpeedup": particleSpeedup,
      "distortionSpeedup": distortionSpeedup,
      "ciHolds30fps": ciHolds30fps,
      "verdict": verdict,
    ])
  }

  // -- Core Image baseline (the real renderer) --

  private static func ciBaseline(canvas: CGSize) -> (particleMs: Double, distortionMs: Double) {
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, Int(canvas.width), Int(canvas.height),
      kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas))

    // Particles: the spike scene, no displacement node.
    let particleScene = spikeScene(canvas: canvas, includeDisplacement: false)
    let particlePrepared = PreparedExtraStyleScene(
      handle: "spike-ci-particles", styleId: "__spike", styleVersion: 1,
      seed: 1, fps: 30, canvas: canvas, durationFrames: 900,
      automation: nil, maskIndex: nil, scene: particleScene, params: [:], lines: [])
    let renderer = ExtraStyleSceneRenderer(canvas: canvas)
    // Warm up (sprite cache, glyph layout), then measure frame 120
    // (4 s in — the emitter has reached its 2,000 alive steady state).
    for _ in 0..<3 {
      let rendered = renderer.render(prepared: particlePrepared, frame: 120, base: black)
      if let pixelBuffer { ciContext.render(rendered.image, to: pixelBuffer) }
    }
    var particleTimes: [Double] = []
    for _ in 0..<iterations {
      let start = CFAbsoluteTimeGetCurrent()
      let rendered = renderer.render(prepared: particlePrepared, frame: 120, base: black)
      if let pixelBuffer { ciContext.render(rendered.image, to: pixelBuffer) }
      particleTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    // Distortion: CIDisplacementDistortion on a full frame with
    // the same procedural map the renderer uses.
    let map = ExtraStylesEngine.makeDisplacementMap(frequency: 4, size: 256)
    var distortionTimes: [Double] = []
    if let map {
      for _ in 0..<iterations {
        let start = CFAbsoluteTimeGetCurrent()
        if let filter = CIFilter(name: "CIDisplacementDistortion") {
          filter.setValue(black, forKey: kCIInputImageKey)
          filter.setValue(map, forKey: kCIInputDisplacementImageKey)
          filter.setValue(20, forKey: kCIInputScaleKey)
          if let output = filter.outputImage, let pixelBuffer {
            ciContext.render(output.cropped(to: black.extent), to: pixelBuffer)
          }
        }
        distortionTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
      }
    }
    return (median(particleTimes), median(distortionTimes))
  }

  private static func spikeScene(canvas: CGSize, includeDisplacement: Bool) -> ExtraStyleScene {
    var nodes: [String: ExtraStyleNode] = [:]
    nodes["root"] = ExtraStyleNode(
      id: "root", kind: .group,
      children: includeDisplacement
        ? ["spike-particles", "spike-displacement"] : ["spike-particles"])
    nodes["spike-particles"] = ExtraStyleNode(
      id: "spike-particles", kind: .particles,
      position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
      emitter: ExtraStyleEmitterContent(
        rate: 500, lifetimeSeconds: 4,
        origin: CGPoint(x: 0.5, y: 0.9),
        velocity: CGVector(dx: 0, dy: -0.08),
        spread: CGVector(dx: 0.12, dy: 0.03),
        gravity: -0.01,
        size: 0.012, sizeSpread: 0.006,
        opacityFrom: 0.9, opacityTo: 0,
        color: ExtraStyleRGBA(r: 0.79, g: 0.95, b: 0.42, a: 1),
        spriteKind: .softCircle
      )
    )
    if includeDisplacement {
      nodes["spike-displacement"] = ExtraStyleNode(
        id: "spike-displacement", kind: .displacement,
        displacement: ExtraStyleDisplacementContent(baseScale: 20, frequency: 4))
    }
    return ExtraStyleScene(
      rootId: "root", nodes: nodes, canvas: canvas, durationFrames: 900)
  }

  // -- Metal baseline --

  private static func metalBaseline(
    device: MTLDevice, canvas: CGSize
  ) -> (particleMs: Double, distortionMs: Double)? {
    guard let library = try? device.makeLibrary(source: metalSource, options: nil),
      let updateFunction = library.makeFunction(name: "updateParticles"),
      let vertexFunction = library.makeFunction(name: "particleVertex"),
      let fragmentFunction = library.makeFunction(name: "particleFragment"),
      let fullscreenFunction = library.makeFunction(name: "fullscreenVertex"),
      let distortFunction = library.makeFunction(name: "distortFragment"),
      let computePipeline = try? device.makeComputePipelineState(function: updateFunction)
    else { return nil }
    let particleDescriptor = MTLRenderPipelineDescriptor()
    particleDescriptor.vertexFunction = vertexFunction
    particleDescriptor.fragmentFunction = fragmentFunction
    particleDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    particleDescriptor.colorAttachments[0].isBlendingEnabled = true
    particleDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    particleDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    guard let particlePipeline = try? device.makeRenderPipelineState(descriptor: particleDescriptor) else {
      return nil
    }
    let distortDescriptor = MTLRenderPipelineDescriptor()
    distortDescriptor.vertexFunction = fullscreenFunction
    distortDescriptor.fragmentFunction = distortFunction
    distortDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    guard let distortPipeline = try? device.makeRenderPipelineState(descriptor: distortDescriptor) else {
      return nil
    }
    guard
      let queue = device.makeCommandQueue(),
      let particleBuffer = makeParticleBuffer(device: device),
      let sprite = makeSpriteTexture(device: device),
      let targetA = makeTexture(device: device, canvas: canvas),
      let targetB = makeTexture(device: device, canvas: canvas)
    else { return nil }

    let particleTimes = measure(iterations: iterations) {
      guard let buffer = queue.makeCommandBuffer(),
        let encoder = buffer.makeComputeCommandEncoder()
      else { return }
      encoder.setComputePipelineState(computePipeline)
      encoder.setBuffer(particleBuffer, offset: 0, index: 0)
      var dt: Float = 1 / 30
      var seed: Float = 7
      var canvasVec = SIMD2<Float>(Float(canvas.width), Float(canvas.height))
      encoder.setBytes(&dt, length: MemoryLayout<Float>.size, index: 1)
      encoder.setBytes(&seed, length: MemoryLayout<Float>.size, index: 2)
      encoder.setBytes(&canvasVec, length: MemoryLayout<SIMD2<Float>>.size, index: 3)
      encoder.dispatchThreads(
        MTLSize(width: particleCount, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
      encoder.endEncoding()
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = targetA
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      pass.colorAttachments[0].storeAction = .store
      guard let renderEncoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
        buffer.commit()
        return
      }
      renderEncoder.setRenderPipelineState(particlePipeline)
      renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
      renderEncoder.setVertexBytes(&canvasVec, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
      renderEncoder.setFragmentTexture(sprite, index: 0)
      renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
      renderEncoder.endEncoding()
      buffer.commit()
      buffer.waitUntilCompleted()
    }
    let distortionTimes = measure(iterations: iterations) {
      guard let buffer = queue.makeCommandBuffer() else { return }
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = targetB
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      pass.colorAttachments[0].storeAction = .store
      guard let renderEncoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
        buffer.commit()
        return
      }
      renderEncoder.setRenderPipelineState(distortPipeline)
      renderEncoder.setFragmentTexture(targetA, index: 0)
      var time: Float = 1
      renderEncoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
      renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      renderEncoder.endEncoding()
      buffer.commit()
      buffer.waitUntilCompleted()
    }
    return (median(particleTimes), median(distortionTimes))
  }

  private static func measure(iterations: Int, work: () -> Void) -> [Double] {
    var times: [Double] = []
    times.reserveCapacity(iterations)
    for _ in 0..<iterations {
      let start = CFAbsoluteTimeGetCurrent()
      work()
      times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    return times
  }

  private static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 0 {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  // -- Metal resources --

  private struct SpikeParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var size: Float
    var alpha: Float
    var age: Float
    var lifetime: Float
  }

  private static func makeParticleBuffer(device: MTLDevice) -> MTLBuffer? {
    var random = ExtraStyleSeededRandom(seed: 0x5350_494b_4500_0001)
    var particles: [SpikeParticle] = []
    particles.reserveCapacity(particleCount)
    for _ in 0..<particleCount {
      particles.append(SpikeParticle(
        position: SIMD2<Float>(
          Float(random.nextDouble()) * 1080, Float(random.nextDouble()) * 1920),
        velocity: SIMD2<Float>(0, -Float(120 + random.nextDouble() * 80)),
        size: Float(8 + random.nextDouble() * 16),
        alpha: 0.9,
        age: Float(random.nextDouble() * 4),
        lifetime: Float(2 + random.nextDouble() * 3)
      ))
    }
    return device.makeBuffer(
      bytes: particles,
      length: MemoryLayout<SpikeParticle>.stride * particleCount,
      options: [.storageModeShared])
  }

  private static func makeTexture(device: MTLDevice, canvas: CGSize) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: Int(canvas.width), height: Int(canvas.height),
      mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    return device.makeTexture(descriptor: descriptor)
  }

  /// The same soft-circle sprite the CI renderer draws (a white
  /// radial blob; the fragment shader tints it acid-lime).
  private static func makeSpriteTexture(device: MTLDevice) -> MTLTexture? {
    let size = 64
    guard let context = CGContext(
      data: nil, width: size, height: size,
      bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
      ] as CFArray,
      locations: [0, 1])
    if let gradient {
      context.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
        endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: CGFloat(size) / 2,
        options: [])
    }
    guard let image = context.makeImage(),
      let data = image.dataProvider?.data as Data?
    else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    texture.replace(
      region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
      withBytes: (data as NSData).bytes, bytesPerRow: size * 4)
    return texture
  }

  private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Particle {
      float2 position;
      float2 velocity;
      float size;
      float alpha;
      float age;
      float lifetime;
    };

    kernel void updateParticles(device Particle *particles [[buffer(0)]],
                                constant float &dt [[buffer(1)]],
                                constant float &seed [[buffer(2)]],
                                constant float2 &canvas [[buffer(3)]],
                                uint id [[thread_position_in_grid]]) {
      Particle p = particles[id];
      p.age += dt;
      p.position += p.velocity * dt;
      if (p.age >= p.lifetime || p.position.y < -p.size) {
        float h = fract(sin(float(id) * 12.9898 + seed) * 43758.5453);
        float h2 = fract(sin(float(id) * 78.233 + seed * 1.7) * 12543.1234);
        p.position = float2(h * canvas.x, canvas.y + p.size);
        p.velocity = float2((h2 - 0.5) * 60.0, -(120.0 + h * 80.0));
        p.age = 0.0;
        p.lifetime = 2.0 + h2 * 3.0;
        p.size = 8.0 + h * 16.0;
      }
      p.alpha = 0.9 * (1.0 - p.age / p.lifetime);
      particles[id] = p;
    }

    struct ParticleOut {
      float4 position [[position]];
      float pointSize [[point_size]];
      float alpha;
    };

    vertex ParticleOut particleVertex(device Particle *particles [[buffer(0)]],
                                      constant float2 &canvas [[buffer(1)]],
                                      uint id [[vertex_id]]) {
      Particle p = particles[id];
      ParticleOut out;
      float2 clip = float2(p.position.x / canvas.x * 2.0 - 1.0,
                           1.0 - p.position.y / canvas.y * 2.0);
      out.position = float4(clip, 0.0, 1.0);
      out.pointSize = p.size;
      out.alpha = p.alpha;
      return out;
    }

    fragment float4 particleFragment(ParticleOut in [[stage_in]],
                                     float2 coord [[point_coord]],
                                     texture2d<float> sprite [[texture(0)]]) {
      constexpr sampler s(coord::normalized, filter::linear);
      float4 tex = sprite.sample(s, coord);
      return float4(0.79, 0.95, 0.42, 1.0) * tex.a * in.alpha;
    }

    struct FullscreenOut {
      float4 position [[position]];
      float2 uv;
    };

    vertex FullscreenOut fullscreenVertex(uint id [[vertex_id]]) {
      float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
      FullscreenOut out;
      out.position = float4(pos[id], 0.0, 1.0);
      out.uv = pos[id] * 0.5 + 0.5;
      out.uv.y = 1.0 - out.uv.y;
      return out;
    }

    fragment float4 distortFragment(FullscreenOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    constant float &time [[buffer(0)]]) {
      constexpr sampler s(coord::normalized, filter::linear);
      float2 uv = in.uv;
      uv.x += 0.012 * sin(uv.y * 40.0 + time * 2.0);
      uv.y += 0.012 * sin(uv.x * 40.0 + time * 1.6);
      return source.sample(s, uv);
    }
    """
}
