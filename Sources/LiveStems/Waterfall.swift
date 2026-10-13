import AppKit
import Metal
import MetalKit
import MetalPerformanceShaders

/// Where the 3D view looks from: an orbit around the box's centre, from the reference's
/// view, fitted to its box corners. At that view the box fills the view less a margin for the
/// labels, centred, as large as the height allows: a wide window adds room at the sides.
struct Camera: Equatable {
  static let reference = Camera(yaw: 0.4463, pitch: 0.3513)
  /// Box size: frequency across, 0 dB up, time back. Eye distance and vertical field of view.
  static let box = SIMD3<Float>(1, 0.2779, 0.6473), distance: Float = 1.9204, fov: Float = 20 * .pi / 180
  /// Room for the axis labels around the box at the reference view, in points.
  static let margin = (left: Float(66), right: Float(96), bottom: Float(40), top: Float(12))
  var yaw: Float, pitch: Float, zoom: Float = 1

  mutating func turn(dx: Float, dy: Float) {
    yaw = (yaw - dx).truncatingRemainder(dividingBy: 2 * .pi)
    pitch = min(89 * .pi / 180, max(-89 * .pi / 180, pitch - dy))
  }
  /// Grows the picture by e^steps, from half size to 4×.
  mutating func magnify(_ steps: Float) { zoom = min(4, max(0.5, zoom * exp(steps))) }
  /// The eye in box units: (frequency, time, height), each 0 to 1 across the box.
  var eye: SIMD3<Float> {
    let world = SIMD3(Self.distance * cos(pitch) * sin(yaw), Self.box.y / 2 + Self.distance * sin(pitch), Self.distance * cos(pitch) * cos(yaw))
    return SIMD3(world.x + 0.5, 0.5 - world.z / Self.box.z, world.y / Self.box.y)
  }
  /// (frequency, time, height, 1) to the camera's x right, y up, z back toward the eye.
  private var place: simd_float4x4 {
    let size = Self.box, target = SIMD3<Float>(0, size.y / 2, 0), corner = SIMD3<Float>(-0.5, 0, size.z / 2)
    let eye = target + Self.distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    let forward = simd_normalize(target - eye), right = simd_normalize(simd_cross(forward, [0, 1, 0])), up = simd_cross(right, forward)
    return simd_float4x4(columns: (
      SIMD4(size.x * right.x, size.x * up.x, -size.x * forward.x, 0),
      SIMD4(-size.z * right.z, -size.z * up.z, size.z * forward.z, 0),
      SIMD4(size.y * right.y, size.y * up.y, -size.y * forward.y, 0),
      SIMD4(simd_dot(right, corner - eye), simd_dot(up, corner - eye), -simd_dot(forward, corner - eye), 1)))
  }
  private static let focal = 1 / tan(fov / 2)
  /// The box at the reference view, as focal length times x and y over depth: what the view fits.
  private static let extent: (lo: SIMD2<Float>, hi: SIMD2<Float>) = {
    let corners = (0..<8).map { i -> SIMD2<Float> in
      let c = reference.place * SIMD4(Float(i & 1), Float(i >> 1 & 1), Float(i >> 2 & 1), 1)
      return SIMD2(c.x, c.y) * focal / -c.z
    }
    return (corners.reduce(corners[0], simd_min), corners.reduce(corners[0], simd_max))
  }()
  /// (frequency, time, height, 1) to clip space, in a view this many pixels across at this
  /// many pixels per point.
  func clip(width: Float, height: Float, scale: Float = 1) -> simd_float4x4 {
    let m = Self.margin, e = Self.extent
    let room = SIMD2(width - (m.left + m.right) * scale, height - (m.bottom + m.top) * scale)
    let k = zoom * max(1e-3, min(room.x / (e.hi.x - e.lo.x), room.y / (e.hi.y - e.lo.y)))  // pixels per focal unit
    let offset = SIMD2(m.left - m.right, m.bottom - m.top) * scale / 2 - k * (e.lo + e.hi) / 2  // from the view's centre
    let project = simd_float4x4(columns: (
      SIMD4(2 * k * Self.focal / width, 0, 0, 0), SIMD4(0, 2 * k * Self.focal / height, 0, 0),
      SIMD4(-2 * offset.x / width, -2 * offset.y / height, -0.5, -1), SIMD4(0, 0, 0, 0)))
    return project * place
  }
  /// A box point in view points, y up; nil behind the eye.
  func point(_ p: SIMD3<Float>, in size: CGSize) -> CGPoint? {
    let c = clip(width: Float(size.width), height: Float(size.height)) * SIMD4(p, 1)
    guard c.w > 1e-4 else { return nil }
    return CGPoint(x: CGFloat((c.x / c.w + 1) / 2) * size.width, y: CGFloat((c.y / c.w + 1) / 2) * size.height)
  }
}

