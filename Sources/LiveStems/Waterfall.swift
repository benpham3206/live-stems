import CoreGraphics
import Metal
import MetalPerformanceShaders

/// The 3D waterfall's rows, every row each frame, drawn on the GPU into an image: a
/// translucent sheet in the band colours under each glowing line, back to front, in
/// perspective, and a soft bloom of their light over them. Core Graphics alone took 395 ms
/// for this; an incremental bitmap that only shifts the old rows cannot shrink them with
/// depth without blurring them away.
final class Waterfall {
  /// Matches `Stage` in the shader. Floor rows: a homography from (frequency, time, 1) to the
  /// view, 0 to 1 across each side. Shape: pixel size, height of 0 dB at the front left (as a
  /// fraction of the view height), shrink of that height to the back. Counts: rows, bands,
  /// unused, pixels per point.
  struct Stage {
    var x, y, w, shape, counts: SIMD4<Float>
  }
  private let device: MTLDevice, queue: MTLCommandQueue, sheet: MTLRenderPipelineState, line: MTLRenderPipelineState,
    bloom: MTLRenderPipelineState
  private var target: MTLTexture?, glow: MTLTexture?, blur: MPSImageGaussianBlur?, pixels: CGContext?

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw StemError("No Metal device") }
    let library = try device.makeLibrary(source: Self.shader, options: nil)
    /// Premultiplied source-over: a row veils and covers what is behind it, and its glow adds
    /// light. The bloom only adds light.
    func pipeline(_ name: String, covers: Bool = true) throws -> MTLRenderPipelineState {
      let description = MTLRenderPipelineDescriptor()
      description.vertexFunction = library.makeFunction(name: name)
      description.fragmentFunction = library.makeFunction(name: name + "Light")
      let color = description.colorAttachments[0]!
      color.pixelFormat = .bgra8Unorm
      color.isBlendingEnabled = true
      color.sourceRGBBlendFactor = .one
      color.sourceAlphaBlendFactor = covers ? .one : .zero
      color.destinationRGBBlendFactor = covers ? .oneMinusSourceAlpha : .one
      color.destinationAlphaBlendFactor = covers ? .oneMinusSourceAlpha : .one
      return try device.makeRenderPipelineState(descriptor: description)
    }
    (self.device, self.queue) = (device, queue)
    (sheet, line, bloom) = (try pipeline("sheet"), try pipeline("line"), try pipeline("bloom", covers: false))
  }

  /// Heights 0 to 1, `bands` per row, farthest row first, and each row's depth 0 (front) to 1;
  /// hues per band. The image is premultiplied and brighter than its alpha where it glows:
  /// draw it source-over and the glow adds light.
  func render(_ heights: [Float], depths: [Float], hues: [SIMD4<Float>], stage: Stage, width: Int, height: Int) -> CGImage? {
    let rows = Int(stage.counts.x), bands = Int(stage.counts.y)
    guard rows > 0, bands > 1, heights.count == rows * bands, depths.count == rows, hues.count == bands, width > 0, height > 0
    else { return nil }
    if target?.width != width || target?.height != height || blur?.sigma != 4 * stage.counts.w {
      let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      description.usage = [.renderTarget, .shaderRead]
      description.storageMode = .managed
      target = device.makeTexture(descriptor: description)
      description.usage = [.shaderRead, .shaderWrite]
      description.storageMode = .private
      glow = device.makeTexture(descriptor: description)
      blur = MPSImageGaussianBlur(device: device, sigma: 4 * stage.counts.w)
      blur?.edgeMode = .clamp
      pixels = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
    guard let target, let glow, let blur, let pixels, let data = pixels.data,
      let levels = device.makeBuffer(bytes: heights, length: rows * bands * 4),
      let colors = device.makeBuffer(bytes: hues, length: hues.count * 16),
      let rowDepths = device.makeBuffer(bytes: depths, length: rows * 4),
      let commands = queue.makeCommandBuffer() else { return nil }
    func pass(_ load: MTLLoadAction) -> MTLRenderCommandEncoder? {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = load
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
      pass.colorAttachments[0].storeAction = .store
      return commands.makeRenderCommandEncoder(descriptor: pass)
    }
    guard let encoder = pass(.clear) else { return nil }
    var stage = stage
    encoder.setVertexBytes(&stage, length: MemoryLayout<Stage>.stride, index: 0)
    encoder.setFragmentBytes(&stage, length: MemoryLayout<Stage>.stride, index: 0)
    encoder.setVertexBuffer(levels, offset: 0, index: 1)
    encoder.setVertexBuffer(colors, offset: 0, index: 2)
    encoder.setVertexBuffer(rowDepths, offset: 0, index: 3)
    // Back to front, each row's sheet then its line, so nearer rows veil farther ones.
    for row in 0..<rows {
      encoder.setRenderPipelineState(sheet)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: ((bands - 1) * Self.steps + 1) * 2, instanceCount: 1,
        baseInstance: row)
      encoder.setRenderPipelineState(line)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: (bands - 1) * Self.steps * 6, instanceCount: 1, baseInstance: row)
    }
    encoder.endEncoding()
    // The bloom: the rows blurred, their light added back over them.
    blur.encode(commandBuffer: commands, sourceTexture: target, destinationTexture: glow)
    guard let encoder = pass(.load) else { return nil }
    encoder.setRenderPipelineState(bloom)
    encoder.setFragmentTexture(glow, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    commands.makeBlitCommandEncoder().map { $0.synchronize(resource: target); $0.endEncoding() }
    commands.commit()
    commands.waitUntilCompleted()
    target.getBytes(data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return pixels.makeImage()
  }

  /// Curve points per band.
  private static let steps = 4
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Stage { float4 x, y, w, shape, counts; };
    struct Lit { float4 position [[position]]; float4 color; float across; float radius; float fade; };
    constant uint ends[6] = {0, 1, 0, 1, 1, 0};
    constant float sides[6] = {-1, -1, 1, -1, 1, 1};
    constant uint steps = \(steps);  // curve points per band

    // A row's height x bands along: a monotone cubic through its band levels, so peaks round
    // off without overshooting them.
    static float curve(const device float *row, uint bands, float x) {
      uint i = min(uint(x), bands - 2);
      float u = x - i, p0 = row[max(int(i) - 1, 0)], p1 = row[i], p2 = row[i + 1], p3 = row[min(i + 2, bands - 1)];
      float d0 = p1 - p0, d1 = p2 - p1, d2 = p3 - p2;
      float m1 = d0 * d1 <= 0 ? 0 : 2 * d0 * d1 / (d0 + d1), m2 = d1 * d2 <= 0 ? 0 : 2 * d1 * d2 / (d1 + d2);
      return (2 * u * u * u - 3 * u * u + 1) * p1 + (u * u * u - 2 * u * u + u) * m1 + (3 * u * u - 2 * u * u * u) * p2 + (u * u * u - u * u) * m2;
    }
    static float3 hue(const device float4 *hues, uint bands, float x) {
      uint i = min(uint(x), bands - 2);
      return mix(hues[i].rgb, hues[i + 1].rgb, x - i);
    }

    // Pixels, y up: the floor point under (f, t), raised by v of the 0 dB height there.
    static float2 place(constant Stage &s, float f, float t, float v) {
      float3 p = float3(f, t, 1);
      float2 ground = float2(dot(s.x.xyz, p), dot(s.y.xyz, p)) / dot(s.w.xyz, p);
      return (ground + float2(0, v * s.shape.z * (1 - s.shape.w * t))) * s.shape.xy;
    }
    static float4 clip(constant Stage &s, float2 pixel) { return float4(pixel / s.shape.xy * 2 - 1, 0, 1); }
    // How far x stands above the lowest of the row within 0.4 octave: peaks stand out, the
    // body of the spectrum does not, however loud.
    static float prominence(const device float *row, uint bands, float x, float v) {
      int i = int(x + 0.5);
      float low = v;
      for (int k = max(i - 8, 0); k <= min(i + 8, int(bands) - 1); k++) { low = min(low, row[k]); }
      return v - low;
    }
    // How much of a row shows: the newest fade in from clear over the first fifth of the box,
    // so the front edge is a translucent falloff and the peaks stand behind it.
    static float emerge(float t) { return 0.05 + 0.95 * smoothstep(0.0, 0.2, t); }
    // Quiet is blue, rising through violet into the band's own hue where loud and standing
    // out; the tallest peaks burn toward white. Farther rows dim.
    static float3 shade(float v, float rise, float3 hue, float t) {
      float3 c = mix(float3(0.16, 0.34, 1.0), float3(0.55, 0.18, 1.0), smoothstep(0.30, 0.48, v));
      c = mix(c, hue, smoothstep(0.38, 0.62, v) * smoothstep(0.02, 0.14, rise));
      c = mix(c, float3(1.0, 0.97, 0.88), smoothstep(0.90, 1.0, v) * 0.5);
      return c * (0.80 + 0.20 * smoothstep(0.3, 0.8, v)) * (1 - 0.30 * t);
    }

    vertex Lit sheet(uint id [[vertex_id]], uint row [[instance_id]], constant Stage &s [[buffer(0)]],
      const device float *levels [[buffer(1)]], const device float4 *hues [[buffer(2)]], const device float *depths [[buffer(3)]]) {
      uint bands = uint(s.counts.y);
      float x = float(id / 2) / steps, t = depths[row], v = curve(levels + row * bands, bands, x);
      bool top = id % 2 == 0;
      float3 c = shade(v, prominence(levels + row * bands, bands, x, v), hue(hues, bands, x), t);
      Lit out;
      out.position = clip(s, place(s, x / (bands - 1), t, top ? v : 0));
      out.color = float4(c, v);
      out.across = top ? 1 : 0;
      out.radius = 1;
      out.fade = emerge(t);
      return out;
    }
    // A veil over the rows behind, lit just under its top where loud: the peaks glow from within.
    fragment float4 sheetLight(Lit in [[stage_in]]) {
      float v = in.color.a, below = (1 - in.across) * v;  // how far under the top, in box heights
      float light = smoothstep(0.25, 0.95, v) * exp(-below / 0.08), veil = 0.04 + 0.08 * smoothstep(0, 0.3, v) + 0.15 * light;
      return float4(in.color.rgb * 0.2 * light + float3(0.03, 0.07, 0.30) * veil, veil) * in.fade * in.fade;  // the veils clear first: the floor shows through
    }

    vertex Lit line(uint id [[vertex_id]], uint row [[instance_id]], constant Stage &s [[buffer(0)]],
      const device float *levels [[buffer(1)]], const device float4 *hues [[buffer(2)]], const device float *depths [[buffer(3)]]) {
      uint bands = uint(s.counts.y), end = ends[id % 6];
      float xa = float(id / 6) / steps, xb = xa + 1.0 / steps, t = depths[row];
      float va = curve(levels + row * bands, bands, xa), vb = curve(levels + row * bands, bands, xb);
      float2 a = place(s, xa / (bands - 1), t, va), b = place(s, xb / (bands - 1), t, vb);
      float2 along = normalize(b - a + float2(1e-4, 0)), normal = float2(-along.y, along.x);
      // Louder segments glow wider, the bloom around the reference's peaks.
      float v = max(va, vb), radius = (2.5 + 7 * smoothstep(0.45, 1.0, v)) * s.counts.w, side = sides[id % 6] * radius;
      Lit out;
      out.position = clip(s, (end ? b : a) + normal * side);
      float x = end ? xb : xa, at = end ? vb : va;
      out.color = float4(shade(at, prominence(levels + row * bands, bands, x, at), hue(hues, bands, x), t), smoothstep(0.3, 1.0, v));
      out.across = side;
      out.radius = radius;
      out.fade = emerge(t);
      return out;
    }
    // A thin core that covers what is behind it, in a soft halo of added light, wider and
    // brighter where loud.
    fragment float4 lineLight(Lit in [[stage_in]], constant Stage &s [[buffer(0)]]) {
      float d = abs(in.across) / s.counts.w, r = in.radius / s.counts.w;
      float halo = (0.08 + 0.30 * in.color.a) * exp(-4 * d * d / (r * r)) * (1 - smoothstep(0.7 * r, r, d));
      float core = 0.85 * (1 - smoothstep(0.25, 0.8, d));
      return float4(in.color.rgb * (core + halo * 0.7), core) * in.fade;
    }

    // One triangle over the whole view; the blurred rows' light, a third of it, added.
    struct Whole { float4 position [[position]]; };
    vertex Whole bloom(uint id [[vertex_id]]) { return { float4(id == 1 ? 3 : -1, id == 2 ? 3 : -1, 0, 1) }; }
    fragment float4 bloomLight(Whole in [[stage_in]], texture2d<float> glow [[texture(0)]]) {
      return float4(glow.read(uint2(in.position.xy)).rgb * 0.3, 0);
    }
    """
}
