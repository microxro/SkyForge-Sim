// SKYFORGE — Apache-2.0
// Volumetric cumulus on Metal: half-resolution ray march (CloudShaders) composited over the frame.
#if canImport(Metal)
import Foundation
import Metal
import simd
import SFAtmosphere

struct CloudLayerGPU { var shape: SIMD4<Float>; var drift: SIMD4<Float> }

/// Matches `CloudUniforms` in CloudShaders.source (all float4, no padding surprises).
struct CloudUniforms {
    var camPos: SIMD4<Float>
    var forward: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var toSun: SIMD4<Float>
    var sun: SIMD4<Float>
    var skyAmb: SIMD4<Float>
    var groundAmb: SIMD4<Float>
    var tableDims: SIMD4<Float>
    var viewport: SIMD4<Float>
    var layer: CloudLayerGPU

    init(layer c: CloudLayer, steps: Int) {
        camPos = SIMD4(0, 0, 0, Float(steps)); forward = .zero; right = .zero; up = .zero; toSun = .zero
        sun = .zero; skyAmb = SIMD4(0, 0, 0, 1); groundAmb = .zero; tableDims = SIMD4(1, 1, 1, 0); viewport = .zero
        layer = CloudLayerGPU(shape: SIMD4(c.base, c.thickness, c.coverage, c.extinction), drift: SIMD4(c.offset.x, c.offset.y, 0, 0))
    }
}

public final class CloudRenderer {
    public let device: MTLDevice
    private let marchPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let rayKernel: MTLComputePipelineState
    private var target: MTLTexture?
    /// March steps per ray (quality/performance knob; device tiers pick 40–96).
    public var steps = 64
    /// The march runs at 1/`downsample` of the frame in each dimension.
    public var downsample = 2
    /// Self-shadow taps toward the sun per sample (same ~1.7 km reach at any count; tiers pick 4–6).
    public var lightSteps = 6
    /// Strength of the fine cloud structure (0 = the reference density; 1 at the best tier).
    public var fineDetail: Float = 0

    public init(device: MTLDevice, colorFormat: MTLPixelFormat) throws {
        self.device = device
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: CloudShaders.source, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        guard let v = lib.makeFunction(name: "cloud_vertex"), let mf = lib.makeFunction(name: "cloud_march_fragment"),
              let cf = lib.makeFunction(name: "cloud_composite_fragment"), let k = lib.makeFunction(name: "cloud_march_rays") else {
            throw RendererError.shaderCompile("missing cloud functions")
        }
        let md = MTLRenderPipelineDescriptor()
        md.label = "CloudMarch"
        md.vertexFunction = v; md.fragmentFunction = mf
        md.colorAttachments[0].pixelFormat = .rgba16Float
        let cd = MTLRenderPipelineDescriptor()
        cd.label = "CloudComposite"
        cd.vertexFunction = v; cd.fragmentFunction = cf
        cd.colorAttachments[0].pixelFormat = colorFormat
        let ca = cd.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            marchPipeline = try device.makeRenderPipelineState(descriptor: md)
            compositePipeline = try device.makeRenderPipelineState(descriptor: cd)
            rayKernel = try device.makeComputePipelineState(function: k)
        } catch { throw RendererError.pipeline(String(describing: error)) }
    }

    private func marchTarget(width: Int, height: Int) throws -> MTLTexture {
        if let t = target, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
        target = t
        return t
    }

    /// Marches at reduced resolution against the frame's depth, then blends over `colour`.
    func encode(cmd: MTLCommandBuffer, colour: MTLTexture, depth: MTLTexture, uniforms: CloudUniforms,
                inscatter: MTLTexture, transmit: MTLTexture) throws {
        let w = max(1, colour.width / downsample), h = max(1, colour.height / downsample)
        let t = try marchTarget(width: w, height: h)
        var u = uniforms
        u.camPos.w = Float(steps)
        u.layer.drift.z = Float(lightSteps)
        u.layer.drift.w = fineDetail
        u.viewport = SIMD4(Float(w), Float(h), Float(colour.width), Float(colour.height))
        let mp = MTLRenderPassDescriptor()
        mp.colorAttachments[0].texture = t
        mp.colorAttachments[0].loadAction = .dontCare
        mp.colorAttachments[0].storeAction = .store
        guard let me = cmd.makeRenderCommandEncoder(descriptor: mp) else { throw RendererError.commandQueue }
        me.label = "Clouds (march)"
        me.setRenderPipelineState(marchPipeline)
        me.setFragmentBytes(&u, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        me.setFragmentTexture(depth, index: 0)
        me.setFragmentTexture(inscatter, index: 1)
        me.setFragmentTexture(transmit, index: 2)
        me.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        me.endEncoding()
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = colour
        cp.colorAttachments[0].loadAction = .load
        cp.colorAttachments[0].storeAction = .store
        guard let ce = cmd.makeRenderCommandEncoder(descriptor: cp) else { throw RendererError.commandQueue }
        ce.label = "Clouds (composite)"
        ce.setRenderPipelineState(compositePipeline)
        ce.setFragmentTexture(t, index: 0)
        var cp4 = SIMD4<Float>(Float(downsample), 0, 0, 0)
        ce.setFragmentBytes(&cp4, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        ce.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        ce.endEncoding()
    }

    /// One ray per entry through the GPU march (used by CI to compare against `VolumetricClouds.march`).
    public func marchRays(origins: [SIMD3<Float>], dirs: [SIMD3<Float>], maxDist: [Float], jitter: [Float], layer: CloudLayer,
                          toSun: SIMD3<Float>, sun: SIMD3<Float>, skyAmbient: SIMD3<Float>, groundAmbient: SIMD3<Float>,
                          steps: Int) throws -> [CloudSample] {
        let n = origins.count
        var rays = [SIMD4<Float>](repeating: .zero, count: 2 * n)
        for i in 0..<n {
            rays[2 * i] = SIMD4(origins[i], maxDist[i]); rays[2 * i + 1] = SIMD4(dirs[i], jitter[i])
        }
        var u = CloudUniforms(layer: layer, steps: steps)
        u.toSun = SIMD4(toSun, 0); u.sun = SIMD4(sun, 1); u.skyAmb = SIMD4(skyAmbient, 1); u.groundAmb = SIMD4(groundAmbient, 0)
        guard let queue = device.makeCommandQueue(),
              let rb = device.makeBuffer(bytes: rays, length: rays.count * 16, options: .storageModeShared),
              let ob = device.makeBuffer(length: 2 * n * 16, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw RendererError.commandQueue }
        enc.setComputePipelineState(rayKernel)
        enc.setBuffer(rb, offset: 0, index: 0)
        enc.setBuffer(ob, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<CloudUniforms>.stride, index: 2)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(n, rayKernel.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error { throw RendererError.pipeline(String(describing: e)) }
        let p = ob.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * n)
        return (0..<n).map { CloudSample(radiance: SIMD3(p[2 * $0].x, p[2 * $0].y, p[2 * $0].z), transmittance: p[2 * $0].w, depth: p[2 * $0 + 1].x) }
    }
}
#endif
