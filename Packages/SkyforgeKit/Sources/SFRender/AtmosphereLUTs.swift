// SKYFORGE — Apache-2.0
// GPU generation of the Hillaire sky LUTs; textures feed the sky pass, read-back feeds tests.
#if canImport(Metal)
import Foundation
import Metal
import SFAtmosphere

/// Matches `Atmo` in AtmosphereShaders.source (eight float4s, no padding surprises).
struct AtmosphereGPUParams {
    var radii: SIMD4<Float>
    var rayleigh: SIMD4<Float>
    var mieScat: SIMD4<Float>
    var mieExt: SIMD4<Float>
    var ozone: SIMD4<Float>
    var ground: SIMD4<Float>
    var sun: SIMD4<Float>
    var solar: SIMD4<Float>

    init(_ p: AtmosphereParameters, viewHeightKm: Double, sunZenithCos: Double) {
        func f4(_ v: SIMD3<Double>, _ w: Double) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w)) }
        radii = SIMD4(Float(p.bottomRadius), Float(p.topRadius), Float(p.rayleighScaleHeight), Float(p.mieScaleHeight))
        rayleigh = f4(p.rayleighScattering, p.mieG)
        mieScat = f4(p.mieScattering, p.turbidity)
        mieExt = f4(p.mieExtinction, p.ozoneCenter)
        ozone = f4(p.ozoneAbsorption, p.ozoneWidth)
        ground = f4(p.groundAlbedo, viewHeightKm)
        sun = SIMD4(0, 0, 0, Float(sunZenithCos))
        solar = f4(p.solarIrradiance, 0)
    }
}

public final class AtmosphereLUTGenerator {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let transmittancePSO: MTLComputePipelineState
    private let multiScatterPSO: MTLComputePipelineState
    private let skyViewPSO: MTLComputePipelineState

    public struct Textures {
        public let transmittance: MTLTexture
        public let multiScattering: MTLTexture
        public let skyView: MTLTexture
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandQueue }
        self.device = device
        self.queue = queue
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: AtmosphereShaders.source, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        func pso(_ name: String) throws -> MTLComputePipelineState {
            guard let f = lib.makeFunction(name: name) else { throw RendererError.shaderCompile("missing \(name)") }
            do { return try device.makeComputePipelineState(function: f) }
            catch { throw RendererError.pipeline(String(describing: error)) }
        }
        transmittancePSO = try pso("transmittance_lut")
        multiScatterPSO = try pso("multiscatter_lut")
        skyViewPSO = try pso("skyview_lut")
    }

    private func texture(_ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
        return t
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
        enc.setComputePipelineState(pso)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: 1), threadsPerThreadgroup: tg)
    }

    public func generate(_ p: AtmosphereParameters, viewHeightKm: Double, sunZenithCos: Double) throws -> Textures {
        let ts = SkyAtmosphere.transmittanceSize, ms = SkyAtmosphere.multiScatteringSize, sv = SkyAtmosphere.skyViewSize
        let t = try texture(ts.w, ts.h), m = try texture(ms, ms), s = try texture(sv.w, sv.h)
        var params = AtmosphereGPUParams(p, viewHeightKm: viewHeightKm, sunZenithCos: sunZenithCos)
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw RendererError.commandQueue }
        enc.setBytes(&params, length: MemoryLayout<AtmosphereGPUParams>.stride, index: 0)
        enc.setTexture(t, index: 0)
        dispatch(enc, transmittancePSO, ts.w, ts.h)
        enc.memoryBarrier(scope: .textures)
        enc.setTexture(m, index: 0); enc.setTexture(t, index: 1)
        dispatch(enc, multiScatterPSO, ms, ms)
        enc.memoryBarrier(scope: .textures)
        enc.setTexture(s, index: 0); enc.setTexture(t, index: 1); enc.setTexture(m, index: 2)
        dispatch(enc, skyViewPSO, sv.w, sv.h)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error { throw RendererError.pipeline(String(describing: e)) }
        return Textures(transmittance: t, multiScattering: m, skyView: s)
    }

    /// Reads an rgba32Float texture back as RGB triples (tests and diagnostics).
    public func readBack(_ tex: MTLTexture) throws -> [SIMD3<Float>] {
        let w = tex.width, h = tex.height
        guard let buf = device.makeBuffer(length: w * h * 16, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { throw RendererError.commandQueue }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: w * 16, destinationBytesPerImage: w * h * 16)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let p = buf.contents().bindMemory(to: SIMD4<Float>.self, capacity: w * h)
        return (0..<(w * h)).map { SIMD3(p[$0].x, p[$0].y, p[$0].z) }
    }
}
#endif
