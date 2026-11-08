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
    public init(position: SIMD3<Double>, target: SIMD3<Double>, verticalFOVDeg: Double = 55) {
        self.position = position; self.target = target; self.verticalFOVDeg = verticalFOVDeg
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
    private var real: (vertices: MTLBuffer, indices: MTLBuffer, draws: [(indexOffset: Int, indexCount: Int, baseVertex: Int, min: SIMD3<Float>, max: SIMD3<Float>)],
                       treeMesh: MTLBuffer, coniferCount: Int, oakStart: Int, oakCount: Int,
                       instances: MTLBuffer?, coniferInstances: Int, oakInstances: Int)?
    private var imageryNear: (tex: MTLTexture, centre: SIMD2<Double>, half: Double)?
    private var imageryFar: (tex: MTLTexture, centre: SIMD2<Double>, half: Double)?
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
    private var cloudRenderer: CloudRenderer?
    private let sky: PhysicalSkyRenderer
    private var environment: (buffer: MTLBuffer, count: Int, origin: SIMD3<Double>)?
    private var aircraft: (buffer: MTLBuffer, count: Int)?
    private var tables: (ins: MTLTexture, tr: MTLTexture, key: SIMD4<Float>)?
    public private(set) var lighting: LightingSetup
    public let colorFormat: MTLPixelFormat

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), colorFormat: MTLPixelFormat = .rgba8Unorm,
                lighting: LightingSetup) throws {
        guard let device else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandQueue }
        self.device = device
        self.queue = queue
        self.colorFormat = colorFormat
        self.lighting = lighting
        sky = try PhysicalSkyRenderer(device: device, colorFormat: colorFormat)
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: WorldShaders.source, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        guard let v = lib.makeFunction(name: "world_vertex"), let f = lib.makeFunction(name: "world_fragment") else {
            throw RendererError.shaderCompile("missing world functions")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "World"
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = colorFormat
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
            if colour { d.colorAttachments[0].pixelFormat = colorFormat }
            d.depthAttachmentPixelFormat = .depth32Float
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RendererError.pipeline(String(describing: error)) }
        }
        terrainPipeline = try pso("terrain_vertex", "world_fragment", label: "RealTerrain", colour: true)
        treePipeline = try pso("tree_vertex", "world_fragment", label: "Trees", colour: true)
        shadowTerrainPipeline = try pso("shadow_terrain_vertex", nil, label: "ShadowTerrain", colour: false)
        shadowTreePipeline = try pso("shadow_tree_vertex", nil, label: "ShadowTrees", colour: false)
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
    static func treeMeshes() -> (conifer: [PackedTerrainVertex], oak: [PackedTerrainVertex]) {
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
        return (conifer, oak)
    }

    /// Uploads real-world terrain chunks, tree instances and imagery.
    public func setRealWorld(_ data: RealWorldRenderData) throws {
        func q(_ x: Float) -> Int8 { Int8(max(-127, min(127, (x * 127).rounded()))) }
        var verts: [PackedTerrainVertex] = [], idx: [UInt32] = []
        var draws: [(Int, Int, Int, SIMD3<Float>, SIMD3<Float>)] = []
        for c in data.chunks {
            let base = verts.count
            for (p, n) in zip(c.positions, c.normals) { verts.append(PackedTerrainVertex(px: p.x, py: p.y, pz: p.z, nx: q(n.x), ny: q(n.y), nz: q(n.z), nw: 127)) }
            draws.append((idx.count, c.indices.count, base, c.boundsMin, c.boundsMax))
            idx += c.indices
        }
        let meshes = Self.treeMeshes()
        let treeVerts = meshes.conifer + meshes.oak
        let conifers = data.trees.filter(\.conifer), oaks = data.trees.filter { !$0.conifer }
        let inst = (conifers + oaks).map { PackedTreeInstance(px: $0.position.x, py: $0.position.y, pz: $0.position.z, height: $0.height,
                                                               r: $0.colour.x, g: $0.colour.y, b: $0.colour.z, kind: $0.conifer ? 0 : 1) }
        func buf<T>(_ a: [T]) throws -> MTLBuffer {
            guard !a.isEmpty, let b = a.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw RendererError.commandQueue
            }
            return b
        }
        precondition(MemoryLayout<PackedTerrainVertex>.stride == 16 && MemoryLayout<PackedTreeInstance>.stride == 32)
        real = (try buf(verts), try buf(idx), draws.map { (indexOffset: $0.0, indexCount: $0.1, baseVertex: $0.2, min: $0.3, max: $0.4) },
                try buf(treeVerts), meshes.conifer.count, meshes.conifer.count, meshes.oak.count,
                inst.isEmpty ? nil : try buf(inst), conifers.count, oaks.count)
        func imageryTexture(_ i: RealWorldRenderData.Imagery) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: i.size, height: i.size, mipmapped: true)
            d.usage = [.shaderRead]
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.commandQueue }
            var rgba = [UInt8](repeating: 255, count: i.size * i.size * 4)
            for p in 0..<(i.size * i.size) { rgba[4 * p] = i.rgb[3 * p]; rgba[4 * p + 1] = i.rgb[3 * p + 1]; rgba[4 * p + 2] = i.rgb[3 * p + 2] }
            t.replace(region: MTLRegionMake2D(0, 0, i.size, i.size), mipmapLevel: 0, withBytes: rgba, bytesPerRow: i.size * 4)
            if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: t); blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
            }
            return t
        }
        imageryNear = try data.near.map { (try imageryTexture($0), $0.centre, $0.halfExtent) }
        imageryFar = try data.far.map { (try imageryTexture($0), $0.centre, $0.halfExtent) }
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

    static func pack(_ soup: TriangleSoup) -> [PackedWorldVertex] {
        var out = [PackedWorldVertex]()
        out.reserveCapacity(soup.triangleCount * 3)
        func q(_ x: Float) -> Int8 { Int8(max(-127, min(127, (x * 127).rounded()))) }
        func c(_ x: Float) -> UInt8 { UInt8(max(0, min(255, (max(0, x).squareRoot() * 255).rounded()))) }
        for t in 0..<soup.triangleCount {
            let a = soup.albedo[t], m = soup.material[t].rawValue
            for k in 0..<3 {
                let p = soup.positions[3 * t + k], n = soup.normals[3 * t + k]
                out.append(PackedWorldVertex(px: p.x, py: p.y, pz: p.z, nx: q(n.x), ny: q(n.y), nz: q(n.z), nw: 0,
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
        environment = (try makeBuffer(Self.pack(soup)), soup.triangleCount * 3, soup.origin)
    }

    public func setAircraft(_ soup: TriangleSoup) throws {
        aircraft = (try makeBuffer(Self.pack(soup)), soup.triangleCount * 3)
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
    static func view(forward f: SIMD3<Float>) -> simd_float4x4 {
        let r = simd_normalize(simd_cross(f, SIMD3(0, 0, 1)))
        let u = simd_cross(r, f)
        return simd_float4x4(rows: [SIMD4(r, 0), SIMD4(u, 0), SIMD4(-f, 0), SIMD4(0, 0, 0, 1)])
    }

    /// Encodes sky + world + aircraft into a pass whose colour attachment is already set.
    public func encode(cmd: MTLCommandBuffer, colour: MTLTexture, depth: MTLTexture, camera c: WorldCamera,
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
                    se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: e.count)
                }
                if let rw = real {
                    var su = ShadowUniforms(lightViewProj: cascades[ci], model: Self.translation(-c.position))
                    se.setRenderPipelineState(shadowTerrainPipeline)
                    se.setVertexBuffer(rw.vertices, offset: 0, index: 0)
                    se.setVertexBytes(&su, length: MemoryLayout<ShadowUniforms>.stride, index: 1)
                    for d in rw.draws {
                        se.drawIndexedPrimitives(type: .triangle, indexCount: d.indexCount, indexType: .uint32, indexBuffer: rw.indices,
                                                 indexBufferOffset: d.indexOffset * 4, instanceCount: 1, baseVertex: d.baseVertex, baseInstance: 0)
                    }
                    if let ib = rw.instances {
                        se.setRenderPipelineState(shadowTreePipeline)
                        se.setVertexBuffer(rw.treeMesh, offset: 0, index: 0)
                        se.setVertexBuffer(ib, offset: 0, index: 2)
                        if rw.coniferInstances > 0 {
                            se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: rw.coniferCount, instanceCount: rw.coniferInstances, baseInstance: 0)
                        }
                        if rw.oakInstances > 0 {
                            se.drawPrimitives(type: .triangle, vertexStart: rw.oakStart, vertexCount: rw.oakCount, instanceCount: rw.oakInstances,
                                              baseInstance: rw.coniferInstances)
                        }
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
        // Sky (clears colour). SkyView uses y-up (x east, y up, z north).
        let skyPass = MTLRenderPassDescriptor()
        skyPass.colorAttachments[0].texture = colour
        skyPass.colorAttachments[0].loadAction = .clear
        skyPass.colorAttachments[0].storeAction = .store
        var sv = SkyView()
        sv.yawDeg = atan2(fwdD.y, fwdD.x) * 180 / .pi
        sv.pitchDeg = asin(max(-1, min(1, fwdD.z))) * 180 / .pi
        let fovY = c.verticalFOVDeg * .pi / 180
        sv.horizontalFOVDeg = 2 * atan(tan(fovY / 2) * aspect) * 180 / .pi
        let toSun = simd_normalize(L.toSun)
        sv.sunElevationDeg = asin(Double(toSun.z)) * 180 / .pi
        sv.sunAzimuthDeg = atan2(Double(toSun.y), Double(toSun.x)) * 180 / .pi
        sv.viewHeightKm = max(0.002, (c.position.z / 50).rounded() * 0.05)   // 50 m bands: LUTs regenerate rarely
        sv.exposure = Double(L.exposure) * Double.pi * 3.4    // renderer units → sky radiance scale (PhysicalSky.ks)
        if L.physical != nil { sky.parameters = L.physical!.model.parameters }
        try sky.encode(into: cmd, pass: skyPass, view: sv, aspect: aspect)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        let cloudsOn = clouds.coverage > 0
        pass.depthAttachment.storeAction = cloudsOn ? .store : .dontCare
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
        let viewProj = Self.reversedZProjection(fovY: Float(fovY), aspect: Float(aspect), near: 0.5) * Self.view(forward: fwd)
        let sunAz = Float(atan2(Double(toSun.y), Double(toSun.x)))
        let dims = tables?.key ?? SIMD4(1, 1, 1, 1000)
        func uniforms(model: simd_float4x4) -> WorldUniforms {
            WorldUniforms(viewProj: viewProj, model: model, sunDir: SIMD4(toSun, sunAz), sunColour: SIMD4(L.sunColour, L.exposure),
                          ambientSky: SIMD4(L.ambientSky, dims.w), ambientGround: SIMD4(L.ambientGround, 0),
                          skyHorizon: SIMD4(L.skyHorizon, 0), tableDims: SIMD4(dims.x, dims.y, dims.z, doShadows ? 2 : 0),
                          shadow0: cascades[0], shadow1: cascades[1],
                          cascadeSplits: SIMD4(ShadowCascades.splits[0], ShadowCascades.splits[1],
                                               2 * ShadowCascades.halfExtents[0] / Float(ShadowCascades.size),
                                               2 * ShadowCascades.halfExtents[1] / Float(ShadowCascades.size)),
                          cascadeDepth: SIMD4(ShadowCascades.depthRanges[0], ShadowCascades.depthRanges[1], 0, 0),
                          cameraPos: SIMD4(Float(Self.wrap(c.position.x)), Float(Self.wrap(c.position.y)), Float(c.position.z), 0),
                          cameraLocal: SIMD4(Float(c.position.x), Float(c.position.y), Float(c.position.z), 0),
                          imageryNear: imageryNear.map { SIMD4(Float($0.centre.x), Float($0.centre.y), Float($0.half), 1) } ?? .zero,
                          imageryFar: imageryFar.map { SIMD4(Float($0.centre.x), Float($0.centre.y), Float($0.half), 1) } ?? .zero)
        }
        if let e = environment {
            let o = e.origin - c.position
            var u = uniforms(model: Self.translation(o))
            enc.setVertexBuffer(e.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: e.count)
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
                                          indexBufferOffset: d.indexOffset * 4, instanceCount: 1, baseVertex: d.baseVertex, baseInstance: 0)
                drawn += 1
            }
            lastDrawnChunks = drawn
            if let ib = rw.instances {
                enc.setRenderPipelineState(treePipeline)
                enc.setVertexBuffer(rw.treeMesh, offset: 0, index: 0)
                enc.setVertexBuffer(ib, offset: 0, index: 2)
                if rw.coniferInstances > 0 {
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: rw.coniferCount, instanceCount: rw.coniferInstances, baseInstance: 0)
                }
                if rw.oakInstances > 0 {
                    enc.drawPrimitives(type: .triangle, vertexStart: rw.oakStart, vertexCount: rw.oakCount, instanceCount: rw.oakInstances,
                                       baseInstance: rw.coniferInstances)
                }
            }
            enc.setRenderPipelineState(pipeline)
        }
        if let a = aircraft, let p = aircraftPosition, let m = aircraftBodyToENU {
            var u = uniforms(model: Self.modelMatrix(m, p - c.position))
            enc.setVertexBuffer(a.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: a.count)
        }
        enc.endEncoding()
        if cloudsOn {
            if cloudRenderer == nil { cloudRenderer = try CloudRenderer(device: device, colorFormat: colorFormat) }
            let cr = cloudRenderer!
            cr.steps = cloudSteps
            var cu = CloudUniforms(layer: clouds, steps: cloudSteps)
            let r = simd_normalize(simd_cross(fwd, SIMD3<Float>(0, 0, 1)))
            let up = simd_cross(r, fwd)
            let tanV = Float(tan(fovY / 2)), tanH = tanV * Float(aspect)
            cu.camPos = SIMD4(Float(c.position.x), Float(c.position.y), Float(c.position.z), Float(cloudSteps))
            cu.forward = SIMD4(fwd, 0.5); cu.right = SIMD4(r, tanH); cu.up = SIMD4(up, tanV)
            cu.toSun = SIMD4(toSun, sunAz)
            cu.sun = SIMD4(L.sunColour, L.exposure)
            cu.skyAmb = SIMD4(L.ambientSky, dims.w)
            cu.groundAmb = SIMD4(L.ambientGround, 1)
            cu.tableDims = SIMD4(dims.x, dims.y, dims.z, 0)
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
