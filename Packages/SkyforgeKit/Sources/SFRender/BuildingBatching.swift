// SKYFORGE — Apache-2.0
// Draw batches for the building mesh and the CPU reference of the GPU culling test (`BuildingCullShaders`).
// Platform independent (tested on Linux): the Metal host code in BuildingCuller.swift only uploads these structs.
import Foundation
import SFQuickFlight
#if canImport(simd)
import simd
#endif

/// One cull cell as the compute kernel reads it. Eight scalars (32 B, no SIMD3 padding) so the layout is the
/// same in Swift and MSL (`packed_float3` + `uint` pairs).
public struct GPUCullCell: Sendable, Equatable {
    public var minX: Float, minY: Float, minZ: Float
    public var indexStart: UInt32
    public var maxX: Float, maxY: Float, maxZ: Float
    public var indexCount: UInt32
    public init(minX: Float, minY: Float, minZ: Float, indexStart: UInt32, maxX: Float, maxY: Float, maxZ: Float, indexCount: UInt32) {
        self.minX = minX; self.minY = minY; self.minZ = minZ; self.indexStart = indexStart
        self.maxX = maxX; self.maxY = maxY; self.maxZ = maxZ; self.indexCount = indexCount
    }
    public var min: SIMD3<Float> { SIMD3(minX, minY, minZ) }
    public var max: SIMD3<Float> { SIMD3(maxX, maxY, maxZ) }
}

/// `MTLDrawIndexedPrimitivesIndirectArguments`: the cull kernel writes one per batch (`instanceCount` 0 = culled).
public struct IndirectDrawArgs: Sendable, Equatable {
    public var indexCount: UInt32 = 0
    public var instanceCount: UInt32 = 0
    public var indexStart: UInt32 = 0
    public var baseVertex: Int32 = 0
    public var baseInstance: UInt32 = 0
    public init() {}
}

public enum BuildingBatching {
    /// Merges neighbouring cells whose index ranges are contiguous into batches of at most `maxIndices` indices
    /// and `maxSpan` metres across (x or y), so a sparse suburb is one draw instead of dozens. `BuildingMeshBuilder`
    /// emits its 500 m cells in row-major order with contiguous ranges, so row neighbours merge.
    public static func batches(_ cells: [BuildingMesh.Cell], maxIndices: Int = 36_000, maxSpan: Float = 1_200) -> [GPUCullCell] {
        var out: [GPUCullCell] = []
        out.reserveCapacity(cells.count)
        for c in cells where c.indexCount > 0 {
            if var last = out.last,
               Int(last.indexStart) + Int(last.indexCount) == c.indexStart,
               Int(last.indexCount) + c.indexCount <= maxIndices {
                let lo = pointwiseMin(last.min, c.min), hi = pointwiseMax(last.max, c.max)
                if hi.x - lo.x <= maxSpan && hi.y - lo.y <= maxSpan {
                    last.minX = lo.x; last.minY = lo.y; last.minZ = lo.z
                    last.maxX = hi.x; last.maxY = hi.y; last.maxZ = hi.z
                    last.indexCount += UInt32(c.indexCount)
                    out[out.count - 1] = last
                    continue
                }
            }
            out.append(GPUCullCell(minX: c.min.x, minY: c.min.y, minZ: c.min.z, indexStart: UInt32(c.indexStart),
                                   maxX: c.max.x, maxY: c.max.y, maxZ: c.max.z, indexCount: UInt32(c.indexCount)))
        }
        return out
    }

    /// Six normalised frustum planes (xyz normal pointing inside, w offset) of clip matrix `m` (given as its four columns) for Metal clip space
    /// (x, y in [−w, w], z in [0, w]); order left, right, bottom, top, near-clip (z ≥ 0), far-clip (z ≤ w).
    /// Works for reversed-Z and infinite-far projections alike, because the inequalities are in clip space.
    public static func frustumPlanes(columns c: [SIMD4<Float>]) -> [SIMD4<Float>] {
        precondition(c.count == 4)
        func row(_ i: Int) -> SIMD4<Float> { SIMD4(c[0][i], c[1][i], c[2][i], c[3][i]) }
        let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2].map { p in
            let l = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
            return l > 1e-12 ? p / l : p
        }
    }

    #if canImport(simd)
    public static func frustumPlanes(_ m: simd_float4x4) -> [SIMD4<Float>] {
        frustumPlanes(columns: [m.columns.0, m.columns.1, m.columns.2, m.columns.3])
    }
    #endif

    /// True when the box is entirely outside one of `planes` (the GPU kernel's frustum test).
    public static func outsideFrustum(min lo: SIMD3<Float>, max hi: SIMD3<Float>, planes: [SIMD4<Float>]) -> Bool {
        for p in planes {
            let v = SIMD3(p.x >= 0 ? hi.x : lo.x, p.y >= 0 ? hi.y : lo.y, p.z >= 0 ? hi.z : lo.z)
            if p.x * v.x + p.y * v.y + p.z * v.z + p.w < 0 { return true }
        }
        return false
    }

    /// Distance from `p` to the box (0 inside).
    public static func distance(from p: SIMD3<Float>, toMin lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Float {
        { let d = pointwiseMax(pointwiseMax(lo - p, p - hi), SIMD3<Float>.zero); return (d * d).sum().squareRoot() }()
    }

    /// CPU reference of the frustum + distance part of `building_cull`; the Hi-Z part needs a depth pyramid and is
    /// checked against the GPU only.
    public static func visible(_ c: GPUCullCell, planes: [SIMD4<Float>], cameraLocal: SIMD3<Float>, maxDistance: Float) -> Bool {
        if distance(from: cameraLocal, toMin: c.min, max: c.max) > maxDistance { return false }
        return !outsideFrustum(min: c.min, max: c.max, planes: planes)
    }

    /// Mip count of a Hi-Z pyramid down to 1×1 (Metal's full chain: floor(log2(max side)) + 1).
    public static func hizMipCount(width: Int, height: Int) -> Int {
        var n = 1, w = max(width, height)
        while w > 1 { w /= 2; n += 1 }
        return n
    }

    /// Mip the kernel samples for a screen rectangle `w`×`h` pixels: the first where the rectangle spans at most 2 texels
    /// per axis, so four reads cover it.
    public static func hizMip(rectPixels w: Float, _ h: Float, mipCount: Int) -> Int {
        let s = max(w, h, 1)
        return min(mipCount - 1, max(0, Int(ceil(log2(s))) - 1))
    }
}
