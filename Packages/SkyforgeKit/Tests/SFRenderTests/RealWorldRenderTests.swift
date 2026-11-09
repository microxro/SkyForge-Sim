// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFRender
import SFQuickFlight
import SFImagery
import SFContent
import SFPreview
#if canImport(simd)
import simd
#endif

/// Serves the USGS fixture JPEG for imagery hosts; elevation is offline (bundled global DEM). No network.
actor FixtureImageryTransport: HTTPTransport {
    let jpeg: Data
    init() throws {
        jpeg = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/imagery/usgs_15_13676_9038.jpg"))
    }
    func get(_ url: URL) async throws -> Data {
        if url.host == "basemap.nationalmap.gov" || url.host == "tiles.maps.eox.at" { return jpeg }
        throw TransportError.offline
    }
}

@Suite struct RealWorldRenderTests {
    static let detail = RealWorldDetail(nearHalf: 1_500, nearStep: 30, midHalf: 5_000, midStep: 150, farHalf: 12_000, farStep: 800,
                                        imageryNearSize: 512, imageryFarSize: 256, treeRadius: 700, maxTrees: 4_000)

    static func region() async throws -> RealWorldRegion {
        try await RealWorldRegion.load(airport: "KCOI", detail: detail, transport: try FixtureImageryTransport(), cache: nil)
    }

    @Test func regionConvertsToRenderData() async throws {
        let r = try await Self.region()
        let d = RealWorldRenderData(region: r, chunkQuads: 16)
        #expect(d.chunks.count == r.terrainChunks(quads: 16).count)
        #expect(d.trees.count == r.trees().count && !d.trees.isEmpty)
        let near = try #require(d.near)
        #expect(near.rgb.count == near.size * near.size * 3)
        let mask = try #require(d.waterMask)
        #expect(mask.values.count == mask.size * mask.size)
        #expect(d.far != nil)
    }

