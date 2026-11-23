// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Foundation
import Metal
import simd

/// GPU-culled indirect draws for the environment cells. Off by default (`WorldRenderer.gpuEnvironmentCull`).
///
/// A compute kernel runs the same five-plane box test as the CPU path and writes one
/// `MTLDrawPrimitivesIndirectArguments` per cell; culled cells get `vertexCount` 0. The CPU path merges
/// neighbouring visible cells into runs, so this trades draw merging for GPU culling. The perf gate and the
/// frames test decide whether it becomes the default.
final class EnvironmentCullIndirect {
    /// Matches `Cell` in `source` (48 bytes).
    private struct GPUCell {
        var lo: SIMD4<Float>
        var hi: SIMD4<Float>
        var start: UInt32
        var count: UInt32
        var pad: SIMD2<UInt32>
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Cell { float4 lo; float4 hi; uint start; uint count; uint2 pad; };
    struct DrawArgs { uint vertexCount; uint instanceCount; uint vertexStart; uint baseInstance; };
    kernel void cullEnvironment(device const Cell* cells [[buffer(0)]],
                                constant float4* planes [[buffer(1)]],
                                device DrawArgs* args [[buffer(2)]],
                                constant uint& n [[buffer(3)]],
                                uint i [[thread_position_in_grid]]) {
        if (i >= n) { return; }
        Cell c = cells[i];
        bool visible = true;
        for (uint k = 0; k < 5 && visible; ++k) {
            float4 p = planes[k];
            float3 v = float3(p.x >= 0 ? c.hi.x : c.lo.x, p.y >= 0 ? c.hi.y : c.lo.y, p.z >= 0 ? c.hi.z : c.lo.z);
            if (dot(p.xyz, v) + p.w < 0) { visible = false; }
        }
        DrawArgs a;
        a.vertexCount = visible ? c.count : 0;
        a.instanceCount = 1;
        a.vertexStart = c.start;
        a.baseInstance = 0;
        args[i] = a;
    }
    """

    private let pipeline: MTLComputePipelineState
    private let cellBuffer: MTLBuffer
    private let argsBuffer: MTLBuffer
    let count: Int

    init(device: MTLDevice, cells: [MeshCell]) throws {
        let lib = try device.makeLibrary(source: Self.source, options: nil)
        guard let fn = lib.makeFunction(name: "cullEnvironment") else { throw RendererError.shaderCompile("cullEnvironment") }
        pipeline = try device.makeComputePipelineState(function: fn)
        let gpu = cells.map {
            GPUCell(lo: SIMD4($0.min, 0), hi: SIMD4($0.max, 0), start: UInt32($0.start), count: UInt32($0.count), pad: .zero)
        }
        guard !gpu.isEmpty,
              let cb = gpu.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let ab = device.makeBuffer(length: gpu.count * 16, options: .storageModePrivate) else {
            throw RendererError.commandQueue
        }
        cellBuffer = cb
        argsBuffer = ab
        count = gpu.count
    }

    /// Writes the draw arguments for this frame. `planes` are the five clip planes of `WorldRenderer.planes`.
    func dispatch(cmd: MTLCommandBuffer, planes: [SIMD4<Float>]) {
        guard count > 0, let ce = cmd.makeComputeCommandEncoder() else { return }
        ce.label = "EnvironmentCull"
        ce.setComputePipelineState(pipeline)
        ce.setBuffer(cellBuffer, offset: 0, index: 0)
        ce.setBytes(planes, length: planes.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
        ce.setBuffer(argsBuffer, offset: 0, index: 2)
        var n = UInt32(count)
        ce.setBytes(&n, length: MemoryLayout<UInt32>.stride, index: 3)
        let w = max(1, min(pipeline.threadExecutionWidth, count))
        ce.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        ce.endEncoding()
    }

    /// One indirect draw per cell; culled cells draw nothing. Call inside the main render encoder, after bindings.
    func draw(_ enc: MTLRenderCommandEncoder) {
        for i in 0..<count {
            enc.drawPrimitives(type: .triangle, indirectBuffer: argsBuffer, indirectBufferOffset: i * 16)
        }
    }
}
#endif
