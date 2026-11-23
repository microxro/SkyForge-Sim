// SKYFORGE — Apache-2.0
// Night sky pass: stars, moon, Milky Way and airglow from NightShaders (nt_sky_fragment, nt_star_vertex /
// nt_star_fragment), additive over the sky and before the terrain. Terrain is opaque and overwrites the stars
// and moon below the horizon, so no depth buffer is needed.
#if canImport(Metal)
import Foundation
import Metal
import simd

final class NightSkyPass {
    private let skyPipeline: MTLRenderPipelineState
    private let starPipeline: MTLRenderPipelineState
    private var starBuffer: MTLBuffer?
    private var starCount = 0
    private var starTier: NightTier?

    init(device: MTLDevice, colorFormat: MTLPixelFormat) throws {
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: NightShaders.source, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        guard let skyV = lib.makeFunction(name: "nt_full_vertex"), let skyF = lib.makeFunction(name: "nt_sky_fragment"),
              let starV = lib.makeFunction(name: "nt_star_vertex"), let starF = lib.makeFunction(name: "nt_star_fragment") else {
            throw RendererError.shaderCompile("missing nt_sky or nt_star functions")
        }
        func additive(_ d: MTLRenderPipelineDescriptor) {
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = colorFormat
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .zero; ca.destinationAlphaBlendFactor = .one
        }
        let sd = MTLRenderPipelineDescriptor()
        sd.label = "NightSky"
        sd.vertexFunction = skyV
        sd.fragmentFunction = skyF
        additive(sd)
        let td = MTLRenderPipelineDescriptor()
        td.label = "NightStars"
        td.vertexFunction = starV
        td.fragmentFunction = starF
        additive(td)
        do {
            skyPipeline = try device.makeRenderPipelineState(descriptor: sd)
            starPipeline = try device.makeRenderPipelineState(descriptor: td)
        } catch { throw RendererError.pipeline(String(describing: error)) }
    }

    /// Night state for a sun direction (ENU, from the lighting setup) and a clock time. Star and moon positions
    /// come from the clock and the observer's place; the sun, its elevation and the darkness it implies come from
    /// `sun`, so the sky always matches the chosen time of day.
    static func state(sun: SIMD3<Float>, unix: Double, latDeg: Double, lonDeg: Double) -> NightSkyState {
        var s = NightSkyState(unix: unix, latDeg: latDeg, lonDeg: lonDeg)
        let u = simd_normalize(sun)
        s.sunENU = SIMD3<Double>(Double(u.x), Double(u.y), Double(u.z))
        s.sunElevationDeg = Float(asin(max(-1, min(1, Double(u.z)))) * 180 / .pi)
        s.darkness = NightModel.darkness(sunElevationDeg: s.sunElevationDeg)
        s.limitingMagnitude = NightModel.limitingMagnitude(sunElevationDeg: s.sunElevationDeg)
        s.twilight = NightModel.twilight(sunElevationDeg: s.sunElevationDeg)
        return s
    }

    /// Adds the night sky to `colour` (the scene target, after the sky pass and before terrain).
    func encode(cmd: MTLCommandBuffer, device: MTLDevice, colour: MTLTexture, state: NightSkyState,
                tier: NightTier, camera: WorldCamera, time: Float) throws {
        if starBuffer == nil || starTier != tier {
            let packed = StarField.pack(StarField.generate(tier: tier))
            starCount = packed.count / 2
            starBuffer = device.makeBuffer(bytes: packed, length: packed.count * MemoryLayout<SIMD4<Float>>.stride,
                                           options: .storageModeShared)
            starTier = tier
        }
        guard let stars = starBuffer, starCount > 0 else { throw RendererError.commandQueue }

        let fwdD = simd_normalize(camera.target - camera.position)
        let fwd = SIMD3<Float>(Float(fwdD.x), Float(fwdD.y), Float(fwdD.z))
        let upF = SIMD3<Float>(Float(camera.up.x), Float(camera.up.y), Float(camera.up.z))
        let right = simd_normalize(simd_cross(fwd, upF))
        let up = simd_cross(right, fwd)
        let vfov = Float(camera.verticalFOVDeg) * .pi / 180
        let viewport = SIMD2<Float>(Float(colour.width), Float(colour.height))
        var u = NightSkyUniforms(state: state, tier: tier, right: right, up: up, forward: fwd, verticalFOV: vfov,
                                 viewport: viewport, time: time, near: Float(camera.near))

        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = colour
        pd.colorAttachments[0].loadAction = .load
        pd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pd) else { throw RendererError.commandQueue }
        enc.label = "Night sky"
        enc.setRenderPipelineState(skyPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<NightSkyUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.setRenderPipelineState(starPipeline)
        enc.setVertexBuffer(stars, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<NightSkyUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
        enc.endEncoding()
    }
}
#endif