/// The 3D waterfall on the GPU, drawn straight into its view: every other row a glowing
/// hairline over a faint veil, in perspective from any angle, far rows first so near ones veil
/// them, and a bloom of their light. The rows live in a ring on the GPU; a new row is one copy.
final class Waterfall {
  /// A grid line from a to b, (frequency, time, height, 1), and its premultiplied colour.
  struct Segment {
    var a, b, color: SIMD4<Float>
  }
  /// Matches `Frame` in the shader.
  private struct Frame {
    var clip: simd_float4x4
    var pixels: SIMD2<Float>
    var scale: Float
    var bands, capacity, newest, full, linear: UInt32
    var ground: Float
  }
  /// Ten seconds of rows and one spare, so the row being replaced is never one being drawn.
  // ceiling: 10 s at 30 rows/s; a longer span needs a bigger ring (1.6 kB a row).
  static let capacity = 10 * SpectrumView.rowsPerSecond + 1
  let device: MTLDevice
  private let queue: MTLCommandQueue, rowState: MTLRenderPipelineState, gridState: MTLRenderPipelineState,
    floorState: MTLRenderPipelineState, finish: MTLRenderPipelineState
  private let ring: MTLBuffer, order: MTLBuffer
  private var hueBuffer: MTLBuffer?, gridBuffer: MTLBuffer?, gridCount = 0
  private var scene: MTLTexture?, glow: MTLTexture?, blur: MPSImageGaussianBlur?
  private var newest = 0, count = 0, pushed = 0
  var camera = Camera.reference, seconds = 5, linear = false

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw StemError("No Metal device") }
    // ceiling: the shader compiles at launch, some milliseconds; a .metallib built with the app if that shows.
    let library = try device.makeLibrary(source: Self.shader, options: nil)
    /// Premultiplied source-over: veils cover what is behind them, light adds. The last pass
    /// writes the finished view.
    func pipeline(_ vertex: String, _ fragment: String, blend: Bool = true) throws -> MTLRenderPipelineState {
      let description = MTLRenderPipelineDescriptor()
      description.vertexFunction = library.makeFunction(name: vertex)
      description.fragmentFunction = library.makeFunction(name: fragment)
      let color = description.colorAttachments[0]!
      color.pixelFormat = .bgra8Unorm
      color.isBlendingEnabled = blend
      color.sourceRGBBlendFactor = .one
      color.sourceAlphaBlendFactor = .one
      color.destinationRGBBlendFactor = .oneMinusSourceAlpha
      color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      return try device.makeRenderPipelineState(descriptor: description)
    }
    guard let ring = device.makeBuffer(length: Self.capacity * SpectrumAnalyzer.bands * 4, options: .storageModeShared),
      let order = device.makeBuffer(length: Self.capacity * 4, options: .storageModeShared) else { throw StemError("No GPU memory") }
    (self.device, self.queue, self.ring, self.order) = (device, queue, ring, order)
    rowState = try pipeline("row", "rowLight")
    gridState = try pipeline("segment", "segmentLight")
    floorState = try pipeline("ground", "groundLight")
    finish = try pipeline("whole", "wholeLight", blend: false)
  }

  /// A new row of band levels in dB, the newest.
  func push(_ levels: [Float]) {
    guard levels.count == SpectrumAnalyzer.bands else { return }
    newest = count == 0 ? 0 : (newest + 1) % Self.capacity
    count = min(Self.capacity - 1, count + 1)
    pushed += 1
    levels.withUnsafeBytes { ring.contents().advanced(by: newest * levels.count * 4).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
  }
  func clear() { count = 0 }
  /// Each band's colour.
  var hues: [SIMD4<Float>] = [] { didSet { hueBuffer = device.makeBuffer(bytes: hues, length: hues.count * 16) } }
  var grid: [Segment] = [] {
    didSet {
      gridCount = grid.count
      gridBuffer = grid.isEmpty ? nil : device.makeBuffer(bytes: grid, length: grid.count * MemoryLayout<Segment>.stride)
    }
  }

  /// Draws into the view's next drawable and presents it.
  func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable, let commands = queue.makeCommandBuffer() else { return }
    encode(commands, to: drawable.texture, scale: Float(view.window?.backingScaleFactor ?? 2))
    commands.present(drawable)
    commands.commit()
  }

  /// The view drawn off screen: for checks and pictures. `read` false skips the copy back.
  func snapshot(width: Int, height: Int, scale: Float, read: Bool = true) -> CGImage? {
    let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    description.usage = .renderTarget
    description.storageMode = .managed
    guard let target = device.makeTexture(descriptor: description), let commands = queue.makeCommandBuffer() else { return nil }
    encode(commands, to: target, scale: scale)
    if read { commands.makeBlitCommandEncoder().map { $0.synchronize(resource: target); $0.endEncoding() } }
    commands.commit()
    commands.waitUntilCompleted()
    guard read, let pixels = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), let data = pixels.data
    else { return nil }
    target.getBytes(data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return pixels.makeImage()
  }

  private func encode(_ commands: MTLCommandBuffer, to target: MTLTexture, scale: Float) {
    let width = target.width, height = target.height
    if scene?.width != width || scene?.height != height || blur?.sigma != 4 * scale {
      let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      description.usage = [.renderTarget, .shaderRead]
      description.storageMode = .private
      scene = device.makeTexture(descriptor: description)
      description.usage = [.shaderRead, .shaderWrite]
      glow = device.makeTexture(descriptor: description)
      blur = MPSImageGaussianBlur(device: device, sigma: 4 * scale)
      blur?.edgeMode = .clamp
    }
    guard let scene, let glow, let blur, let hueBuffer else { return }
    // Depth is age over the whole span, so a new row starts receding at once, as the old trail did.
    let full = seconds * SpectrumView.rowsPerSecond, shown = min(count, full)
    // Every other row, as the reference's ridges are spaced, chosen by its place in the whole
    // stream so a row keeps being drawn as it recedes. Far rows first: by how far each row's
    // plane lies from the eye along time.
    let eye = camera.eye, span = Float(max(1, full - 1))
    let rows = (0..<shown).filter { (pushed - 1 - $0) % 2 == 0 }
      .map { age in ((newest - age + Self.capacity) % Self.capacity, abs(Float(age) / span - eye.y)) }
      .sorted { $0.1 > $1.1 }.map { UInt32($0.0) }
    rows.withUnsafeBytes { if $0.count > 0 { order.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
    var frame = Frame(clip: camera.clip(width: Float(width), height: Float(height), scale: scale), pixels: [Float(width), Float(height)], scale: scale,
      bands: UInt32(SpectrumAnalyzer.bands), capacity: UInt32(Self.capacity), newest: UInt32(newest), full: UInt32(full),
      linear: linear ? 1 : 0, ground: eye.z < 0 ? 0.06 : 0.25)
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = scene
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store
    guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
    encoder.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
    encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
    // The floor, its grid and the walls', then the rows; from below the floor, the floor last.
    func ground() {
      encoder.setRenderPipelineState(floorState)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      if let gridBuffer {
        encoder.setRenderPipelineState(gridState)
        encoder.setVertexBuffer(gridBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gridCount * 6)
      }
    }
    if eye.z >= 0 { ground() }
    if !rows.isEmpty {
      encoder.setRenderPipelineState(rowState)
      encoder.setVertexBuffer(ring, offset: 0, index: 1)
      encoder.setVertexBuffer(hueBuffer, offset: 0, index: 2)
      encoder.setVertexBuffer(order, offset: 0, index: 3)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: (SpectrumAnalyzer.bands - 1) * 12, instanceCount: rows.count)
    }
    if eye.z < 0 { ground() }
    encoder.endEncoding()
    blur.encode(commandBuffer: commands, sourceTexture: scene, destinationTexture: glow)
    pass.colorAttachments[0].texture = target
    guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
    encoder.setRenderPipelineState(finish)
    encoder.setFragmentTexture(scene, index: 0)
    encoder.setFragmentTexture(glow, index: 1)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }

  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Frame { float4x4 clip; float2 pixels; float scale; uint bands, capacity, newest, full, linear; float ground; };
    struct Lit { float4 position [[position]]; float4 color; float across; float width; float fade; };
    constant uint sheetEnds[6] = {0, 0, 1, 1, 0, 1};
    constant float sheetTops[6] = {1, 0, 1, 1, 0, 0};
    constant uint lineEnds[6] = {0, 1, 0, 1, 1, 0};
    constant float sides[6] = {-1, -1, 1, -1, 1, 1};

    static float height(float db, uint linear) { return linear ? min(1.0, pow(10.0, db / 20)) : clamp((db + 120) / 120, 0.0, 1.0); }
    // How far v stands above the lowest within 0.4 octave: peaks stand out, the body does not, however loud.
    static float prominence(const device float *row, uint bands, uint i, float v, uint linear) {
      float low = v;
      for (int k = max(int(i) - 16, 0); k <= min(int(i) + 16, int(bands) - 1); k++) { low = min(low, height(row[k], linear)); }
      return v - low;
    }
    // Quiet is blue, rising through violet into the band's own hue where loud and standing
    // out; the tallest peaks burn toward white. Older rows dim.
    static float3 shade(float v, float rise, float3 hue, float t) {
      float3 c = mix(float3(0.16, 0.34, 1.0), float3(0.55, 0.18, 1.0), smoothstep(0.30, 0.48, v));
      c = mix(c, hue, smoothstep(0.38, 0.62, v) * smoothstep(0.02, 0.14, rise));
      c = mix(c, float3(1.0, 0.97, 0.88), smoothstep(0.90, 1.0, v) * 0.5);
      return c * (0.80 + 0.20 * smoothstep(0.3, 0.8, v)) * (1 - 0.50 * t);  // half as bright at the back of the span
    }
    // The newest rows fade in from clear over the first fifth of the box: a soft front edge.
    static float emerge(float t) { return 0.05 + 0.95 * smoothstep(0.0, 0.2, t); }
    // A point pushed sideways from the line a to b by this many pixels, in clip space.
    static float4 widen(constant Frame &f, float4 a, float4 b, bool end, float pixels) {
      float2 pa = a.xy / a.w * f.pixels / 2, pb = b.xy / b.w * f.pixels / 2;
      float2 along = normalize(pb - pa + float2(1e-4, 0)), normal = float2(-along.y, along.x);
      float4 p = end ? b : a;
      p.xy += normal * pixels / (f.pixels / 2) * p.w;
      return p;
    }

    // Each row: a veil from the floor up to the levels, then a hairline along them.
    vertex Lit row(uint id [[vertex_id]], uint instance [[instance_id]], constant Frame &f [[buffer(0)]],
      const device float *ring [[buffer(1)]], const device float4 *hues [[buffer(2)]], const device uint *order [[buffer(3)]]) {
      uint index = order[instance], age = (f.newest + f.capacity - index) % f.capacity, sheet = (f.bands - 1) * 6;
      const device float *levels = ring + index * f.bands;
      float t = float(age) / max(1.0, float(f.full - 1));
      bool line = id >= sheet;
      uint corner = id % 6, i = (id % sheet) / 6, at = i + (line ? lineEnds[corner] : sheetEnds[corner]);
      float va = height(levels[i], f.linear), vb = height(levels[i + 1], f.linear), v = height(levels[at], f.linear);
      float xa = float(i) / (f.bands - 1), xb = float(i + 1) / (f.bands - 1);
      Lit out;
      out.color = float4(shade(v, prominence(levels, f.bands, at, v, f.linear), hues[at].rgb, t), v);
      if (line) {
        float4 a = f.clip * float4(xa, t, va, 1), b = f.clip * float4(xb, t, vb, 1);
        // Out to the edge of the halo, wider where loud; the glow's strength rides in alpha.
        float loud = max(va, vb);
        out.width = (2.5 + 7 * smoothstep(0.45, 1.0, loud)) * f.scale;
        out.color.a = smoothstep(0.3, 1.0, loud);
        out.across = sides[corner] * out.width;
        out.position = widen(f, a, b, lineEnds[corner], out.across);
      } else {
        out.position = f.clip * float4(float(at) / (f.bands - 1), t, sheetTops[corner] * v, 1);
        out.across = sheetTops[corner];
        out.width = -1;
      }
      out.fade = emerge(t);
      return out;
    }
    fragment float4 rowLight(Lit in [[stage_in]], constant Frame &f [[buffer(0)]]) {
      float v = in.color.a;
      if (in.width < 0) {
        // A veil over the rows behind, lit just under its top where loud: the peaks glow from within.
        float below = (1 - in.across) * v, light = smoothstep(0.25, 0.95, v) * exp(-below / 0.08);
        float veil = 0.04 + 0.08 * smoothstep(0, 0.3, v) + 0.15 * light;
        return float4(in.color.rgb * 0.2 * light + float3(0.03, 0.07, 0.30) * veil, veil) * in.fade * in.fade;
      }
      // A hairline half a point wide, with a pixel of soft edge, that covers what is behind it,
      // in a soft halo of added light, wider and brighter where loud. Distances in points.
      float d = abs(in.across) / f.scale, r = in.width / f.scale;
      float halo = (0.08 + 0.30 * v) * exp(-4 * d * d / (r * r)) * (1 - smoothstep(0.7 * r, r, d));
      float core = 0.85 * clamp(0.25 * f.scale + 0.5 - abs(in.across), 0.0, 1.0);
      return float4(in.color.rgb * (1.4 * core + halo * 0.7), core) * in.fade;
    }

    struct Segment { float4 a, b, color; };
    vertex Lit segment(uint id [[vertex_id]], constant Frame &f [[buffer(0)]], const device Segment *segments [[buffer(1)]]) {
      Segment s = segments[id / 6];
      uint corner = id % 6;
      Lit out;
      out.width = 0.375 * f.scale;
      out.across = sides[corner] * (out.width + 1);
      out.position = widen(f, f.clip * s.a, f.clip * s.b, lineEnds[corner], out.across);
      out.color = s.color;
      out.fade = 1;
      return out;
    }
    fragment float4 segmentLight(Lit in [[stage_in]]) { return in.color * clamp(in.width + 0.5 - abs(in.across), 0.0, 1.0); }

    // The floor: a faint blue square under the rows, glass-thin seen from below.
    constant float2 corners[6] = {{0, 0}, {1, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 1}};
    vertex Lit ground(uint id [[vertex_id]], constant Frame &f [[buffer(0)]]) {
      Lit out;
      out.position = f.clip * float4(corners[id], 0, 1);
      out.color = float4(0.05, 0.10, 0.34, 1) * f.ground;
      return out;
    }
    fragment float4 groundLight(Lit in [[stage_in]]) { return in.color; }

    // The finished view: the scene and a third of its blurred light added over it.
    struct Whole { float4 position [[position]]; };
    vertex Whole whole(uint id [[vertex_id]]) { return { float4(id == 1 ? 3 : -1, id == 2 ? 3 : -1, 0, 1) }; }
    fragment float4 wholeLight(Whole in [[stage_in]], texture2d<float> scene [[texture(0)]], texture2d<float> glow [[texture(1)]]) {
      uint2 at = uint2(in.position.xy);
      float4 c = scene.read(at);
      return float4(min(c.rgb + glow.read(at).rgb * 0.3, 1.0), c.a);
    }
    """
}
