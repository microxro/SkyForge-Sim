// SKYFORGE — Apache-2.0
// Ray tracing backend. SFPerf decides which RT passes may run (RayTracingPlan.swift); this file runs them.
// Hardware-RT devices only (`MTLDevice.supportsRaytracing`). Everything else keeps the rasterised path.
// Milestone 1: a triangle BLAS/TLAS and a compute pass that writes a ray-traced sun-shadow mask from the
// scene depth. The renderer does not call this yet, so the shipped frame is unchanged.
#if canImport(Metal)
import Foundation
import Metal
import simd
import SFPerf

public enum RayTracingError: Error, Equatable {
    case unsupported
    case invalidMesh(String)
    case buildFailed(String)
    case pipeline(String)
    case commandBuffer
}

public enum RayTracingProbe {
    /// The capability the renderer reports to SFPerf. Unsupported devices report `hardwareRT: false`.
    public static func capability(for device: MTLDevice) -> RayTracingCapability {
        RayTracingCapability(hardwareRT: device.supportsRaytracing)
    }
}

/// Triangle soup in one coordinate space (the caller decides; world or camera-relative).
public struct RTTriangleMesh: Sendable {
    public var vertices: [SIMD3<Float>]
    public var indices: [UInt32]

    public init(vertices: [SIMD3<Float>], indices: [UInt32]) {
        self.vertices = vertices
        self.indices = indices
    }

    /// Checked before any GPU work, so a bad mesh fails as a value and never reaches the driver.
    func validate() throws {
        guard !vertices.isEmpty else { throw RayTracingError.invalidMesh("no vertices") }
        guard !indices.isEmpty, indices.count % 3 == 0 else { throw RayTracingError.invalidMesh("index count is not a multiple of 3") }
        let n = UInt32(vertices.count)
        guard indices.allSatisfy({ $0 < n }) else { throw RayTracingError.invalidMesh("index out of range") }
    }
}

/// Matches `RTShadowParams` in `RayTracingShaders.source`: float4x4 at 0, float4 at 64, floats at 80/84, pad at 88. Stride 96.
struct RTShadowParamsGPU {
    var invViewProj: simd_float4x4
    var sunDir: SIMD4<Float>     // xyz direction towards the sun, w unused
    var tMax: Float
    var bias: Float
    var pad: SIMD2<Float>
}

/// Triangle BLAS wrapped in a single-instance TLAS. Built once per mesh; rebuild when the geometry changes.
public final class RayTracingScene {
    let device: MTLDevice
    let tlas: MTLAccelerationStructure
    private let blas: MTLAccelerationStructure

    public init(device: MTLDevice, queue: MTLCommandQueue, mesh: RTTriangleMesh) throws {
        guard device.supportsRaytracing else { throw RayTracingError.unsupported }
        try mesh.validate()
        self.device = device

        guard let vbuf = device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared),
              let ibuf = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw RayTracingError.buildFailed("vertex or index buffer")
        }

        let geo = MTLAccelerationStructureTriangleGeometryDescriptor()
        geo.vertexBuffer = vbuf
        geo.vertexStride = MemoryLayout<SIMD3<Float>>.stride
        geo.indexBuffer = ibuf
        geo.indexType = .uint32
        geo.triangleCount = mesh.indices.count / 3
        geo.opaque = true

        let bdesc = MTLPrimitiveAccelerationStructureDescriptor()
        bdesc.geometryDescriptors = [geo]
        let blas = try Self.build(device: device, queue: queue, descriptor: bdesc, label: "RT BLAS")
        self.blas = blas

        // One instance, identity transform. Packed 4x3 columns, column-major: (1,0,0) (0,1,0) (0,0,1) (0,0,0).
        var inst = MTLAccelerationStructureInstanceDescriptor()
        inst.accelerationStructureIndex = 0
        inst.mask = 0xFF
        inst.options = .opaque
        inst.intersectionFunctionTableOffset = 0
        var identity = MTLPackedFloat4x3()
        withUnsafeMutableBytes(of: &identity) { raw in
            let f = raw.bindMemory(to: Float.self)
            let cols: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
            for i in 0..<12 { f[i] = cols[i] }
        }
        inst.transformationMatrix = identity
        guard let instBuf = device.makeBuffer(bytes: [inst], length: MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride, options: .storageModeShared) else {
            throw RayTracingError.buildFailed("instance buffer")
        }

        let tdesc = MTLInstanceAccelerationStructureDescriptor()
        tdesc.instanceCount = 1
        tdesc.instanceDescriptorBuffer = instBuf
        tdesc.instancedAccelerationStructures = [blas]
        self.tlas = try Self.build(device: device, queue: queue, descriptor: tdesc, label: "RT TLAS")
    }

    private static func build(device: MTLDevice, queue: MTLCommandQueue, descriptor: MTLAccelerationStructureDescriptor,
                              label: String) throws -> MTLAccelerationStructure {
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RayTracingError.buildFailed(label)
        }
        accel.label = label
        enc.build(accelerationStructure: accel, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let err = cmd.error { throw RayTracingError.buildFailed("\(label): \(err.localizedDescription)") }
        return accel
    }
}

