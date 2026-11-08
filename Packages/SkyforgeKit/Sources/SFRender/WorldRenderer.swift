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
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.commandQueue }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        let (ins, tr) = try aerialTables()
        enc.setFragmentTexture(ins, index: 0)
        enc.setFragmentTexture(tr, index: 1)
        let viewProj = Self.reversedZProjection(fovY: Float(fovY), aspect: Float(aspect), near: 0.5) * Self.view(forward: fwd)
        let sunAz = Float(atan2(Double(toSun.y), Double(toSun.x)))
        let dims = tables?.key ?? SIMD4(1, 1, 1, 1000)
        func uniforms(model: simd_float4x4) -> WorldUniforms {
            WorldUniforms(viewProj: viewProj, model: model, sunDir: SIMD4(toSun, sunAz), sunColour: SIMD4(L.sunColour, L.exposure),
                          ambientSky: SIMD4(L.ambientSky, dims.w), ambientGround: SIMD4(L.ambientGround, 0),
                          skyHorizon: SIMD4(L.skyHorizon, 0), tableDims: SIMD4(dims.x, dims.y, dims.z, 0))
        }
        if let e = environment {
            let o = e.origin - c.position
            var u = uniforms(model: simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                                           SIMD4(Float(o.x), Float(o.y), Float(o.z), 1))))
            enc.setVertexBuffer(e.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: e.count)
        }
        if let a = aircraft, let p = aircraftPosition, let m = aircraftBodyToENU {
            let o = p - c.position
            let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2
            var u = uniforms(model: simd_float4x4(columns: (SIMD4(Float(c0.x), Float(c0.y), Float(c0.z), 0),
                                                           SIMD4(Float(c1.x), Float(c1.y), Float(c1.z), 0),
                                                           SIMD4(Float(c2.x), Float(c2.y), Float(c2.z), 0),
                                                           SIMD4(Float(o.x), Float(o.y), Float(o.z), 1))))
            enc.setVertexBuffer(a.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: a.count)
        }
        enc.endEncoding()
    }

    public func makeDepth(width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget]
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
