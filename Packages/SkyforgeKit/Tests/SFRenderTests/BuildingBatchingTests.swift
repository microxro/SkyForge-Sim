// SKYFORGE — Apache-2.0
import Testing
import Foundation
#if canImport(simd)
import simd
#endif
@testable import SFRender
@testable import SFQuickFlight

@Suite struct BuildingBatchingTests {
    static func cell(_ start: Int, _ count: Int, x: Float, y: Float = 0, size: Float = 100) -> BuildingMesh.Cell {
        BuildingMesh.Cell(indexStart: start, indexCount: count, min: SIMD3(x, y, 0), max: SIMD3(x + size, y + size, 20))
    }

    /// Metal-convention perspective columns (clip z in [0, w]); camera at the origin looking down −z.
    static func projectionColumns(fovY: Float = 1.0, aspect: Float = 1.5, near: Float = 1, far: Float = 1_000) -> [SIMD4<Float>] {
        let f = 1 / tan(fovY / 2)
        return [SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)]
    }
    /// Reversed-Z, infinite far (z_clip = near, w = −z_eye: depth 1 at the near plane, 0 at infinity).
    static func reversedInfiniteColumns(fovY: Float = 1.0, aspect: Float = 1.5, near: Float = 0.5) -> [SIMD4<Float>] {
        let f = 1 / tan(fovY / 2)
        return [SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)]
    }
    #if canImport(simd)
    static func projection(fovY: Float = 1.0, aspect: Float = 1.5, near: Float = 1, far: Float = 1_000) -> simd_float4x4 {
        let c = projectionColumns(fovY: fovY, aspect: aspect, near: near, far: far)
        return simd_float4x4(columns: (c[0], c[1], c[2], c[3]))
    }
    #endif

    @Test func gpuStructLayoutsMatchTheShader() {
        #expect(MemoryLayout<GPUCullCell>.size == 32 && MemoryLayout<GPUCullCell>.stride == 32)
        #expect(MemoryLayout<IndirectDrawArgs>.size == 20 && MemoryLayout<IndirectDrawArgs>.stride == 20)
    }

    @Test func contiguousNeighbourCellsMergeUpToTheLimits() {
        let cells = [Self.cell(0, 100, x: 0), Self.cell(100, 100, x: 100), Self.cell(200, 100, x: 200)]
        let one = BuildingBatching.batches(cells)
        #expect(one.count == 1 && one[0].indexStart == 0 && one[0].indexCount == 300)
        #expect(one[0].min == SIMD3(0, 0, 0) && one[0].max == SIMD3(300, 100, 20))
        // Index limit: 250 per batch splits after two cells.
        let split = BuildingBatching.batches(cells, maxIndices: 250)
        #expect(split.map(\.indexCount) == [200, 100])
        // Span limit: 250 m across keeps only two 100 m cells together.
        #expect(BuildingBatching.batches(cells, maxSpan: 250).map(\.indexCount) == [200, 100])
        // A gap in the index ranges never merges, and empty cells are dropped.
        let gap = BuildingBatching.batches([Self.cell(0, 100, x: 0), Self.cell(150, 100, x: 100), Self.cell(250, 0, x: 200)])
        #expect(gap.map(\.indexStart) == [0, 150])
    }

    @Test func frustumPlanesCullBoxesOutsideTheView() {
        let planes = BuildingBatching.frustumPlanes(columns: Self.projectionColumns())
        #expect(planes.count == 6)
        // In front of the camera.
        #expect(!BuildingBatching.outsideFrustum(min: SIMD3(-5, -5, -30), max: SIMD3(5, 5, -20), planes: planes))
        // Behind it, far to the left, beyond the far plane.
        #expect(BuildingBatching.outsideFrustum(min: SIMD3(-5, -5, 20), max: SIMD3(5, 5, 30), planes: planes))
        #expect(BuildingBatching.outsideFrustum(min: SIMD3(-600, -5, -30), max: SIMD3(-500, 5, -20), planes: planes))
        #expect(BuildingBatching.outsideFrustum(min: SIMD3(-5, -5, -1_600), max: SIMD3(5, 5, -1_500), planes: planes))
        // A box straddling the left plane is kept.
        #expect(!BuildingBatching.outsideFrustum(min: SIMD3(-60, -1, -50), max: SIMD3(-20, 1, -40), planes: planes))
    }

    @Test func visibleCombinesDistanceAndFrustum() {
        let planes = BuildingBatching.frustumPlanes(columns: Self.projectionColumns())
        let c = GPUCullCell(minX: -5, minY: -5, minZ: -300, indexStart: 0, maxX: 5, maxY: 5, maxZ: -290, indexCount: 30)
        #expect(BuildingBatching.visible(c, planes: planes, cameraLocal: .zero, maxDistance: 1_000))
        #expect(!BuildingBatching.visible(c, planes: planes, cameraLocal: .zero, maxDistance: 200))
        #expect(BuildingBatching.distance(from: SIMD3(0, 0, 0), toMin: SIMD3(3, 4, 0), max: SIMD3(9, 9, 9)) == 5)
        #expect(BuildingBatching.distance(from: SIMD3(5, 5, 5), toMin: SIMD3(0, 0, 0), max: SIMD3(9, 9, 9)) == 0)
    }

    @Test func hizMipSelection() {
        #expect(BuildingBatching.hizMipCount(width: 1_920, height: 1_080) == 11)
        #expect(BuildingBatching.hizMipCount(width: 1, height: 1) == 1)
        #expect(BuildingBatching.hizMip(rectPixels: 1, 1, mipCount: 11) == 0)
        #expect(BuildingBatching.hizMip(rectPixels: 64, 10, mipCount: 11) == 5)     // 64 px → 2 texels at mip 5
        #expect(BuildingBatching.hizMip(rectPixels: 1e6, 1, mipCount: 11) == 10)    // clamped to the last mip
    }

    /// Reversed-Z infinite-far projection with the renderer's convention: mvp = viewProj * translation(−camera),
    /// mesh-local → clip, `cameraLocal` = camera position in mesh-local metres. Camera at (1000, 2000, 50) looks north.
    @Test func reversedZInfiniteFarWithCameraRelativeMvp() {
        let cam = SIMD3<Float>(1_000, 2_000, 50)
        // View (z up, looking +y): x_e = x, y_e = z, z_e = −y, applied to camera-relative coordinates.
        func clip(_ p: SIMD3<Float>) -> SIMD4<Float> {
            let r = p - cam, e = SIMD4<Float>(r.x, r.z, -r.y, 1)
            let c = Self.reversedInfiniteColumns()
            return c[0] * e.x + c[1] * e.y + c[2] * e.z + c[3] * e.w
        }
        // Planes of mvp = P·V·T(−cam): build the columns of that product by transforming the basis points.
        let o = clip(SIMD3(0, 0, 0)), x = clip(SIMD3(1, 0, 0)) - o, y = clip(SIMD3(0, 1, 0)) - o, z = clip(SIMD3(0, 0, 1)) - o
        let planes = BuildingBatching.frustumPlanes(columns: [x, y, z, o])
        let ahead = (min: cam + SIMD3<Float>(-5, 100, -20), max: cam + SIMD3<Float>(5, 110, -10))
        #expect(!BuildingBatching.outsideFrustum(min: ahead.min, max: ahead.max, planes: planes))
        #expect(!BuildingBatching.outsideFrustum(min: cam + SIMD3(-5, 50_000, -20), max: cam + SIMD3(5, 50_010, -10), planes: planes), "infinite far never culls")
        #expect(BuildingBatching.outsideFrustum(min: cam + SIMD3(-5, -110, -20), max: cam + SIMD3(5, -100, -10), planes: planes), "behind the camera")
        #expect(BuildingBatching.outsideFrustum(min: cam + SIMD3(-900, 100, -20), max: cam + SIMD3(-800, 110, -10), planes: planes), "far left")
        #expect(BuildingBatching.visible(GPUCullCell(minX: ahead.min.x, minY: ahead.min.y, minZ: ahead.min.z, indexStart: 0,
                                                     maxX: ahead.max.x, maxY: ahead.max.y, maxZ: ahead.max.z, indexCount: 3),
                                         planes: planes, cameraLocal: cam, maxDistance: 500))
    }
}
