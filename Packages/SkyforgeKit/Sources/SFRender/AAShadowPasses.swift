// SKYFORGE — Apache-2.0
// Round 5 (aa_shadows): GPU side of the AA path. TAA jitter and history, the TAA resolve, and the tier cascade
// matrices packed for `CascadeShadowParams`. MSL: Shaders/AAShadowShaders.swift (in the world library). CPU maths:
// AAShadowMath.swift. Owned by WorldRenderer and only created once `aaTier` is set.
#if canImport(Metal)
import Foundation
import Metal
import simd

/// Packed `CascadeShadowParams` (AAShadowShaders.swift), bound at fragment buffer 12 of the world pass. Four
/// float4x4 then five float4, the same layout as the MSL struct (336 bytes). `fwd.w` = 0 keeps the legacy cascades.
struct CascadeShadowGPU {
    var vp0: simd_float4x4
    var vp1: simd_float4x4
    var vp2: simd_float4x4
    var vp3: simd_float4x4
    var splits: SIMD4<Float>
    var texel: SIMD4<Float>
    var depthRange: SIMD4<Float>
    var q: SIMD4<Float>
    var fwd: SIMD4<Float>

    static let inactive = CascadeShadowGPU(vp0: matrix_identity_float4x4, vp1: matrix_identity_float4x4,
                                           vp2: matrix_identity_float4x4, vp3: matrix_identity_float4x4,
                                           splits: .zero, texel: .zero, depthRange: .zero, q: .zero, fwd: .zero)
}

/// Packed `TAAParams` (AAShadowShaders.swift), fragment buffer 0 of the resolve pass.
struct TAAParamsGPU {
    var invViewProj: simd_float4x4
    var prevViewProj: simd_float4x4
    var params: SIMD4<Float>   // x base blend, y clip gamma, z 1 = history invalid, w unused
}

/// Round 5: per-renderer state for the AA path (TAA history, SMAA-lite pipeline, tier cascades).
final class AAShadowPasses {
    /// Camera-relative cascade matrices (padded to four) and the packed shader parameters for one frame.
    struct CascadeSet {
        var count: Int
        var matrices: [simd_float4x4]
        var gpu: CascadeShadowGPU
    }

    let taaPipeline: MTLRenderPipelineState
    /// Low tier's edge AA, drawn where FXAA would be (colour format of the final frame).
    let smaaPipeline: MTLRenderPipelineState
    private let device: MTLDevice
    /// Resolved frames, ping-pong: `historyIndex` holds the last output.
    private var historyTargets: [MTLTexture] = []
    private var historyIndex = 0
    private var historyState = TAAHistoryState()
    private var frame = 0
    private var lastTier: AAShadowTier?
    /// Set by `beginFrame` when the tier runs TAA; cleared by `resolve`.
    private var active = false
    private var resetFrame = true
    private var width = 0, height = 0
    private var eye = SIMD3<Double>.zero
    private var baseVP = matrix_identity_float4x4
    private var prevBaseVP: simd_float4x4?
    private var prevEye = SIMD3<Double>.zero

    init(device: MTLDevice, library: MTLLibrary, colorFormat: MTLPixelFormat) throws {
        self.device = device
        func pipeline(_ fragment: String, format: MTLPixelFormat, label: String) throws -> MTLRenderPipelineState {
            guard let v = library.makeFunction(name: "aa_vertex"), let f = library.makeFunction(name: fragment) else {
                throw RendererError.shaderCompile("missing \(fragment)")
            }
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = v
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = format
            do { return try device.makeRenderPipelineState(descriptor: d) }
            catch { throw RendererError.pipeline(String(describing: error)) }
        }
        taaPipeline = try pipeline("taa_resolve_fragment", format: .rgba16Float, label: "TAAResolve")
        smaaPipeline = try pipeline("smaa_lite_fragment", format: colorFormat, label: "SMAALite")
    }

