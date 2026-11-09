// SKYFORGE — Apache-2.0
// Metal renderer for the Quick Flight world: static environment mesh + aircraft + physically
// based sky, with aerial perspective tables from SFPreview.PhysicalSky.
#if canImport(Metal)
import Foundation
import Metal
import simd
import SFPreview
import SFAtmosphere

struct WorldUniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    var sunDir: SIMD4<Float>
    var sunColour: SIMD4<Float>
    var ambientSky: SIMD4<Float>
    var ambientGround: SIMD4<Float>
    var skyHorizon: SIMD4<Float>
    var tableDims: SIMD4<Float>
    var shadow0: simd_float4x4
    var shadow1: simd_float4x4
    var cascadeSplits: SIMD4<Float>
    var cascadeDepth: SIMD4<Float>
    var cameraPos: SIMD4<Float>
    var cameraLocal: SIMD4<Float>
    var imageryNear: SIMD4<Float>
    var imageryFar: SIMD4<Float>
    var clouds: CloudLayerGPU
    var fieldGrid: SIMD4<Float>       // farmed-parcel texture: iu0, iv0, width, height (width 0 = none)
    var imageryDetail: SIMD4<Float>   // centre x, y, half extent, 1 if present
}

/// 16-byte vertex matching `TerrainVertex` (position + snorm normal; w = −127 marks bark).
struct PackedTerrainVertex {
    var px: Float, py: Float, pz: Float
    var nx: Int8, ny: Int8, nz: Int8, nw: Int8
}

/// 32-byte instance matching `TreeInstanceGPU`.
struct PackedTreeInstance {
    var px: Float, py: Float, pz: Float
    var height: Float
    var r: Float, g: Float, b: Float
    var kind: Float
}

/// Real-world content handed to the renderer (all positions in region metres).
struct ShadowUniforms {
    var lightViewProj: simd_float4x4
    var model: simd_float4x4
}

/// Two-cascade sun shadow setup in camera-relative coordinates.
struct ShadowCascades {
    static let size = 2048
    static let halfExtents: [Float] = [220, 2_200]
    static let depthRanges: [Float] = [3_000, 10_000]
    static let splits: [Float] = [380, 3_600]

    /// Orthographic light matrix centred `ahead` metres along the horizontal camera forward,
    /// snapped to whole texels so shadows do not shimmer as the camera moves.
    static func matrix(cascade c: Int, toSun s: SIMD3<Float>, forward f: SIMD3<Float>, cameraWorld: SIMD3<Double>) -> simd_float4x4 {
        let zL = simd_normalize(s)
        var xL = simd_cross(SIMD3<Float>(0, 0, 1), zL)
        if simd_length(xL) < 1e-3 { xL = SIMD3(1, 0, 0) }
        xL = simd_normalize(xL)
        let yL = simd_cross(zL, xL)
        let fh = simd_normalize(SIMD3(f.x, f.y, 0) + SIMD3(0, 0, 1e-6))
        let half = halfExtents[c], range = depthRanges[c]
        let centre = fh * half * 0.6
        // Snap in light space using absolute world position, so the grid is fixed to the world.
        let texel = 2 * half / Float(size)
        let worldC = SIMD3<Double>(Double(centre.x), Double(centre.y), Double(centre.z)) + cameraWorld
        func snap(_ axis: SIMD3<Float>) -> Float {
            let a = SIMD3<Double>(Double(axis.x), Double(axis.y), Double(axis.z))
            let d = (worldC * a).sum()
            let snapped = (d / Double(texel)).rounded() * Double(texel)
            return Float(snapped - (cameraWorld * a).sum())
        }
        let cx = snap(xL), cy = snap(yL), cz = simd_dot(centre, zL)
        let view = simd_float4x4(rows: [SIMD4(xL, -cx), SIMD4(yL, -cy), SIMD4(zL, -cz), SIMD4(0, 0, 0, 1)])
        let proj = simd_float4x4(rows: [SIMD4(1 / half, 0, 0, 0), SIMD4(0, 1 / half, 0, 0),
                                        SIMD4(0, 0, -1 / range, 0.5), SIMD4(0, 0, 0, 1)])
        return proj * view
    }
}

/// 20-byte vertex matching `WorldVertex` in WorldShaders.
struct PackedWorldVertex {
    var px: Float, py: Float, pz: Float
    var nx: Int8, ny: Int8, nz: Int8, nw: Int8
    var r: UInt8, g: UInt8, b: UInt8, material: UInt8
}

public struct WorldCamera: Sendable, Equatable {
    public var position: SIMD3<Double>   // world (x east, y north, z up)
    public var target: SIMD3<Double>
    public var verticalFOVDeg: Double = 55
    /// Up hint (world); tilt it to bank the view (cockpit). Must not be parallel to the view direction.
    public var up: SIMD3<Double> = SIMD3(0, 0, 1)
    /// Near plane (m); the cockpit view uses a few centimetres.
    public var near: Double = 0.5
    public init(position: SIMD3<Double>, target: SIMD3<Double>, verticalFOVDeg: Double = 55,
                up: SIMD3<Double> = SIMD3(0, 0, 1), near: Double = 0.5) {
        self.position = position; self.target = target; self.verticalFOVDeg = verticalFOVDeg; self.up = up; self.near = near
    }
}

