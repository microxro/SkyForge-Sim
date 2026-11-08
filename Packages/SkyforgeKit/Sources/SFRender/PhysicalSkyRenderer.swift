// SKYFORGE — Apache-2.0
// Physically based sky pass: GPU LUTs (AtmosphereLUTGenerator) + fullscreen LUT lookup.
#if canImport(Metal)
import Foundation
import Metal
import SFAtmosphere

struct SkyLUTUniforms {
    var forward: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var sun: SIMD4<Float>
    var params: SIMD4<Float>
}

/// Camera and sun for one sky frame (y up, as SFAtmosphere).
public struct SkyView: Sendable, Equatable {
    public var yawDeg: Double = 0          // relative to north (+x here), counter-clockwise toward +z
    public var pitchDeg: Double = 10
    public var horizontalFOVDeg: Double = 80
    public var sunElevationDeg: Double = 20
    public var sunAzimuthDeg: Double = 0
    public var viewHeightKm: Double = 0.5
    public var exposure: Double = 10
    /// Rotation of the image about the view direction (banked cockpit view), radians-free degrees.
    public var rollDeg: Double = 0
    public init() {}

    public var basis: (forward: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>) {
        let y = yawDeg * .pi / 180, p = pitchDeg * .pi / 180
        let f = SIMD3(cos(p) * cos(y), sin(p), cos(p) * sin(y))
        let r = SIMD3(-sin(y), 0, cos(y))
        let u = SIMD3(r.y * f.z - r.z * f.y, r.z * f.x - r.x * f.z, r.x * f.y - r.y * f.x)
        if rollDeg == 0 { return (f, r, u) }
        let phi = rollDeg * .pi / 180
        return (f, r * cos(phi) + u * sin(phi), u * cos(phi) - r * sin(phi))
    }
}

public final class PhysicalSkyRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let luts: AtmosphereLUTGenerator
    public var parameters = AtmosphereParameters()
    private var cached: (key: SIMD2<Double>, tex: AtmosphereLUTGenerator.Textures)?

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), colorFormat: MTLPixelFormat = .rgba8Unorm) throws {
        guard let device else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandQueue }
        self.device = device
        self.queue = queue
        luts = try AtmosphereLUTGenerator(device: device)
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: AtmosphereShaders.skyPass, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        guard let v = lib.makeFunction(name: "sky_lut_vertex"), let f = lib.makeFunction(name: "sky_lut_fragment") else {
            throw RendererError.shaderCompile("missing sky_lut functions")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "PhysicalSky"
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = colorFormat
        do { pipeline = try device.makeRenderPipelineState(descriptor: d) }
        catch { throw RendererError.pipeline(String(describing: error)) }
    }

    /// LUTs are regenerated only when the sun elevation or the eye height changes.
    func textures(for v: SkyView) throws -> AtmosphereLUTGenerator.Textures {
        let key = SIMD2(v.sunElevationDeg, v.viewHeightKm)
        if let c = cached, c.key == key { return c.tex }
        let t = try luts.generate(parameters, viewHeightKm: v.viewHeightKm, sunZenithCos: sin(v.sunElevationDeg * .pi / 180))
        cached = (key, t)
        return t
    }

    /// Encodes the sky into `pass` (any colour target of the pipeline's format).
    /// `hdr`: write linear radiance × exposure (for an HDR scene buffer tone-mapped later) instead of
    /// tone-mapped, gamma-encoded colour.
    public func encode(into cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor, view v: SkyView, aspect: Double, hdr: Bool = false) throws {
        let tex = try textures(for: v)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.commandQueue }
        let b = v.basis
        let el = v.sunElevationDeg * .pi / 180, az = v.sunAzimuthDeg * .pi / 180
        let sun = SIMD3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
        func f4(_ x: SIMD3<Double>, _ w: Double) -> SIMD4<Float> { SIMD4(Float(x.x), Float(x.y), Float(x.z), Float(w)) }
        var u = SkyLUTUniforms(forward: f4(b.forward, tan(v.horizontalFOVDeg * .pi / 360)), right: f4(b.right, aspect),
                               up: f4(b.up, v.exposure), sun: f4(sun, atan2(sun.z, sun.x)),
                               params: SIMD4(Float(parameters.bottomRadius + v.viewHeightKm), hdr ? 1 : 0, 0, Float(parameters.sunAngularRadius)))
        var a = AtmosphereGPUParams(parameters, viewHeightKm: v.viewHeightKm, sunZenithCos: sin(el))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<SkyLUTUniforms>.stride, index: 0)
        enc.setFragmentBytes(&a, length: MemoryLayout<AtmosphereGPUParams>.stride, index: 1)
        enc.setFragmentTexture(tex.skyView, index: 0)
        enc.setFragmentTexture(tex.transmittance, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Offscreen render to RGB8 (visual regression).
    public func render(width: Int, height: Int, view v: SkyView) throws -> [UInt8] {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        guard let target = device.makeTexture(descriptor: td),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer() else { throw RendererError.commandQueue }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try encode(into: cmd, pass: pass, view: v, aspect: Double(width) / Double(height))
        guard let blit = cmd.makeBlitCommandEncoder() else { throw RendererError.commandQueue }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error { throw RendererError.pipeline(String(describing: e)) }
        let src = readback.contents().bindMemory(to: UInt8.self, capacity: width * height * 4)
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for p in 0..<(width * height) { out[3 * p] = src[4 * p]; out[3 * p + 1] = src[4 * p + 1]; out[3 * p + 2] = src[4 * p + 2] }
        return out
    }
}

#if canImport(MetalKit)
import MetalKit

/// On-screen driver: sweeps the sun from 30° to −6° and back over two minutes so the preview
/// shows day, golden hour, sunset and twilight from the same LUT pipeline the tests verify.
@MainActor
public final class PhysicalSkyViewDelegate: NSObject, MTKViewDelegate {
    private let renderer: PhysicalSkyRenderer
    private let queue: MTLCommandQueue
    private let start = Date()
    public var view = SkyView()

    public init(view mtk: MTKView) throws {
        guard let device = mtk.device ?? MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else {
            throw RendererError.noDevice
        }
        mtk.device = device
        mtk.colorPixelFormat = .bgra8Unorm
        renderer = try PhysicalSkyRenderer(device: device, colorFormat: .bgra8Unorm)
        queue = q
        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in mtk: MTKView) {
        guard let pass = mtk.currentRenderPassDescriptor, let drawable = mtk.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        let t = Date().timeIntervalSince(start)
        // Quantised to 0.25° so LUTs regenerate a few times per second at most.
        let el = 12 + 18 * cos(t / 120 * 2 * .pi)
        view.sunElevationDeg = (el * 4).rounded() / 4
        view.exposure = 10 * pow(2, max(0, (8 - view.sunElevationDeg) / 4))
        let size = mtk.drawableSize
        try? renderer.encode(into: cmd, pass: pass, view: view, aspect: size.height > 0 ? Double(size.width / size.height) : 1)
        cmd.present(drawable)
        cmd.commit()
    }
}
#endif
#endif