/// Ray-traced sun shadow mask: one ray per pixel from the reconstructed surface point towards the sun.
/// Output is 1 where the sun reaches the surface and 0 where something occludes it.
public final class RayTracingSunShadow {
    private let pipeline: MTLComputePipelineState
    private let scene: RayTracingScene

    public init(device: MTLDevice, scene: RayTracingScene) throws {
        guard device.supportsRaytracing else { throw RayTracingError.unsupported }
        self.scene = scene
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: RayTracingShaders.source, options: opts) }
        catch { throw RayTracingError.pipeline(String(describing: error)) }
        guard let fn = lib.makeFunction(name: "rt_sun_shadow") else { throw RayTracingError.pipeline("missing rt_sun_shadow") }
        do { pipeline = try device.makeComputePipelineState(function: fn) }
        catch { throw RayTracingError.pipeline(String(describing: error)) }
    }

    /// Encodes the shadow pass. `depth` is the scene depth (reversed-Z, depth32Float). `visibility` is r8Unorm, same size.
    public func encode(cmd: MTLCommandBuffer, depth: MTLTexture, visibility: MTLTexture, invViewProj: simd_float4x4,
                       sunDirection: SIMD3<Float>, maxDistance: Float) throws {
        guard let enc = cmd.makeComputeCommandEncoder() else { throw RayTracingError.commandBuffer }
        var p = RTShadowParamsGPU(invViewProj: invViewProj,
                                  sunDir: SIMD4<Float>(simd_normalize(sunDirection), 0),
                                  tMax: maxDistance, bias: 0.05, pad: .zero)
        enc.setComputePipelineState(pipeline)
        enc.setAccelerationStructure(scene.tlas, bufferIndex: 0)
        enc.setBytes(&p, length: MemoryLayout<RTShadowParamsGPU>.stride, index: 1)
        enc.setTexture(depth, index: 0)
        enc.setTexture(visibility, index: 1)
        enc.useResource(scene.tlas, usage: .read)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: visibility.width, height: visibility.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }
}

enum RayTracingShaders {
    static let source = """
    #include <metal_stdlib>
    #include <metal_raytracing>
    using namespace metal;
    using namespace metal::raytracing;

    struct RTShadowParams {
        float4x4 invViewProj;
        float4 sunDir;
        float tMax;
        float bias;
        float2 pad;
    };

    kernel void rt_sun_shadow(instance_acceleration_structure scene [[buffer(0)]],
                              constant RTShadowParams &p [[buffer(1)]],
                              depth2d<float, access::read> depth [[texture(0)]],
                              texture2d<float, access::write> vis [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= vis.get_width() || gid.y >= vis.get_height()) { return; }
        float d = depth.read(gid);
        // Reversed-Z: a cleared depth of 0 is sky, which the sun reaches.
        if (d <= 0.0) { vis.write(float4(1.0, 0.0, 0.0, 0.0), gid); return; }
        float2 size = float2(vis.get_width(), vis.get_height());
        float2 uv = (float2(gid) + 0.5) / size;
        float4 clip = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, d, 1.0);
        float4 world = p.invViewProj * clip;
        float3 pos = world.xyz / world.w;
        float3 dir = p.sunDir.xyz;
        intersector<triangle_data, instancing> isect;
        isect.accept_any_intersection(true);
        ray r(pos + dir * p.bias, dir, 0.0, p.tMax);
        auto hit = isect.intersect(r, scene);
        float lit = (hit.type == intersection_type::none) ? 1.0 : 0.0;
        vis.write(float4(lit, 0.0, 0.0, 0.0), gid);
    }
    """
}

#endif