public final class WorldRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let shadowPipeline: MTLRenderPipelineState
    private let shadowDepthState: MTLDepthStencilState
    private var shadowMap: MTLTexture?
    private let terrainPipeline: MTLRenderPipelineState
    private let treePipeline: MTLRenderPipelineState
    private let shadowTerrainPipeline: MTLRenderPipelineState
    private let shadowTreePipeline: MTLRenderPipelineState
    private let screenPipeline: MTLRenderPipelineState
    private var cockpit: (buffer: MTLBuffer, count: Int, screen: MTLBuffer)?
    private var cockpitScreen: MTLTexture?
    /// Draw from inside the cockpit: interior mesh, PFD screen, airframe back faces skipped.
    public var cockpitView = false
    /// FXAA on the final frame (the scene renders into an internal texture first).
    public var antialiasing = true
    private let fxaaPipeline: MTLRenderPipelineState
    private var sceneTarget: MTLTexture?
    private var real: (vertices: MTLBuffer, indices: MTLBuffer, draws: [(indexOffset: Int, indexCount: Int, baseVertex: Int, min: SIMD3<Float>, max: SIMD3<Float>)])?
    /// Instanced trees (real world and SkyWorld): shared conifer/broadleaf meshes and per-tree instances.
    private var trees: (mesh: MTLBuffer, ranges: [(start: Int, count: Int)], instances: MTLBuffer)?
    /// Tree cells nearer than this draw the full mesh; farther cells (and the outer shadow cascades) the
    /// crown-only LOD. 105k SkyWorld desktop trees at full detail cost ~11 ms on the CI GPU.
    static let treeLODDistance: Float = 650

    /// Vertex range of the tree mesh for a cell: kind 0 conifer / 1 broadleaf, full or LOD.
    private func treeRange(kind: Int, full: Bool) -> (start: Int, count: Int) {
        trees!.ranges[(full ? 0 : 2) + kind]
    }

    /// Squared distance from `p` to a cell's box (0 inside).
    @inline(__always) static func boxDistance2(_ p: SIMD3<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Float {
        let d = simd_max(simd_max(lo - p, p - hi), SIMD3<Float>(repeating: 0))
        return simd_dot(d, d)
    }
    /// Tree instances binned into 400 m cells per kind (contiguous ranges), culled per view and cascade.
    private var treeCells: [(kind: Int, start: Int, count: Int, min: SIMD3<Float>, max: SIMD3<Float>)] = []
    /// Tree cells drawn in the last main pass (of `treeCellCount`).
    public private(set) var lastDrawnTreeCells = 0
    /// Of those, cells drawn with the distant LOD mesh.
    public private(set) var lastLODTreeCells = 0
    public var treeCellCount: Int { treeCells.count }
    private var imageryNear: (tex: MTLTexture, centre: SIMD2<Double>, half: Double)?
    private var imageryFar: (tex: MTLTexture, centre: SIMD2<Double>, half: Double)?
    private var imageryDetail: (tex: MTLTexture, centre: SIMD2<Double>, half: Double)?
    private var waterTex: MTLTexture?
    private lazy var dummy2D: MTLTexture = makeDummy()
    /// Chunks drawn in the last frame after frustum culling (diagnostics/tests).
    public private(set) var lastDrawnChunks = 0
    /// Sun shadows (two cascades). Low-tier devices may turn this off.
    public var shadowsEnabled = true
    /// Volumetric cumulus layer (coverage 0 disables the cloud passes).
    public var clouds: CloudLayer = .clear
    /// Cloud march steps per ray (device tier knob).
    public var cloudSteps = 64
    /// Display grade strength (gentle filmic contrast and vibrance after the tone map; 0 = off).
    public var colourGrade: Float = 1
    /// Cloud self-shadow taps toward the sun per march sample (tier setting).
    public var cloudLightSteps = 6
    /// Cloud march resolution divisor (2 = half resolution).
    public var cloudDownsample = 2
    /// Dynamic resolution: the scene renders at this fraction of the output size and is upscaled
    /// in the tone-map pass (FXAA runs at the output size).
    public var renderScale: Float = 1
    private var scaledDepth: MTLTexture?

    /// Per-device-tier render settings (the app and the CI frame-time test use the same presets).
    public struct Settings: Sendable, Equatable {
        public var renderScale: Float, cloudSteps: Int, cloudDownsample: Int, bloomIntensity: Float, ssaoStrength: Float
        /// Cloud self-shadow taps per march sample.
        public var cloudLightSteps: Int
        public init(renderScale: Float, cloudSteps: Int, cloudDownsample: Int, bloomIntensity: Float, ssaoStrength: Float,
                    cloudLightSteps: Int = 6) {
            self.cloudLightSteps = cloudLightSteps
            self.renderScale = renderScale; self.cloudSteps = cloudSteps; self.cloudDownsample = cloudDownsample
            self.bloomIntensity = bloomIntensity; self.ssaoStrength = ssaoStrength
        }
        public static let low = Settings(renderScale: 1, cloudSteps: 40, cloudDownsample: 2, bloomIntensity: 0.04, ssaoStrength: 0.5,
                                         cloudLightSteps: 4)
        public static let medium = Settings(renderScale: 1, cloudSteps: 48, cloudDownsample: 2, bloomIntensity: 0.05, ssaoStrength: 0.7)
        public static let high = Settings(renderScale: 0.75, cloudSteps: 40, cloudDownsample: 4, bloomIntensity: 0.05, ssaoStrength: 0.7)
    }

    public func apply(_ s: Settings) {
        renderScale = s.renderScale; cloudSteps = s.cloudSteps; cloudDownsample = s.cloudDownsample; cloudLightSteps = s.cloudLightSteps
        bloomIntensity = s.bloomIntensity; ssaoStrength = s.ssaoStrength
    }
    private var cloudRenderer: CloudRenderer?
    private let sky: PhysicalSkyRenderer
    private var environment: (buffer: MTLBuffer, count: Int, origin: SIMD3<Double>, cells: [MeshCell])?
    /// Field parcels drawn per pixel on the environment's terrain (from the soup; nil = none).
    public private(set) var fieldPattern: FieldPattern?
    private var parcelTex: (tex: MTLTexture, grid: FieldPattern.ParcelGrid)?
    private let worldLibrary: MTLLibrary
    /// Environment cells drawn in the last main pass (of `environmentCellCount`), for tests and HUD stats.
    public private(set) var lastDrawnEnvironmentCells = 0
    public var environmentCellCount: Int { environment?.cells.count ?? 0 }
    private var aircraft: (buffer: MTLBuffer, count: Int)?
    /// Translucent propeller disc (material 9), drawn blended after the opaque airframe.
    private var propDisc: (buffer: MTLBuffer, count: Int)?
    private let propPipeline: MTLRenderPipelineState
    private let propDepthState: MTLDepthStencilState
    private var tables: (ins: MTLTexture, tr: MTLTexture, key: SIMD4<Float>)?
    public private(set) var lighting: LightingSetup
    public let colorFormat: MTLPixelFormat
    /// The scene renders into linear HDR (radiance × exposure); post-processing tone-maps it.
    public let sceneFormat: MTLPixelFormat = .rgba16Float
    /// Energy-conserving bloom: the frame is lerped this far toward its blurred self (0 = off).
    public var bloomIntensity: Float = 0.05
    private let bloomDownPipeline: MTLRenderPipelineState
    private let bloomUpPipeline: MTLRenderPipelineState
    private let tonemapPipeline: MTLRenderPipelineState
    private var bloomLevels: [MTLTexture] = []
    private let ssaoPipeline: MTLRenderPipelineState
    private var aoTarget: MTLTexture?
    /// Screen-space ambient occlusion strength (0 = off).
    public var ssaoStrength: Float = 0.7
    private var ldrTarget: MTLTexture?

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), colorFormat: MTLPixelFormat = .rgba8Unorm,
                lighting: LightingSetup) throws {
        guard let device else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandQueue }
        self.device = device
        self.queue = queue
        self.colorFormat = colorFormat
        self.lighting = lighting
        sky = try PhysicalSkyRenderer(device: device, colorFormat: .rgba16Float)
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: CloudShaders.common + WorldShaders.source, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        worldLibrary = lib
        guard let v = lib.makeFunction(name: "world_vertex"), let f = lib.makeFunction(name: "world_fragment") else {
            throw RendererError.shaderCompile("missing world functions")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "World"
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = .rgba16Float
        d.depthAttachmentPixelFormat = .depth32Float
        do { pipeline = try device.makeRenderPipelineState(descriptor: d) }
        catch { throw RendererError.pipeline(String(describing: error)) }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .greater      // reversed-Z
        ds.isDepthWriteEnabled = true
        guard let dss = device.makeDepthStencilState(descriptor: ds) else { throw RendererError.commandQueue }
        depthState = dss
        guard let sv = lib.makeFunction(name: "shadow_vertex") else { throw RendererError.shaderCompile("missing shadow_vertex") }
        let sd = MTLRenderPipelineDescriptor()
        sd.label = "SunShadow"
        sd.vertexFunction = sv
        sd.fragmentFunction = nil
        sd.depthAttachmentPixelFormat = .depth32Float
        do { shadowPipeline = try device.makeRenderPipelineState(descriptor: sd) }
        catch { throw RendererError.pipeline(String(describing: error)) }
        let sds = MTLDepthStencilDescriptor()
        sds.depthCompareFunction = .lessEqual
        sds.isDepthWriteEnabled = true
        guard let sdss = device.makeDepthStencilState(descriptor: sds) else { throw RendererError.commandQueue }
        shadowDepthState = sdss
        func pso(_ v: String, _ f: String?, label: String, colour: Bool) throws -> MTLRenderPipelineState {
            guard let vf = lib.makeFunction(name: v) else { throw RendererError.shaderCompile("missing \(v)") }
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = vf
            if let f { d.fragmentFunction = lib.makeFunction(name: f) }
            if colour { d.colorAttachments[0].pixelFormat = .rgba16Float }
            d.depthAttachmentPixelFormat = .depth32Float
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RendererError.pipeline(String(describing: error)) }
        }
        terrainPipeline = try pso("terrain_vertex", "world_fragment", label: "RealTerrain", colour: true)
        treePipeline = try pso("tree_vertex", "world_fragment", label: "Trees", colour: true)
        shadowTerrainPipeline = try pso("shadow_terrain_vertex", nil, label: "ShadowTerrain", colour: false)
        shadowTreePipeline = try pso("shadow_tree_vertex", nil, label: "ShadowTrees", colour: false)
        screenPipeline = try pso("screen_vertex", "screen_fragment", label: "CockpitScreen", colour: true)
        do {
            guard let pv = lib.makeFunction(name: "world_vertex"), let pf = lib.makeFunction(name: "prop_fragment") else {
                throw RendererError.shaderCompile("missing prop functions")
            }
            let pd = MTLRenderPipelineDescriptor()
            pd.label = "PropDisc"
            pd.vertexFunction = pv; pd.fragmentFunction = pf
            pd.colorAttachments[0].pixelFormat = .rgba16Float
            pd.depthAttachmentPixelFormat = .depth32Float
            let ca = pd.colorAttachments[0]!
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            propPipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch let e as RendererError { throw e } catch { throw RendererError.pipeline(String(describing: error)) }
        let pds = MTLDepthStencilDescriptor()
        pds.depthCompareFunction = .greater      // reversed-Z test, no depth write (translucent)
        pds.isDepthWriteEnabled = false
        guard let pdss = device.makeDepthStencilState(descriptor: pds) else { throw RendererError.commandQueue }
        propDepthState = pdss
        do {
            let plib = try device.makeLibrary(source: PostShaders.source, options: nil)
            let fd = MTLRenderPipelineDescriptor()
            fd.label = "FXAA"
            fd.vertexFunction = plib.makeFunction(name: "post_vertex")
            fd.fragmentFunction = plib.makeFunction(name: "fxaa_fragment")
            fd.colorAttachments[0].pixelFormat = colorFormat
            fxaaPipeline = try device.makeRenderPipelineState(descriptor: fd)
            func post(_ f: String, _ label: String, _ format: MTLPixelFormat, additive: Bool = false) throws -> MTLRenderPipelineState {
                let pd = MTLRenderPipelineDescriptor()
                pd.label = label
                pd.vertexFunction = plib.makeFunction(name: "post_vertex")
                pd.fragmentFunction = plib.makeFunction(name: f)
                pd.colorAttachments[0].pixelFormat = format
                if additive, let ca = pd.colorAttachments[0] {
                    ca.isBlendingEnabled = true
                    ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
                    ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .zero
                }
                return try device.makeRenderPipelineState(descriptor: pd)
            }
            bloomDownPipeline = try post("bloom_down_fragment", "BloomDown", .rgba16Float)
            bloomUpPipeline = try post("bloom_up_fragment", "BloomUp", .rgba16Float, additive: true)
            tonemapPipeline = try post("tonemap_fragment", "Tonemap", colorFormat)
            ssaoPipeline = try post("ssao_fragment", "SSAO", .r16Float)
        } catch { throw RendererError.pipeline(String(describing: error)) }
    }

    /// `FieldPattern.factor` evaluated by the world shader's code (CI compares it with the CPU).
    public func fieldFactors(points: [SIMD3<Float>], pattern: FieldPattern, town: Bool = false) throws -> [SIMD3<Float>] {
        try runFieldKernel(points.map { SIMD4<Float>($0, 0) }, pattern: pattern, town: town).map { SIMD3($0.x, $0.y, $0.z) }
    }

    /// `FieldPattern.coverage` on the GPU for (x, y, weight) triples.
    public func fieldCoverage(points: [SIMD3<Float>], pattern: FieldPattern) throws -> [Float] {
        try runFieldKernel(points.map { SIMD4<Float>($0.x, $0.y, 1, $0.z) }, pattern: pattern, town: false).map(\.w)
    }

    private func runFieldKernel(_ pts: [SIMD4<Float>], pattern: FieldPattern, town: Bool) throws -> [SIMD4<Float>] {
        let n = pts.count
        guard n > 0 else { return [] }
        guard let k = worldLibrary.makeFunction(name: "field_factors") else { throw RendererError.shaderCompile("missing field_factors") }
        let kernel: MTLComputePipelineState
        do { kernel = try device.makeComputePipelineState(function: k) } catch { throw RendererError.pipeline(String(describing: error)) }
        var params = SIMD4<Float>(Float(pattern.seed), pattern.autumn ? 1 : 0, town ? 1 : 0, 0)
        guard let ib = device.makeBuffer(bytes: pts, length: n * 16, options: .storageModeShared),
              let ob = device.makeBuffer(length: n * 16, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw RendererError.commandQueue }
        enc.setComputePipelineState(kernel)
        enc.setBuffer(ib, offset: 0, index: 0)
        enc.setBuffer(ob, offset: 0, index: 1)
        enc.setBytes(&params, length: 16, index: 2)
        enc.setTexture(dummy2D, index: 0)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(n, kernel.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error { throw RendererError.pipeline(String(describing: e)) }
        let p = ob.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        return (0..<n).map { p[$0] }
    }

    private func makeDummy() -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        let t = device.makeTexture(descriptor: d)!
        var px: [UInt8] = [0, 0, 0, 255]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }

    /// Unit-height tree meshes (z 0…1): conifer (bare trunk, crown on top) and broad oak.
    static func treeMeshes() -> (conifer: [PackedTerrainVertex], oak: [PackedTerrainVertex], coniferLow: [PackedTerrainVertex], oakLow: [PackedTerrainVertex]) {
        func q(_ x: Double) -> Int8 { Int8(max(-127, min(127, (x * 127).rounded()))) }
        func tri(_ out: inout [PackedTerrainVertex], _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, bark: Bool) {
            let n = normalize(cross(b - a, c - a))
            for p in [a, b, c] { out.append(PackedTerrainVertex(px: Float(p.x), py: Float(p.y), pz: Float(p.z), nx: q(n.x), ny: q(n.y), nz: q(n.z), nw: bark ? -127 : 127)) }
        }
        func frustum(_ out: inout [PackedTerrainVertex], z0: Double, r0: Double, z1: Double, r1: Double, sides: Int, bark: Bool) {
            for k in 0..<sides {
                let a0 = Double(k) / Double(sides) * 2 * .pi, a1 = Double(k + 1) / Double(sides) * 2 * .pi
                let b0 = SIMD3(r0 * cos(a0), r0 * sin(a0), z0), b1 = SIMD3(r0 * cos(a1), r0 * sin(a1), z0)
                let t0 = SIMD3(r1 * cos(a0), r1 * sin(a0), z1), t1 = SIMD3(r1 * cos(a1), r1 * sin(a1), z1)
                tri(&out, b0, b1, t1, bark: bark)
                if r1 > 0 { tri(&out, b0, t1, t0, bark: bark) }
            }
        }
        var conifer: [PackedTerrainVertex] = [], oak: [PackedTerrainVertex] = []
        frustum(&conifer, z0: -0.03, r0: 0.018, z1: 0.6, r1: 0.012, sides: 5, bark: true)
        frustum(&conifer, z0: 0.52, r0: 0.12, z1: 0.62, r1: 0.22, sides: 7, bark: false)
        frustum(&conifer, z0: 0.62, r0: 0.22, z1: 0.82, r1: 0.17, sides: 7, bark: false)
        frustum(&conifer, z0: 0.82, r0: 0.17, z1: 1.0, r1: 0, sides: 7, bark: false)
        frustum(&oak, z0: -0.03, r0: 0.03, z1: 0.4, r1: 0.025, sides: 5, bark: true)
        frustum(&oak, z0: 0.3, r0: 0.18, z1: 0.48, r1: 0.42, sides: 8, bark: false)
        frustum(&oak, z0: 0.48, r0: 0.42, z1: 0.75, r1: 0.36, sides: 8, bark: false)
        frustum(&oak, z0: 0.75, r0: 0.36, z1: 1.0, r1: 0, sides: 8, bark: false)
        // Distant LOD (beyond `treeLODDistance`, a few pixels tall): crown only, 4 sides, 4–12 triangles
        // against ~45–50, same silhouette height and width.
        var coniferLow: [PackedTerrainVertex] = [], oakLow: [PackedTerrainVertex] = []
        frustum(&coniferLow, z0: 0.4, r0: 0.22, z1: 1.0, r1: 0, sides: 4, bark: false)
        frustum(&oakLow, z0: 0.3, r0: 0.4, z1: 0.62, r1: 0.4, sides: 4, bark: false)
        frustum(&oakLow, z0: 0.62, r0: 0.4, z1: 1.0, r1: 0, sides: 4, bark: false)
        return (conifer, oak, coniferLow, oakLow)
    }

    /// A ready GPU imagery texture with its placement, built on any thread (`makeImagery`) and swapped in
    /// on the render thread (`setDetailImagery`), so streaming never stalls a frame.
    public struct PreparedImagery: @unchecked Sendable {
        public let texture: MTLTexture
        public let centre: SIMD2<Double>
        public let half: Double
    }

    /// Mipmapped sRGB texture for an imagery mosaic (blocks the calling thread for the mip blit; call it
    /// off the main thread when streaming).
    public static func imageryTexture(_ i: RealWorldRenderData.Imagery, device: MTLDevice, queue: MTLCommandQueue) throws -> PreparedImagery {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: i.size, height: i.size, mipmapped: true)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
        var rgba = [UInt8](repeating: 255, count: i.size * i.size * 4)
        for p in 0..<(i.size * i.size) { rgba[4 * p] = i.rgb[3 * p]; rgba[4 * p + 1] = i.rgb[3 * p + 1]; rgba[4 * p + 2] = i.rgb[3 * p + 2] }
        t.replace(region: MTLRegionMake2D(0, 0, i.size, i.size), mipmapLevel: 0, withBytes: rgba, bytesPerRow: i.size * 4)
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t); blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        }
        return PreparedImagery(texture: t, centre: i.centre, half: i.halfExtent)
    }

    /// Builds the streamed detail texture (call off the main thread).
    public func makeImagery(_ i: RealWorldRenderData.Imagery) throws -> PreparedImagery {
        try Self.imageryTexture(i, device: device, queue: queue)
    }

    /// Swaps the camera-following sharp imagery layer (nil removes it). The previous texture is released,
    /// so streaming holds one detail texture at a time.
    public func setDetailImagery(_ p: PreparedImagery?) {
        imageryDetail = p.map { ($0.texture, $0.centre, $0.half) }
    }

    /// Centre and half extent of the current detail layer (nil = none).
    public var detailImageryPlacement: (centre: SIMD2<Double>, half: Double)? { imageryDetail.map { ($0.centre, $0.half) } }

    /// Uploads instanced trees, binned by kind and 400 m cell so each cell is one contiguous instance range
    /// (culled per view and per shadow cascade). An empty list removes them.
    public func setTrees(_ list: [RealWorldRenderData.Tree]) throws {
        guard !list.isEmpty else { trees = nil; treeCells = []; return }
        let meshes = Self.treeMeshes()
        let treeVerts = meshes.conifer + meshes.oak + meshes.coniferLow + meshes.oakLow
        let c0 = meshes.conifer.count, o0 = meshes.oak.count, c1 = meshes.coniferLow.count, o1 = meshes.oakLow.count
        let ranges = [(0, c0), (c0, o0), (c0 + o0, c1), (c0 + o0 + c1, o1)]
        func cellKey(_ t: RealWorldRenderData.Tree) -> (Int, Int, Int) {
            (t.conifer ? 0 : 1, Int((t.position.x / 400).rounded(.down)), Int((t.position.y / 400).rounded(.down)))
        }
        let sorted = list.sorted { cellKey($0) < cellKey($1) }
        var cells: [(kind: Int, start: Int, count: Int, min: SIMD3<Float>, max: SIMD3<Float>)] = []
        for (i, t) in sorted.enumerated() {
            let k = cellKey(t)
            let lo = t.position - SIMD3(8, 8, 1), hi = t.position + SIMD3(8, 8, t.height + 1)
            if let last = cells.last, cellKey(sorted[last.start]) == k {
                cells[cells.count - 1].count += 1
                cells[cells.count - 1].min = SIMD3(min(last.min.x, lo.x), min(last.min.y, lo.y), min(last.min.z, lo.z))
                cells[cells.count - 1].max = SIMD3(max(last.max.x, hi.x), max(last.max.y, hi.y), max(last.max.z, hi.z))
            } else {
                cells.append((k.0, i, 1, lo, hi))
            }
        }
        let inst = sorted.map { PackedTreeInstance(px: $0.position.x, py: $0.position.y, pz: $0.position.z, height: $0.height,
                                                   r: $0.colour.x, g: $0.colour.y, b: $0.colour.z, kind: $0.conifer ? 0 : 1) }
        precondition(MemoryLayout<PackedTreeInstance>.stride == 32)
        guard let mb = treeVerts.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let ib = inst.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw RendererError.commandQueue
        }
        treeCells = cells
        trees = (mb, ranges.map { (start: $0.0, count: $0.1) }, ib)
    }

    /// Uploads real-world terrain chunks, tree instances and imagery.
    public func setRealWorld(_ data: RealWorldRenderData) throws {
        // OSM buildings and roads use the world mesh pass (culled spatial cells, shadows).
        if let b = data.buildings, b.triangleCount > 0 { try setEnvironment(b) } else { environment = nil; fieldPattern = nil }
        func q(_ x: Float) -> Int8 { Int8(max(-127, min(127, (x * 127).rounded()))) }
        var verts: [PackedTerrainVertex] = [], idx: [UInt32] = []
        var draws: [(Int, Int, Int, SIMD3<Float>, SIMD3<Float>)] = []
        for c in data.chunks {
            let base = verts.count
            for (p, n) in zip(c.positions, c.normals) { verts.append(PackedTerrainVertex(px: p.x, py: p.y, pz: p.z, nx: q(n.x), ny: q(n.y), nz: q(n.z), nw: 127)) }
            draws.append((idx.count, c.indices.count, 0, c.boundsMin, c.boundsMax))
            // Absolute indices: the CI virtual GPU ignored `baseVertex`, so every chunk after the first
            // assembled triangles from the wrong vertices (missing foreground, slabs across the sky).
            idx += c.indices.map { $0 + UInt32(base) }
        }
        func buf<T>(_ a: [T]) throws -> MTLBuffer {
            guard !a.isEmpty, let b = a.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw RendererError.commandQueue
            }
            return b
        }
        precondition(MemoryLayout<PackedTerrainVertex>.stride == 16)
        real = (try buf(verts), try buf(idx), draws.map { (indexOffset: $0.0, indexCount: $0.1, baseVertex: $0.2, min: $0.3, max: $0.4) })
        try setTrees(data.trees)
        func imageryTexture(_ i: RealWorldRenderData.Imagery) throws -> MTLTexture {
            try Self.imageryTexture(i, device: device, queue: queue).texture
        }
        imageryNear = try data.near.map { (try imageryTexture($0), $0.centre, $0.halfExtent) }
        imageryFar = try data.far.map { (try imageryTexture($0), $0.centre, $0.halfExtent) }
        imageryDetail = try data.detail.map { (try imageryTexture($0), $0.centre, $0.halfExtent) }
        if let wm = data.waterMask {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: wm.size, height: wm.size, mipmapped: false)
            d.usage = [.shaderRead]
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
            t.replace(region: MTLRegionMake2D(0, 0, wm.size, wm.size), mipmapLevel: 0, withBytes: wm.values, bytesPerRow: wm.size * 4)
            waterTex = t
        } else { waterTex = nil }
    }

    /// Frustum planes (camera-relative) from a view-projection matrix (reversed-Z: near plane is w − z ≥ 0 … any order works).
    static func planes(_ m: simd_float4x4) -> [SIMD4<Float>] {
        let r0 = SIMD4(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = SIMD4(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = SIMD4(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = SIMD4(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2]   // left, right, bottom, top, near (z ≥ 0); infinite far
    }

    /// Six clip planes of an orthographic (or any) matrix with z in [0, 1].
    static func clipPlanes(_ m: simd_float4x4) -> [SIMD4<Float>] {
        let r0 = SIMD4(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = SIMD4(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = SIMD4(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = SIMD4(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
    }

    static func boxVisible(_ planes: [SIMD4<Float>], _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
        for p in planes {
            let v = SIMD3(p.x >= 0 ? hi.x : lo.x, p.y >= 0 ? hi.y : lo.y, p.z >= 0 ? hi.z : lo.z)
            if p.x * v.x + p.y * v.y + p.z * v.z + p.w < 0 { return false }
        }
        return true
    }

    private func shadowTexture() throws -> MTLTexture {
        if let t = shadowMap { return t }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .depth32Float
        d.width = ShadowCascades.size; d.height = ShadowCascades.size; d.arrayLength = 2
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
        shadowMap = t
        return t
    }

    static func pack(_ soup: TriangleSoup, order: [Int]? = nil) -> [PackedWorldVertex] {
        var out = [PackedWorldVertex]()
        out.reserveCapacity(soup.triangleCount * 3)
        func q(_ x: Float) -> Int8 { Int8(max(-127, min(127, (x * 127).rounded()))) }
        func c(_ x: Float) -> UInt8 { UInt8(max(0, min(255, (max(0, x).squareRoot() * 255).rounded()))) }
        for i in 0..<(order?.count ?? soup.triangleCount) {
            let t = order?[i] ?? i
            let m = soup.material[t].rawValue
            for k in 0..<3 {
                let a = soup.colour(t, k)
                let p = soup.positions[3 * t + k], n = soup.normals[3 * t + k]
                out.append(PackedWorldVertex(px: p.x, py: p.y, pz: p.z, nx: q(n.x), ny: q(n.y), nz: q(n.z), nw: q(soup.field(t, k)),
                                             r: c(a.x), g: c(a.y), b: c(a.z), material: m))
            }
        }
        return out
    }

    private func makeBuffer(_ v: [PackedWorldVertex]) throws -> MTLBuffer {
        guard !v.isEmpty, let b = v.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw RendererError.commandQueue
        }
        return b
    }

    public func setEnvironment(_ soup: TriangleSoup) throws {
        precondition(MemoryLayout<PackedWorldVertex>.stride == 20)
        let (order, cells) = SpatialBinning.bin(positions: soup.positions)
        environment = (try makeBuffer(Self.pack(soup, order: order)), soup.triangleCount * 3, soup.origin, cells)
        fieldPattern = soup.vertexField.isEmpty ? nil : soup.fieldPattern
        parcelTex = nil
        if let g = fieldPattern?.parcels, g.width > 0, g.height > 0 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: g.width, height: g.height, mipmapped: false)
            d.usage = [.shaderRead]
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
            g.on.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, g.width, g.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: g.width) }
            parcelTex = (t, g)
        }
    }

    public func setAircraft(_ soup: TriangleSoup) throws {
        let opaque = (0..<soup.triangleCount).filter { soup.material[$0] != .prop }
        let prop = (0..<soup.triangleCount).filter { soup.material[$0] == .prop }
        aircraft = (try makeBuffer(Self.pack(soup, order: opaque)), opaque.count * 3)
        propDisc = prop.isEmpty ? nil : (try makeBuffer(Self.pack(soup, order: prop)), prop.count * 3)
    }

    /// Cockpit interior (body axes, like the aircraft) and the display quad corners
    /// (top-left, top-right, bottom-right, bottom-left as the pilot sees them).
    public func setCockpit(_ soup: TriangleSoup, screen c: [SIMD3<Float>]) throws {
        precondition(c.count == 4)
        let uv: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        var v: [Float] = []
        for i in [0, 1, 2, 0, 2, 3] { v += [c[i].x, c[i].y, c[i].z, uv[i].x, uv[i].y] }
        guard let sb = device.makeBuffer(bytes: v, length: v.count * 4, options: .storageModeShared) else { throw RendererError.commandQueue }
        cockpit = (try makeBuffer(Self.pack(soup)), soup.triangleCount * 3, sb)
    }

    /// Uploads the cockpit display image (RGB8, gamma encoded, row 0 at the top).
    public func updateCockpitScreen(rgb: [UInt8], width: Int, height: Int) {
        if cockpitScreen?.width != width || cockpitScreen?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
            d.usage = [.shaderRead]
            cockpitScreen = device.makeTexture(descriptor: d)
        }
        guard let t = cockpitScreen else { return }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for p in 0..<(width * height) { rgba[4 * p] = rgb[3 * p]; rgba[4 * p + 1] = rgb[3 * p + 1]; rgba[4 * p + 2] = rgb[3 * p + 2] }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: rgba, bytesPerRow: width * 4)
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t); blit.endEncoding(); cmd.commit()
        }
    }

    public func setLighting(_ l: LightingSetup) { lighting = l; tables = nil }

    private func aerialTables() throws -> (MTLTexture, MTLTexture) {
        if let t = tables { return (t.ins, t.tr) }
        guard let ph = lighting.physical else {
            // No physical sky: identity tables (no in-scatter, full transmittance).
            let ins = try texture3D(1, 1, 1, [SIMD4<Float>(0, 0, 0, 0)])
            let tr = try texture3D(1, 1, 1, [SIMD4<Float>(1, 1, 1, 1)])
            tables = (ins, tr, SIMD4(1, 1, 1, 1000))
            return (ins, tr)
        }
        let ins = try texture3D(ph.nD, ph.nAz, ph.nEl, ph.inscatter.map { SIMD4($0, 1) })
        let tr = try texture3D(ph.nD, ph.nAz, ph.nEl, ph.transmit.map { SIMD4($0, 1) })
        tables = (ins, tr, SIMD4(Float(ph.nD), Float(ph.nAz), Float(ph.nEl), Float(ph.maxDistanceKm)))
        return (ins, tr)
    }

    private func texture3D(_ w: Int, _ h: Int, _ d: Int, _ data: [SIMD4<Float>]) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float
        desc.width = w; desc.height = h; desc.depth = d
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else { throw RendererError.commandQueue }
        data.withUnsafeBytes { buf in
            t.replace(region: MTLRegionMake3D(0, 0, 0, w, h, d), mipmapLevel: 0, slice: 0, withBytes: buf.baseAddress!,
                      bytesPerRow: w * 16, bytesPerImage: w * h * 16)
        }
        return t
    }

    static func reversedZProjection(fovY: Float, aspect: Float, near: Float) -> simd_float4x4 {
        let f = 1 / tan(fovY / 2)
        return simd_float4x4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
    }

    /// View matrix for a camera at the origin (camera-relative rendering), z up world.
    static func view(forward f: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 0, 1)) -> simd_float4x4 {
        let r = simd_normalize(simd_cross(f, up))
        let u = simd_cross(r, f)
        return simd_float4x4(rows: [SIMD4(r, 0), SIMD4(u, 0), SIMD4(-f, 0), SIMD4(0, 0, 0, 1)])
    }

    /// Encodes sky + world + aircraft into a pass whose colour attachment is already set.
    public func encode(cmd: MTLCommandBuffer, colour: MTLTexture, depth: MTLTexture, camera c: WorldCamera,
                       aircraftPosition: SIMD3<Double>?, aircraftBodyToENU: simd_double3x3?) throws {
        func target(_ t: MTLTexture?, _ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            if let t, t.width == w, t.height == h, t.pixelFormat == format { return t }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let scale = max(0.25, min(1, renderScale))
        let sw = max(8, Int((Float(colour.width) * scale).rounded())), sh = max(8, Int((Float(colour.height) * scale).rounded()))
        sceneTarget = target(sceneTarget, .rgba16Float, sw, sh)
        guard let scene = sceneTarget else { throw RendererError.commandQueue }
        var sceneDepth = depth
        if sw != depth.width || sh != depth.height {
            if scaledDepth?.width != sw || scaledDepth?.height != sh { scaledDepth = try makeDepth(width: sw, height: sh) }
            sceneDepth = scaledDepth!
        }
        try encodeScene(cmd: cmd, colour: scene, depth: sceneDepth, camera: c, aircraftPosition: aircraftPosition, aircraftBodyToENU: aircraftBodyToENU)
        func pass(_ t: MTLTexture, load: MTLLoadAction, label: String, _ body: (MTLRenderCommandEncoder) -> Void) throws {
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = t
            pd.colorAttachments[0].loadAction = load
            pd.colorAttachments[0].storeAction = .store
            guard let e = cmd.makeRenderCommandEncoder(descriptor: pd) else { throw RendererError.commandQueue }
            e.label = label
            body(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        // Bloom chain: up to 6 half-resolution levels down, then tent-upsampled and summed back up.
        var levelCount = 0
        if bloomIntensity > 0 {
            var w = sw / 2, h = sh / 2, levels: [MTLTexture] = []
            while levels.count < 6 && w >= 8 && h >= 8 {
                let existing = levels.count < bloomLevels.count ? bloomLevels[levels.count] : nil
                guard let t = target(existing, .rgba16Float, w, h) else { throw RendererError.commandQueue }
                levels.append(t); w /= 2; h /= 2
            }
            bloomLevels = levels
            levelCount = levels.count
            var bp = SIMD4<Float>(0, 0.5, bloomIntensity, 0)      // no threshold: physically plausible glare
            for (i, t) in levels.enumerated() {
                let src = i == 0 ? scene : levels[i - 1]
                try pass(t, load: .dontCare, label: "BloomDown\(i)") { e in
                    e.setRenderPipelineState(bloomDownPipeline)
                    e.setFragmentTexture(src, index: 0)
                    e.setFragmentBytes(&bp, length: 16, index: 0)
                }
            }
            for i in stride(from: levels.count - 1, to: 0, by: -1) {
                try pass(levels[i - 1], load: .load, label: "BloomUp\(i)") { e in
                    e.setRenderPipelineState(bloomUpPipeline)
                    e.setFragmentTexture(levels[i], index: 0)
                }
            }
        }
        // SSAO from the scene depth (reversed infinite Z).
        if ssaoStrength > 0 {
            aoTarget = target(aoTarget, .r16Float, sw, sh)
            guard let ao = aoTarget else { throw RendererError.commandQueue }
            let fovY = Float(c.verticalFOVDeg) * .pi / 180
            let tanY = tan(fovY / 2), tanX = tanY * Float(sw) / Float(sh)
            var ap = SIMD4<Float>(Float(c.near), tanX, tanY, 2.5)
            try pass(ao, load: .dontCare, label: "SSAO") { e in
                e.setRenderPipelineState(ssaoPipeline)
                e.setFragmentTexture(sceneDepth, index: 0)
                e.setFragmentBytes(&ap, length: 16, index: 0)
            }
        }
        // Tone map (HDR + bloom → display), then FXAA on the display-referred frame.
        let toneOut: MTLTexture
        if antialiasing {
            ldrTarget = target(ldrTarget, colorFormat, colour.width, colour.height)
            guard let l = ldrTarget else { throw RendererError.commandQueue }
            toneOut = l
        } else { toneOut = colour }
        var tp = SIMD4<Float>(0, 0, levelCount > 0 ? bloomIntensity : 0, levelCount > 0 ? 1 / Float(levelCount) : 0)
        let bloomTex = bloomLevels.first ?? scene
        try pass(toneOut, load: .dontCare, label: "Tonemap") { e in
            e.setRenderPipelineState(tonemapPipeline)
            e.setFragmentTexture(scene, index: 0)
            e.setFragmentTexture(bloomTex, index: 1)
            e.setFragmentTexture((ssaoStrength > 0 ? aoTarget : nil) ?? scene, index: 2)
            e.setFragmentBytes(&tp, length: 16, index: 0)
            var aoS = SIMD4<Float>(ssaoStrength > 0 ? ssaoStrength : 0, colourGrade, 0, 0)
            e.setFragmentBytes(&aoS, length: 16, index: 1)
        }
        if antialiasing {
            try pass(colour, load: .dontCare, label: "FXAA") { e in
                e.setRenderPipelineState(fxaaPipeline)
                e.setFragmentTexture(toneOut, index: 0)
                e.setFragmentTexture(sceneDepth, index: 1)
            }
        }
    }

    private func encodeScene(cmd: MTLCommandBuffer, colour: MTLTexture, depth: MTLTexture, camera c: WorldCamera,
                             aircraftPosition: SIMD3<Double>?, aircraftBodyToENU: simd_double3x3?) throws {
        let aspect = Double(colour.width) / Double(max(1, colour.height))
        let fwdD = simd_normalize(c.target - c.position)
        let fwd = SIMD3<Float>(Float(fwdD.x), Float(fwdD.y), Float(fwdD.z))
        let L = lighting
        let toSunF = simd_normalize(L.toSun)
        let cascades = (0..<2).map { ShadowCascades.matrix(cascade: $0, toSun: toSunF, forward: fwd, cameraWorld: c.position) }
        let sm = try shadowTexture()
        let doShadows = shadowsEnabled && toSunF.z > -0.05
        for ci in 0..<2 {
            let sp = MTLRenderPassDescriptor()
            sp.depthAttachment.texture = sm
            sp.depthAttachment.slice = ci
            sp.depthAttachment.loadAction = .clear
            sp.depthAttachment.clearDepth = 1
            sp.depthAttachment.storeAction = .store
            guard let se = cmd.makeRenderCommandEncoder(descriptor: sp) else { throw RendererError.commandQueue }
            if doShadows {
                se.setRenderPipelineState(shadowPipeline)
                se.setDepthStencilState(shadowDepthState)
                se.setCullMode(.none)
                se.setDepthBias(0, slopeScale: 1.5, clamp: 0)
                if let e = environment {
                    let o = e.origin - c.position
                    var su = ShadowUniforms(lightViewProj: cascades[ci], model: Self.translation(o))
                    se.setVertexBuffer(e.buffer, offset: 0, index: 0)
                    se.setVertexBytes(&su, length: MemoryLayout<ShadowUniforms>.stride, index: 1)
                    // Only cells inside this cascade's light volume can cast into it.
                    let lp = Self.clipPlanes(cascades[ci] * su.model)
                    for r in SpatialBinning.runs(e.cells, visible: { Self.boxVisible(lp, $0.min, $0.max) }) {
                        se.drawPrimitives(type: .triangle, vertexStart: r.lowerBound, vertexCount: r.count)
                    }
                }
                if let rw = real {
                    var su = ShadowUniforms(lightViewProj: cascades[ci], model: Self.translation(-c.position))
                    se.setRenderPipelineState(shadowTerrainPipeline)
                    se.setVertexBuffer(rw.vertices, offset: 0, index: 0)
                    se.setVertexBytes(&su, length: MemoryLayout<ShadowUniforms>.stride, index: 1)
                    // Only chunks and tree cells inside this cascade's light volume can cast into it.
                    let lp = Self.clipPlanes(cascades[ci] * su.model)
                    for d in rw.draws where Self.boxVisible(lp, d.min, d.max) {
                        se.drawIndexedPrimitives(type: .triangle, indexCount: d.indexCount, indexType: .uint32, indexBuffer: rw.indices,
                                                 indexBufferOffset: d.indexOffset * 4)
                    }
                    se.setRenderPipelineState(shadowPipeline)
                }
                if let tr = trees {
                    var su = ShadowUniforms(lightViewProj: cascades[ci], model: Self.translation(-c.position))
                    se.setRenderPipelineState(shadowTreePipeline)
                    se.setVertexBytes(&su, length: MemoryLayout<ShadowUniforms>.stride, index: 1)
                    se.setVertexBuffer(tr.mesh, offset: 0, index: 0)
                    se.setVertexBuffer(tr.instances, offset: 0, index: 2)
                    // Only tree cells inside this cascade's light volume can cast into it.
                    let lp = Self.clipPlanes(cascades[ci] * su.model)
                    let eye = SIMD3<Float>(Float(c.position.x), Float(c.position.y), Float(c.position.z))
                    let lod2 = Self.treeLODDistance * Self.treeLODDistance
                    for cell in treeCells where Self.boxVisible(lp, cell.min, cell.max) {
                        // Full mesh only in the near cascade and near cells; LOD crowns cast the rest.
                        let range = treeRange(kind: cell.kind, full: ci == 0 && Self.boxDistance2(eye, cell.min, cell.max) < lod2)
                        se.setVertexBufferOffset(cell.start * MemoryLayout<PackedTreeInstance>.stride, index: 2)   // not baseInstance (ignored on the CI GPU)
                        se.drawPrimitives(type: .triangle, vertexStart: range.start, vertexCount: range.count, instanceCount: cell.count)
                    }
                    se.setRenderPipelineState(shadowPipeline)
                }
                if let a = aircraft, let p = aircraftPosition, let m = aircraftBodyToENU {
                    var su = ShadowUniforms(lightViewProj: cascades[ci], model: Self.modelMatrix(m, p - c.position))
                    se.setVertexBuffer(a.buffer, offset: 0, index: 0)
                    se.setVertexBytes(&su, length: MemoryLayout<ShadowUniforms>.stride, index: 1)
                    se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: a.count)
                }
            }
            se.endEncoding()
        }
        // Sky (clears colour). SkyView uses y-up (x east, y up, z south).
        let skyPass = MTLRenderPassDescriptor()
        skyPass.colorAttachments[0].texture = colour
        skyPass.colorAttachments[0].loadAction = .clear
        skyPass.colorAttachments[0].storeAction = .store
        var sv = SkyView()
        // ENU (e, n, u) → sky frame (x, y up, z) is the proper rotation (e, u, −n); mapping n to +z
        // would mirror the sky (sun glow on the wrong side of the image).
        sv.yawDeg = atan2(-fwdD.y, fwdD.x) * 180 / .pi
        sv.pitchDeg = asin(max(-1, min(1, fwdD.z))) * 180 / .pi
        do {   // bank: roll the sky image to the camera's up vector
            let rC = simd_normalize(simd_cross(fwdD, c.up)), uC = simd_cross(rC, fwdD)
            let uSky = SIMD3(uC.x, uC.z, -uC.y)
            let b = sv.basis
            sv.rollDeg = atan2(-simd_dot(uSky, b.right), simd_dot(uSky, b.up)) * 180 / .pi
        }
        let fovY = c.verticalFOVDeg * .pi / 180
        sv.horizontalFOVDeg = 2 * atan(tan(fovY / 2) * aspect) * 180 / .pi
        let toSun = simd_normalize(L.toSun)
        sv.sunElevationDeg = asin(Double(toSun.z)) * 180 / .pi
        sv.sunAzimuthDeg = atan2(-Double(toSun.y), Double(toSun.x)) * 180 / .pi
        sv.viewHeightKm = max(0.002, (c.position.z / 50).rounded() * 0.05)   // 50 m bands: LUTs regenerate rarely
        sv.exposure = Double(L.exposure) * Double.pi * 3.4    // renderer units → sky radiance scale (PhysicalSky.ks)
        if L.physical != nil { sky.parameters = L.physical!.model.parameters }
        try sky.encode(into: cmd, pass: skyPass, view: sv, aspect: aspect, hdr: true)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        let cloudsOn = clouds.coverage > 0
        // Stored always: the cloud march, SSAO and the depth-aware FXAA all read scene depth (SSAO used
        // to read an undefined depth buffer on clear-sky frames).
        pass.depthAttachment.storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.commandQueue }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        let (ins, tr) = try aerialTables()
        enc.setFragmentTexture(ins, index: 0)
        enc.setFragmentTexture(tr, index: 1)
        enc.setFragmentTexture(sm, index: 2)
        enc.setFragmentTexture(imageryNear?.tex ?? dummy2D, index: 3)
        enc.setFragmentTexture(imageryFar?.tex ?? dummy2D, index: 4)
        enc.setFragmentTexture(waterTex ?? dummy2D, index: 5)
        enc.setFragmentTexture(parcelTex?.tex ?? dummy2D, index: 6)
        enc.setFragmentTexture(imageryDetail?.tex ?? dummy2D, index: 7)
        let upHint = SIMD3<Float>(Float(c.up.x), Float(c.up.y), Float(c.up.z))
        let viewProj = Self.reversedZProjection(fovY: Float(fovY), aspect: Float(aspect), near: Float(c.near)) * Self.view(forward: fwd, up: upHint)
        let sunAz = Float(atan2(Double(toSun.y), Double(toSun.x)))
        let dims = tables?.key ?? SIMD4(1, 1, 1, 1000)
        // Diffuse light reflected by the cumulus field (sunlit cloud sides and bases): clear-sky ambient alone
        // left cloud and tree shadows at ~7 % of full sun; real fair-weather shadows read ~15–20 %.
        let cloudFill = L.sunColour * max(0, toSun.z) * 0.3 * min(1, max(0, clouds.coverage))
        func uniforms(model: simd_float4x4) -> WorldUniforms {
            WorldUniforms(viewProj: viewProj, model: model, sunDir: SIMD4(toSun, sunAz), sunColour: SIMD4(L.sunColour, L.exposure),
                          ambientSky: SIMD4(L.ambientSky + cloudFill, dims.w), ambientGround: SIMD4(L.ambientGround, Float(fieldPattern?.seed ?? 0)),
                          skyHorizon: SIMD4(L.skyHorizon, fieldPattern.map { $0.autumn ? 2 : 1 } ?? 0), tableDims: SIMD4(dims.x, dims.y, dims.z, doShadows ? 2 : 0),
                          shadow0: cascades[0], shadow1: cascades[1],
                          cascadeSplits: SIMD4(ShadowCascades.splits[0], ShadowCascades.splits[1],
                                               2 * ShadowCascades.halfExtents[0] / Float(ShadowCascades.size),
                                               2 * ShadowCascades.halfExtents[1] / Float(ShadowCascades.size)),
                          cascadeDepth: SIMD4(ShadowCascades.depthRanges[0], ShadowCascades.depthRanges[1], 0, 0),
                          cameraPos: SIMD4(Float(Self.wrap(c.position.x)), Float(Self.wrap(c.position.y)), Float(c.position.z), 0),
                          cameraLocal: SIMD4(Float(c.position.x), Float(c.position.y), Float(c.position.z), 0),
                          imageryNear: imageryNear.map { SIMD4(Float($0.centre.x), Float($0.centre.y), Float($0.half), 1) } ?? .zero,
                          imageryFar: imageryFar.map { SIMD4(Float($0.centre.x), Float($0.centre.y), Float($0.half), 1) } ?? .zero,
                          clouds: CloudUniforms(layer: clouds, steps: 0).layer,
                          fieldGrid: parcelTex.map { SIMD4(Float($0.grid.iu0), Float($0.grid.iv0), Float($0.grid.width), Float($0.grid.height)) } ?? .zero,
                          imageryDetail: imageryDetail.map { SIMD4(Float($0.centre.x), Float($0.centre.y), Float($0.half), 1) } ?? .zero)
        }
        if let e = environment {
            let o = e.origin - c.position
            var u = uniforms(model: Self.translation(o))
            enc.setVertexBuffer(e.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            let fp = Self.planes(viewProj * u.model)
            var cellsDrawn = 0
            for r in SpatialBinning.runs(e.cells, visible: { c in
                let v = Self.boxVisible(fp, c.min, c.max); if v { cellsDrawn += 1 }; return v
            }) {
                enc.drawPrimitives(type: .triangle, vertexStart: r.lowerBound, vertexCount: r.count)
            }
            lastDrawnEnvironmentCells = cellsDrawn
        }
        if let rw = real {
            var u = uniforms(model: Self.translation(-c.position))
            let planes = Self.planes(viewProj)
            let o = SIMD3<Float>(Float(-c.position.x), Float(-c.position.y), Float(-c.position.z))
            enc.setRenderPipelineState(terrainPipeline)
            enc.setVertexBuffer(rw.vertices, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            var drawn = 0
            for d in rw.draws where Self.boxVisible(planes, d.min + o, d.max + o) {
                enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indexCount, indexType: .uint32, indexBuffer: rw.indices,
                                          indexBufferOffset: d.indexOffset * 4)
                drawn += 1
            }
            lastDrawnChunks = drawn
            enc.setRenderPipelineState(pipeline)
        }
        if let tr = trees {
            var u = uniforms(model: Self.translation(-c.position))
            let planes = Self.planes(viewProj)
            let o = SIMD3<Float>(Float(-c.position.x), Float(-c.position.y), Float(-c.position.z))
            enc.setRenderPipelineState(treePipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setVertexBuffer(tr.mesh, offset: 0, index: 0)
            enc.setVertexBuffer(tr.instances, offset: 0, index: 2)
            var cellsDrawn = 0
            let eye = SIMD3<Float>(Float(c.position.x), Float(c.position.y), Float(c.position.z))
            let lod2 = Self.treeLODDistance * Self.treeLODDistance
            var lodCells = 0
            for cell in treeCells where Self.boxVisible(planes, cell.min + o, cell.max + o) {
                let full = Self.boxDistance2(eye, cell.min, cell.max) < lod2
                let range = treeRange(kind: cell.kind, full: full)
                enc.setVertexBufferOffset(cell.start * MemoryLayout<PackedTreeInstance>.stride, index: 2)   // not baseInstance (ignored on the CI GPU)
                enc.drawPrimitives(type: .triangle, vertexStart: range.start, vertexCount: range.count, instanceCount: cell.count)
                cellsDrawn += 1
                if !full { lodCells += 1 }
            }
            lastLODTreeCells = lodCells
            lastDrawnTreeCells = cellsDrawn
            enc.setRenderPipelineState(pipeline)
        }
        if let a = aircraft, let p = aircraftPosition, let m = aircraftBodyToENU {
            var u = uniforms(model: Self.modelMatrix(m, p - c.position))
            if cockpitView { u.cameraPos.w = 1 }
            enc.setVertexBuffer(a.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: a.count)
            if cockpitView, let ck = cockpit {
                u.cameraPos.w = 0
                enc.setVertexBuffer(ck.buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ck.count)
                enc.setRenderPipelineState(screenPipeline)
                enc.setVertexBuffer(ck.screen, offset: 0, index: 0)
                enc.setFragmentTexture(cockpitScreen ?? dummy2D, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.setRenderPipelineState(pipeline)
            }
            if let pdisc = propDisc {
                u.cameraPos.w = 0
                enc.setRenderPipelineState(propPipeline)
                enc.setDepthStencilState(propDepthState)
                enc.setVertexBuffer(pdisc.buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: pdisc.count)
                enc.setRenderPipelineState(pipeline)
                enc.setDepthStencilState(depthState)
            }
        }
        enc.endEncoding()
        if cloudsOn {
            if cloudRenderer == nil { cloudRenderer = try CloudRenderer(device: device, colorFormat: .rgba16Float) }
            let cr = cloudRenderer!
            cr.steps = cloudSteps
            cr.downsample = cloudDownsample
            cr.lightSteps = cloudLightSteps
            var cu = CloudUniforms(layer: clouds, steps: cloudSteps)
            let r = simd_normalize(simd_cross(fwd, upHint))
            let up = simd_cross(r, fwd)
            let tanV = Float(tan(fovY / 2)), tanH = tanV * Float(aspect)
            cu.camPos = SIMD4(Float(c.position.x), Float(c.position.y), Float(c.position.z), Float(cloudSteps))
            cu.forward = SIMD4(fwd, Float(c.near)); cu.right = SIMD4(r, tanH); cu.up = SIMD4(up, tanV)
            cu.toSun = SIMD4(toSun, sunAz)
            cu.sun = SIMD4(L.sunColour, L.exposure)
            cu.skyAmb = SIMD4(L.ambientSky, dims.w)
            cu.groundAmb = SIMD4(L.ambientGround, 1)
            cu.tableDims = SIMD4(dims.x, dims.y, dims.z, 1)      // linear HDR into the scene buffer
            try cr.encode(cmd: cmd, colour: colour, depth: depth, uniforms: cu, inscatter: ins, transmit: tr)
        }
    }

    /// World coordinate modulo the 4096 m noise period (non-negative).
    static func wrap(_ v: Double) -> Double { let r = v.truncatingRemainder(dividingBy: 4_096); return r < 0 ? r + 4_096 : r }

    static func translation(_ o: SIMD3<Double>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(Float(o.x), Float(o.y), Float(o.z), 1)))
    }

    static func modelMatrix(_ m: simd_double3x3, _ o: SIMD3<Double>) -> simd_float4x4 {
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2
        return simd_float4x4(columns: (SIMD4(Float(c0.x), Float(c0.y), Float(c0.z), 0), SIMD4(Float(c1.x), Float(c1.y), Float(c1.z), 0),
                                       SIMD4(Float(c2.x), Float(c2.y), Float(c2.z), 0), SIMD4(Float(o.x), Float(o.y), Float(o.z), 1)))
    }

    public func makeDepth(width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]   // the cloud march reads scene depth
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
        return t
    }

    /// Offscreen frame to RGB8 (tests, screenshots).
    /// GPU time (ms, from command-buffer GPU timestamps) of `frames` consecutive frames rendered into an
    /// offscreen target of `width` × `height`, after `warmup` untimed frames. No readback.
    public func benchmark(width: Int, height: Int, camera: WorldCamera, frames: Int, warmup: Int = 3,
                          aircraftPosition: SIMD3<Double>? = nil, aircraftBodyToENU: simd_double3x3? = nil) throws -> [Double] {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let colour = device.makeTexture(descriptor: td) else { throw RendererError.commandQueue }
        let depth = try makeDepth(width: width, height: height)
        var times: [Double] = []
        for i in 0..<(warmup + frames) {
            guard let cmd = queue.makeCommandBuffer() else { throw RendererError.commandQueue }
            try encode(cmd: cmd, colour: colour, depth: depth, camera: camera,
                       aircraftPosition: aircraftPosition, aircraftBodyToENU: aircraftBodyToENU)
            cmd.commit()
            cmd.waitUntilCompleted()
            if let e = cmd.error { throw RendererError.pipeline(String(describing: e)) }
            if i >= warmup { times.append((cmd.gpuEndTime - cmd.gpuStartTime) * 1_000) }
        }
        return times
    }

    public func render(width: Int, height: Int, camera: WorldCamera, aircraftPosition: SIMD3<Double>? = nil,
                       aircraftBodyToENU: simd_double3x3? = nil) throws -> [UInt8] {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        guard let colour = device.makeTexture(descriptor: td),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer() else { throw RendererError.commandQueue }
        try encode(cmd: cmd, colour: colour, depth: try makeDepth(width: width, height: height), camera: camera,
                   aircraftPosition: aircraftPosition, aircraftBodyToENU: aircraftBodyToENU)
        guard let blit = cmd.makeBlitCommandEncoder() else { throw RendererError.commandQueue }
        blit.copy(from: colour, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error { throw RendererError.pipeline(String(describing: e)) }
        let src = readback.contents().bindMemory(to: UInt8.self, capacity: width * height * 4)
        let bgra = colorFormat == .bgra8Unorm
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for p in 0..<(width * height) {
            out[3 * p] = src[4 * p + (bgra ? 2 : 0)]; out[3 * p + 1] = src[4 * p + 1]; out[3 * p + 2] = src[4 * p + (bgra ? 0 : 2)]
        }
        return out
    }
}
#endif