    #if canImport(Metal)
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func realWorldFrameRenders() async throws {
        let region = try await Self.region()
        let data = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let lighting = LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z)
        let r = try WorldRenderer(lighting: lighting)
        try r.setRealWorld(data)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        let c = session.bodyToENUColumns
        let w = 320, h = 180
        let img = try r.render(width: w, height: h, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        _ = VisualRegression.check(name: "metal_realworld_320x180", rgb: img, width: w, height: h, goldenDir: goldenDir)
        func px(_ x: Int, _ y: Int) -> SIMD3<Int> { let i = 3 * (y * w + x); return SIMD3(Int(img[i]), Int(img[i + 1]), Int(img[i + 2])) }
        let top = px(w / 4, 3)
        #expect(top.z > top.x, "sky at top is blue: \(top)")
        // Ground (imagery, or 3D trees standing on it) along the bottom row, not sky: most pixels are not
        // blue-dominant (one pixel can be a sky-lit shaded crown).
        let groundLike = (0..<w).filter { x in let p = px(x, h - 3); return p.z < p.x || p.z < p.y }.count
        #expect(groundLike > w * 2 / 3, "imagery ground at bottom: \(groundLike)/\(w)")
        #expect(r.lastDrawnChunks > 0 && r.lastDrawnChunks < data.chunks.count,
                "frustum culling drew \(r.lastDrawnChunks) of \(data.chunks.count) chunks")
        #expect(r.lastDrawnTreeCells > 0 && r.lastDrawnTreeCells <= r.treeCellCount,
                "tree cells culled: drew \(r.lastDrawnTreeCells) of \(r.treeCellCount)")
        // Distant cells use the crown-only LOD (at most a quarter of the full mesh's vertices).
        #expect(r.lastLODTreeCells > 0 && r.lastLODTreeCells <= r.lastDrawnTreeCells, "LOD cells \(r.lastLODTreeCells)")
        let m = WorldRenderer.treeMeshes()
        #expect(m.coniferLow.count * 4 <= m.conifer.count && m.oakLow.count * 4 <= m.oak.count)
        // The lower half is textured photo ground, not a flat fill.
        var lo = Int.max, hi = 0
        for y in (h / 2)..<h { for x in 0..<(w / 3) { let s = px(x, y).x + px(x, y).y + px(x, y).z; lo = min(lo, s); hi = max(hi, s) } }
        #expect(hi - lo > 40, "ground contrast \(hi - lo)")
    }

    /// FXAA leaves photo texture alone (depth-aware): on ground-only pixels the antialiased frame equals
    /// the raw one. Plain FXAA smeared imagery along detected "edges" by up to 8 px.
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func fxaaDoesNotSmearGroundTexture() async throws {
        let region = try await Self.region()
        let data = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        try r.setRealWorld(RealWorldRenderData(chunks: data.chunks, trees: [], near: data.near, far: data.far, waterMask: data.waterMask))
        r.clouds = .clear
        let w = 320, h = 180, camera = WorldCamera(position: cam.position, target: cam.target)
        r.antialiasing = true
        let on = try r.render(width: w, height: h, camera: camera)
        r.antialiasing = false
        let off = try r.render(width: w, height: h, camera: camera)
        var diff = 0, n = 0
        for y in (h * 3 / 4)..<(h - 2) { for x in 2..<(w - 2) { for k in 0..<3 {
            diff += abs(Int(on[3 * (y * w + x) + k]) - Int(off[3 * (y * w + x) + k])); n += 1
        } } }
        #expect(Double(diff) / Double(n) < 0.5, "mean |FXAA − raw| on ground: \(Double(diff) / Double(n))")
    }

    /// Four flat 2×2 km chunks seen straight down must cover the whole frame: every chunk's triangles
    /// come from its own vertices (the CI GPU assembled later chunks from the wrong ones with `baseVertex`).
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func everyChunkUsesItsOwnVertices() throws {
        var chunks: [RealWorldRenderData.Chunk] = []
        let q = 8
        for (cx, cy) in [(-1, -1), (0, -1), (-1, 0), (0, 0)] {
            var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = []
            for j in 0...q { for i in 0...q {
                pos.append(SIMD3(Float(cx * 2_000 + i * 2_000 / q), Float(cy * 2_000 + j * 2_000 / q), 0)); nrm.append(SIMD3(0, 0, 1))
            } }
            var idx: [UInt32] = []
            for j in 0..<q { for i in 0..<q {
                let a = UInt32(j * (q + 1) + i), b = a + 1, c = a + UInt32(q + 1), e = c + 1
                idx += [a, b, e, a, e, c]
            } }
            chunks.append(.init(positions: pos, normals: nrm, indices: idx,
                                boundsMin: SIMD3(Float(cx * 2_000), Float(cy * 2_000), 0), boundsMax: SIMD3(Float(cx * 2_000 + 2_000), Float(cy * 2_000 + 2_000), 0)))
        }
        let data = RealWorldRenderData(chunks: chunks, trees: [], near: nil, far: nil, waterMask: nil)
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: 900))
        try r.setRealWorld(data)
        let w = 96, h = 96
        let img = try r.render(width: w, height: h, camera: WorldCamera(position: SIMD3(0, -1, 900), target: SIMD3(0, 0, 0)))
        #expect(r.lastDrawnChunks == 4)
        // Each quadrant is one chunk; all four must look alike (a broken chunk shows bright sky instead).
        var means: [SIMD3<Double>] = []
        for (qx, qy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            var m = SIMD3<Double>.zero
            for y in (qy * h / 2 + 4)..<((qy + 1) * h / 2 - 4) { for x in (qx * w / 2 + 4)..<((qx + 1) * w / 2 - 4) {
                let i = 3 * (y * w + x); m += SIMD3(Double(img[i]), Double(img[i + 1]), Double(img[i + 2]))
            } }
            means.append(m / Double((h / 2 - 8) * (w / 2 - 8)))
        }
        for m in means { #expect(abs(m.x - means[0].x) < 20 && abs(m.y - means[0].y) < 20 && abs(m.z - means[0].z) < 20, "quadrant means \(means)") }
    }
    #endif
}
