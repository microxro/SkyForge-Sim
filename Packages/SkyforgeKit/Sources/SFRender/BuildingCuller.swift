// SKYFORGE — Apache-2.0
// GPU-driven building culling: a Hi-Z pyramid from the previous frame's depth, a compute pass that frustum-,
// distance- and occlusion-culls each batch and writes indirect draw arguments, and an encode helper that issues one
// indirect indexed draw per batch. Needs a Metal device; the pure parts are in BuildingBatching.swift.
#if canImport(Metal)
import Foundation
import Metal
import simd
import SFQuickFlight

/// Matches `CullUniforms` in BuildingCullShaders.source.
struct CullUniformsGPU {
    var mvp: simd_float4x4               // mesh-local → clip, this frame (frustum planes come from it)
    var hizMvp: simd_float4x4            // mesh-local → clip, of the frame the Hi-Z depth was rendered in
    var plane0: SIMD4<Float>, plane1: SIMD4<Float>, plane2: SIMD4<Float>
    var plane3: SIMD4<Float>, plane4: SIMD4<Float>, plane5: SIMD4<Float>
    var cameraLocal: SIMD4<Float>        // xyz camera in mesh-local metres, w = maximum draw distance
    var hizInfo: SIMD4<Float>            // width, height, mip count, 1 = occlusion test on
    var params: SIMD4<Float>             // depth bias (reversed-Z), minimum screen size (px) to test
    var counts: SIMD4<UInt32>            // x = cell count
}

public final class BuildingCuller {
    public enum CullError: Error { case pipeline(String), resources }
    /// Per-frame counters read back after the command buffer completes.
    public struct Stats: Sendable, Equatable { public var visible = 0, frustum = 0, occluded = 0, distance = 0 }

    public let device: MTLDevice
    private let cullPipeline: MTLComputePipelineState
    private let copyPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    public private(set) var batches: [GPUCullCell] = []
    private var cellBuffer: MTLBuffer?
    public private(set) var argsBuffer: MTLBuffer?
    private let statsBuffer: MTLBuffer
    /// Bound at texture 0 until a Hi-Z pyramid exists (a compute function with an unbound texture fails API validation).
    private let dummyHiZ: MTLTexture
    private var hiz: MTLTexture?
    private var hizViews: [MTLTexture] = []
    public var maxDistance: Float = 12_000
    /// Reversed-Z depth bias added to a box's nearest depth before the occlusion compare (hides one-frame disocclusion).
    public var depthBias: Float = 2e-5
    /// Boxes smaller than this on screen (pixels) skip the occlusion test.
    public var minOcclusionPixels: Float = 6