    /// Call once per frame before the scene encode. Returns the clip-space shift to left-multiply the world
    /// view-projection by (identity unless the tier runs TAA). Also records the jitter-free matrices and whether
    /// the history must be ignored this frame.
    func beginFrame(camera c: WorldCamera, width w: Int, height h: Int, tier: AAShadowTier) -> simd_float4x4 {
        active = tier.usesTAA
        guard tier.usesTAA else { lastTier = tier; return matrix_identity_float4x4 }
        // Same construction as WorldRenderer.encodeScene's viewProj, without the jitter.
        let aspect = Float(Double(w) / Double(max(1, h)))
        let fwdD = simd_normalize(c.target - c.position)
        let fwd = SIMD3<Float>(Float(fwdD.x), Float(fwdD.y), Float(fwdD.z))
        let up = SIMD3<Float>(Float(c.up.x), Float(c.up.y), Float(c.up.z))
        baseVP = WorldRenderer.reversedZProjection(fovY: Float(c.verticalFOVDeg * .pi / 180), aspect: aspect,
                                                   near: Float(c.near)) * WorldRenderer.view(forward: fwd, up: up)
        let reason = historyState.beginFrame(width: w, height: h, eye: c.position, tierChanged: tier != lastTier)
        resetFrame = reason != nil
        lastTier = tier
        width = w; height = h; eye = c.position
        let j = TAAJitter.pixelJitter(frame: frame, length: tier.jitterLength)
        frame += 1
        let o = TAAJitter.ndcOffset(pixelJitter: j, width: w, height: h)
        // Adds o to clip x and y after the perspective divide's w: x' = x + o.x * w, y' = y + o.y * w.
        return simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                       SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(o.x, o.y, 0, 1)))
    }

    /// After the scene and its overlays: resolve TAA from `scene` and last frame's history, then copy the result over
    /// `scene`, so bloom, tone map and AA read it unchanged. No-op unless `beginFrame` ran with a TAA tier.
    func resolve(cmd: MTLCommandBuffer, scene: MTLTexture, depth: MTLTexture) throws {
        guard active else { return }
        active = false
        let w = scene.width, h = scene.height
        if historyTargets.count != 2 || historyTargets[0].width != w || historyTargets[0].height != h {
            historyTargets = [try makeTarget(w, h), try makeTarget(w, h)]
            historyIndex = 0
        }
        let src = historyTargets[historyIndex], dst = historyTargets[1 - historyIndex]
        // Previous jitter-free view-projection, moved onto this frame's camera-relative origin: r_prev = r_cur + (Ec - Ep).
        let prevVP = (prevBaseVP ?? baseVP) * WorldRenderer.translation(eye - prevEye)
        var params = TAAParamsGPU(invViewProj: simd_inverse(baseVP), prevViewProj: prevVP,
                                  params: SIMD4<Float>(0.1, 1.25, resetFrame ? 1 : 0, 0))
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = dst
        pd.colorAttachments[0].loadAction = .dontCare
        pd.colorAttachments[0].storeAction = .store
        guard let e = cmd.makeRenderCommandEncoder(descriptor: pd) else { throw RendererError.commandQueue }
        e.label = "TAAResolve"
        e.setRenderPipelineState(taaPipeline)
        e.setFragmentTexture(scene, index: 0)
        e.setFragmentTexture(src, index: 1)
        e.setFragmentTexture(depth, index: 2)
        e.setFragmentBytes(&params, length: MemoryLayout<TAAParamsGPU>.stride, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        guard let blit = cmd.makeBlitCommandEncoder() else { throw RendererError.commandQueue }
        blit.label = "TAACopyBack"
        blit.copy(from: dst, to: scene)
        blit.endEncoding()
        historyIndex = 1 - historyIndex
        prevBaseVP = baseVP
        prevEye = eye
    }

    private func makeTarget(_ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
        return t
    }

    /// Tier cascades: view-depth splits (`CascadeMath.splits`), one texel-snapped orthographic light matrix per
    /// cascade, camera-relative like `ShadowCascades.matrix`. Matrices are padded to four; the shader reads `count`.
    static func cascades(tier: AAShadowTier, camera c: WorldCamera, toSun: SIMD3<Float>, forward fwd: SIMD3<Float>,
                         mapSize: Int, aspect: Float) -> CascadeSet {
        let n = tier.cascadeCount
        let near = max(0.5, Float(c.near))
        let far: Float = 24_000
        let splits = CascadeMath.splits(count: n, near: near, far: far)
        let fovY = Float(c.verticalFOVDeg * .pi / 180)
        let axes = ShadowCascades.lightAxes(toSun)
        let xL = axes.x, yL = axes.y, zL = axes.z
        let camW = c.position
        var mats: [simd_float4x4] = []
        var splitV = SIMD4<Float>(repeating: far), texelV = SIMD4<Float>.zero, rangeV = SIMD4<Float>.zero
        var a = near
        for i in 0..<n {
            let b = splits[i]
            let r = CascadeMath.sliceRadius(near: a, far: b, verticalFOV: fovY, aspect: aspect)
            let range = max(40_000, 4 * r)           // light-space depth extent (m) about the slice centre
            let centre = fwd * sliceCentreDepth(near: a, far: b, verticalFOV: fovY, aspect: aspect)   // camera-relative
            let texel = 2 * r / Float(mapSize)
            // Snap the light-space centre to the world-anchored texel grid (absolute coordinates, Double).
            let worldC = camW + double3(centre)
            let cx = Float(CascadeMath.snap((worldC * double3(xL)).sum(), texel: Double(texel)) - (camW * double3(xL)).sum())
            let cy = Float(CascadeMath.snap((worldC * double3(yL)).sum(), texel: Double(texel)) - (camW * double3(yL)).sum())
            let cz = simd_dot(centre, zL)
            let view = simd_float4x4(rows: [SIMD4(xL, -cx), SIMD4(yL, -cy), SIMD4(zL, -cz), SIMD4<Float>(0, 0, 0, 1)])
            let proj = simd_float4x4(rows: [SIMD4<Float>(1 / r, 0, 0, 0), SIMD4<Float>(0, 1 / r, 0, 0),
                                            SIMD4<Float>(0, 0, -1 / range, 0.5), SIMD4<Float>(0, 0, 0, 1)])
            mats.append(proj * view)
            splitV[i] = b
            texelV[i] = texel
            rangeV[i] = range
            a = b
        }
        while mats.count < 4 { mats.append(matrix_identity_float4x4) }
        let q = SIMD4<Float>(tier.blendFraction, Float(tier.pcfTaps), tier.usesPCSS ? 1 : 0, Float(tan(0.0093 / 2)))
        let gpu = CascadeShadowGPU(vp0: mats[0], vp1: mats[1], vp2: mats[2], vp3: mats[3],
                                   splits: splitV, texel: texelV, depthRange: rangeV, q: q,
                                   fwd: SIMD4<Float>(fwd.x, fwd.y, fwd.z, Float(n)))
        return CascadeSet(count: n, matrices: mats, gpu: gpu)
    }

    /// Centre depth (m along the forward axis) of the bounding sphere `CascadeMath.sliceRadius` measures; mirrors it.
    static func sliceCentreDepth(near a: Float, far b: Float, verticalFOV: Float, aspect: Float) -> Float {
        let ty = tan(verticalFOV * 0.5), tx = ty * aspect
        let k = tx * tx + ty * ty
        return min(b, 0.5 * (a + b) * (1 + k))
    }

    private static func double3(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
    }
}
#endif
