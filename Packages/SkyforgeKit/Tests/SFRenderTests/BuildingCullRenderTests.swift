// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
import Foundation
import Metal
import simd
@testable import SFRender
@testable import SFQuickFlight

/// The compute kernel against the CPU reference (`BuildingBatching.visible`), frustum and distance only. The Hi-Z test
/// needs a rendered depth pyramid and is checked on device by the integrator (docs/rounds/ROUND2.md).
@Suite struct BuildingCullRenderTests {
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func kernelMatchesCPUReferenceWithoutHiZ() throws {
        // Camera 50 m up looking north (+y); mesh-local = camera-relative here.
        let view = simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, -50), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1)])
        try Self.check(mvp: BuildingBatchingTests.projection(far: 2_000) * view, cam: SIMD3<Float>(0, 0, 50))
    }

    /// The renderer's convention: reversed-Z infinite-far projection, mvp = viewProj * translation(−camera), cameraLocal =
    /// camera position (mesh-local metres), camera away from the mesh origin.
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func kernelMatchesCPUReferenceWithReversedZCameraRelativeMvp() throws {
        let cam = SIMD3<Float>(120, -80, 50)
        let c = BuildingBatchingTests.reversedInfiniteColumns()
        let proj = simd_float4x4(columns: (c[0], c[1], c[2], c[3]))
        let view = simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1)])
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(-cam, 1)
        try Self.check(mvp: proj * view * t, cam: cam)
    }

    static func check(mvp: simd_float4x4, cam: SIMD3<Float>) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let culler = try BuildingCuller(device: device)
        culler.maxDistance = 900
        // A 20 × 20 field of 100 m cells with separate index ranges (gaps stop merging), around the origin.
        var cells: [BuildingMesh.Cell] = []
        for j in 0..<20 { for i in 0..<20 {
            let k = j * 20 + i
            cells.append(BuildingMesh.Cell(indexStart: k * 100, indexCount: 30,
                                           min: SIMD3(Float(i - 10) * 100, Float(j - 10) * 100, 0), max: SIMD3(Float(i - 9) * 100 - 10, Float(j - 9) * 100 - 10, 25)))
        } }
        try culler.setCells(cells)
        #expect(culler.batches.count == 400)
        let cmd = try #require(queue.makeCommandBuffer())
        try culler.encodeCull(cmd: cmd, mvp: mvp, hizMvp: nil, cameraLocal: cam)
        cmd.commit(); cmd.waitUntilCompleted()
        let args = try #require(culler.argsBuffer)
        let staging = try #require(device.makeBuffer(length: args.length, options: .storageModeShared))
        let blit = try #require(queue.makeCommandBuffer())
        let enc = try #require(blit.makeBlitCommandEncoder())
        enc.copy(from: args, sourceOffset: 0, to: staging, destinationOffset: 0, size: args.length); enc.endEncoding()
        blit.commit(); blit.waitUntilCompleted()
        let got = staging.contents().bindMemory(to: IndirectDrawArgs.self, capacity: culler.batches.count)
        let planes = BuildingBatching.frustumPlanes(mvp)
        var mismatches = 0, drawn = 0
        for (i, b) in culler.batches.enumerated() {
            let want = BuildingBatching.visible(b, planes: planes, cameraLocal: cam, maxDistance: culler.maxDistance)
            if (got[i].instanceCount == 1) != want { mismatches += 1 }
            #expect(got[i].indexCount == b.indexCount && got[i].indexStart == b.indexStart)
            if got[i].instanceCount == 1 { drawn += 1 }
        }
        #expect(mismatches == 0, "\(mismatches) cells differ from the CPU reference")
        #expect(drawn > 0 && drawn < 400)
        #expect(culler.lastStats.visible == drawn)
    }
}
#endif