    public init(device: MTLDevice) throws {
        self.device = device
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: BuildingCullShaders.source, options: nil) }
        catch { throw CullError.pipeline("\(error)") }
        func pipe(_ name: String) throws -> MTLComputePipelineState {
            guard let f = lib.makeFunction(name: name) else { throw CullError.pipeline(name) }
            return try device.makeComputePipelineState(function: f)
        }
        cullPipeline = try pipe("building_cull"); copyPipeline = try pipe("hiz_copy"); downsamplePipeline = try pipe("hiz_downsample")
        guard let sb = device.makeBuffer(length: 16, options: .storageModeShared) else { throw CullError.resources }
        statsBuffer = sb
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        dd.usage = [.shaderRead]; dd.storageMode = .private
        guard let dt = device.makeTexture(descriptor: dd) else { throw CullError.resources }
        dummyHiZ = dt
    }

    /// Builds the batches from a mesh's cells and allocates the GPU buffers. Call when the building mesh changes.
    public func setCells(_ cells: [BuildingMesh.Cell], maxIndices: Int = 36_000, maxSpan: Float = 1_200) throws {
        batches = BuildingBatching.batches(cells, maxIndices: maxIndices, maxSpan: maxSpan)
        guard !batches.isEmpty else { cellBuffer = nil; argsBuffer = nil; return }
        cellBuffer = batches.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        argsBuffer = device.makeBuffer(length: batches.count * MemoryLayout<IndirectDrawArgs>.stride, options: .storageModePrivate)
        guard cellBuffer != nil, argsBuffer != nil else { throw CullError.resources }
    }

    /// (Re)creates the Hi-Z pyramid (r32Float, full mip chain) for a `width`×`height` depth buffer.
    private func ensureHiZ(width: Int, height: Int) throws {
        if let h = hiz, h.width == width, h.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: true)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw CullError.resources }
        hiz = t
        hizViews = (0..<t.mipmapLevelCount).compactMap { t.makeTextureView(pixelFormat: .r32Float, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1) }
        guard hizViews.count == t.mipmapLevelCount else { throw CullError.resources }
    }

    /// Builds the Hi-Z pyramid (per-texel minimum depth, reversed-Z so the minimum is the farthest surface) from a
    /// resolved depth texture of the frame just drawn. Encode after the main pass, before the next frame's `encodeCull`.
    public func encodeHiZ(cmd: MTLCommandBuffer, depth: MTLTexture) throws {
        try ensureHiZ(width: depth.width, height: depth.height)
        guard let enc = cmd.makeComputeCommandEncoder() else { throw CullError.resources }
        enc.label = "building hi-z"
        func dispatch(_ w: Int, _ h: Int, _ p: MTLComputePipelineState) {
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: tg)
        }
        enc.setComputePipelineState(copyPipeline)
        enc.setTexture(depth, index: 0); enc.setTexture(hizViews[0], index: 1)
        dispatch(depth.width, depth.height, copyPipeline)
        enc.setComputePipelineState(downsamplePipeline)
        for l in 1..<hizViews.count {
            enc.setTexture(hizViews[l - 1], index: 0); enc.setTexture(hizViews[l], index: 1)
            dispatch(max(1, depth.width >> l), max(1, depth.height >> l), downsamplePipeline)
        }
        enc.endEncoding()
    }

    /// Writes the indirect draw arguments for this frame. `mvp` maps mesh-local metres to clip space for this frame;
    /// `hizMvp` is the same matrix of the frame the Hi-Z depth came from (pass nil to cull on frustum and distance only).
    public func encodeCull(cmd: MTLCommandBuffer, mvp: simd_float4x4, hizMvp: simd_float4x4?, cameraLocal: SIMD3<Float>) throws {
        guard let cells = cellBuffer, let args = argsBuffer else { return }
        let planes = BuildingBatching.frustumPlanes(mvp)
        let useHiZ = hizMvp != nil && hiz != nil
        let w = Float(hiz?.width ?? 1), h = Float(hiz?.height ?? 1), mips = Float(hiz?.mipmapLevelCount ?? 1)
        var u = CullUniformsGPU(mvp: mvp, hizMvp: hizMvp ?? mvp, plane0: planes[0], plane1: planes[1], plane2: planes[2],
                                plane3: planes[3], plane4: planes[4], plane5: planes[5],
                                cameraLocal: SIMD4(cameraLocal, maxDistance), hizInfo: SIMD4(w, h, mips, useHiZ ? 1 : 0),
                                params: SIMD4(depthBias, minOcclusionPixels, 0, 0), counts: SIMD4(UInt32(batches.count), 0, 0, 0))
        // Clear on the GPU timeline: a CPU memset would race the previous frame's atomics still in flight.
        guard let blit = cmd.makeBlitCommandEncoder() else { throw CullError.resources }
        blit.label = "building cull stats clear"
        blit.fill(buffer: statsBuffer, range: 0..<16, value: 0)
        blit.endEncoding()
        guard let enc = cmd.makeComputeCommandEncoder() else { throw CullError.resources }
        enc.label = "building cull"
        enc.setComputePipelineState(cullPipeline)
        enc.setBuffer(cells, offset: 0, index: 0); enc.setBuffer(args, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<CullUniformsGPU>.stride, index: 2); enc.setBuffer(statsBuffer, offset: 0, index: 3)
        enc.setTexture(useHiZ ? hiz : dummyHiZ, index: 0)
        let n = batches.count, tg = min(64, cullPipeline.maxTotalThreadsPerThreadgroup)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
        enc.endEncoding()
    }

    /// One indirect indexed draw per batch (culled ones carry instanceCount 0). Pipeline, vertex buffers and uniforms
    /// are the caller's; `indexBuffer` is the building mesh's (uint32 indices).
    public func encodeDraws(_ enc: MTLRenderCommandEncoder, indexBuffer: MTLBuffer) {
        guard let args = argsBuffer else { return }
        let stride = MemoryLayout<IndirectDrawArgs>.stride
        for i in 0..<batches.count {
            enc.drawIndexedPrimitives(type: .triangle, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0,
                                      indirectBuffer: args, indirectBufferOffset: i * stride)
        }
    }

    /// Counters of the last `encodeCull`; valid once its command buffer has completed.
    public var lastStats: Stats {
        let p = statsBuffer.contents().bindMemory(to: UInt32.self, capacity: 4)
        return Stats(visible: Int(p[0]), frustum: Int(p[1]), occluded: Int(p[2]), distance: Int(p[3]))
    }
}
#endif
