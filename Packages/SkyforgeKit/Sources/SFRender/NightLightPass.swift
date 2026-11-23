// SKYFORGE — Apache-2.0
// Night-light sprite pass: draws `NightLight`s (traffic nav and strobe lights, beacons, runway and PAPI lights)
// additively over the HDR scene with NightShaders' nt_light_vertex / nt_light_fragment. Depth-tested
// (reversed-Z, .greater, no writes) so terrain and buildings occlude distant lights.
#if canImport(Metal)
import Foundation
import Metal
import simd

final class NightLightPass {
    /// Upper bound on sprites per frame (the host's traffic and airport lights are far below this).
    static let maxLights = 512

    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var lightBuffer: MTLBuffer?

    init(device: MTLDevice, colorFormat: MTLPixelFormat) throws {
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: NightShaders.source, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        guard let v = lib.makeFunction(name: "nt_light_vertex"), let f = lib.makeFunction(name: "nt_light_fragment") else {
            throw RendererError.shaderCompile("missing nt_light functions")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "NightLights"
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = colorFormat
        let ca = d.colorAttachments[0]!
        ca.isBlendingEnabled = true                       // additive: the sprites only add light
        ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .zero; ca.destinationAlphaBlendFactor = .one
        d.depthAttachmentPixelFormat = .depth32Float
        do { pipeline = try device.makeRenderPipelineState(descriptor: d) }
        catch { throw RendererError.pipeline(String(describing: error)) }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .greater                // reversed-Z: nearer than the stored depth
        ds.isDepthWriteEnabled = false
        guard let dss = device.makeDepthStencilState(descriptor: ds) else { throw RendererError.commandQueue }
        depthState = dss
    }

    /// Encodes the sprites into `colour` (the scene target) against `depth` (the scene depth).
    /// `camera` is in the renderer's world frame; sprite positions are made camera-relative here.
    /// `intensityScale` fades the lights in at dusk (0 = none, 1 = full).
    func encode(cmd: MTLCommandBuffer, device: MTLDevice, colour: MTLTexture, depth: MTLTexture, camera: WorldCamera,
                lights: [NightLight], intensityScale: Float, time: Float, tier: NightTier = .high) throws {
        let used = Array(lights.prefix(Self.maxLights))
        guard !used.isEmpty, intensityScale > 0 else { return }
        let cam = SIMD3<Double>(camera.position.x, camera.position.y, camera.position.z)
        var data = [SIMD4<Float>]()
        data.reserveCapacity(used.count * 4)
        for light in used {
            var p = light.packed()
            let rel = SIMD3<Double>(Double(light.position.x), Double(light.position.y), Double(light.position.z)) - cam
            p[0] = SIMD4(Float(rel.x), Float(rel.y), Float(rel.z), p[0].w)
            p[1].w *= intensityScale
            data.append(contentsOf: p)
        }
        let byteCount = data.count * MemoryLayout<SIMD4<Float>>.stride
        if lightBuffer == nil || lightBuffer!.length < byteCount {
            lightBuffer = device.makeBuffer(length: NightLightPass.maxLights * 4 * MemoryLayout<SIMD4<Float>>.stride,
                                            options: .storageModeShared)
        }
        guard let buffer = lightBuffer else { throw RendererError.commandQueue }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { buffer.contents().copyMemory(from: base, byteCount: byteCount) }
        }

        // Camera basis for the sprite shader (camera-relative, so the camera position itself is zero).
        let fwdD = simd_normalize(camera.target - camera.position)
        let fwd = SIMD3<Float>(Float(fwdD.x), Float(fwdD.y), Float(fwdD.z))
        let upF = SIMD3<Float>(Float(camera.up.x), Float(camera.up.y), Float(camera.up.z))
        let right = simd_normalize(simd_cross(fwd, upF))
        let up = simd_cross(right, fwd)
        let tanV = tan(Float(camera.verticalFOVDeg) * .pi / 360)
        let w = Float(colour.width), h = Float(colour.height)
        var u = NightSkyUniforms()
        u.camRight = SIMD4(right, 0); u.camUp = SIMD4(up, 0); u.camFwd = SIMD4(fwd, 0)
        u.view = SIMD4(tanV * w / max(1, h), tanV, 2 * tanV / max(1, h), time)
        u.sprite = SIMD4(tier.minSpritePixels, 40_000, h / (2 * tanV), Float(camera.near))

        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = colour
        pd.colorAttachments[0].loadAction = .load
        pd.colorAttachments[0].storeAction = .store
        pd.depthAttachment.texture = depth
        pd.depthAttachment.loadAction = .load
        pd.depthAttachment.storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pd) else { throw RendererError.commandQueue }
        enc.label = "Night lights"
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<NightSkyUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: used.count)
        enc.endEncoding()
    }
}
#endif
