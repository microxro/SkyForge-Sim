import Testing
import Foundation
@testable import SFTerrainCore

@Suite struct TerrainCoreTests {
    static var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/terrarium")
    }

    @Test func inflateRoundTripStoredBlocks() throws {
        // A zlib stream with stored blocks (as written by our own PNG encoder) decodes exactly.
        let payload: [UInt8] = (0..<70_000).map { UInt8(($0 * 31) & 0xFF) }
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65_535, payload.count - i)
            z.append(i + n >= payload.count ? 1 : 0)
            z += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            z += payload[i..<(i + n)]
            i += n
        } while i < payload.count
        let a = Inflate.adler32(payload)
        z += [UInt8(a >> 24), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)]
        #expect(try Inflate.zlib(z) == payload)
    }

    @Test func inflateFixedHuffman() throws {
        // zlib.compress(b"hello hello hello hello", 9) from CPython: fixed-Huffman block with back-references.
        let z: [UInt8] = [0x78, 0xDA, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0xC8, 0x40, 0x27, 0x01, 0x68, 0x03, 0x08, 0xB1]
        #expect(String(decoding: try Inflate.zlib(z), as: UTF8.self) == "hello hello hello hello")
    }

    @Test func corruptStreamThrows() {
        #expect(throws: (any Error).self) { try Inflate.zlib([0x78, 0xDA, 0xFF, 0xFF, 0xFF, 0x00]) }
    }

    @Test func terrariumRainierFixture() throws {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("rainier_10_165_360.png"))
        let grid = try Terrarium.decode(png: [UInt8](data))
        #expect(grid.width == 256 && grid.height == 256)
        let mm = grid.minMax
        // Reference values computed independently with Python zlib: max 4370 m at (167,199), min 438 m.
        #expect(mm.max == 4370)
        #expect(mm.min == 438)
        #expect(grid[167, 199] == 4370)
        // Summit location falls inside the tile near the true summit coordinates.
        let t = TileCoord(z: 10, x: 165, y: 360)
        let c = t.coordinate(u: (167 + 0.5) / 256, v: (199 + 0.5) / 256)
        #expect(abs(c.latitude - 46.853) < 0.01 && abs(c.longitude - (-121.760)) < 0.01)
    }

    @Test func tileMathRoundTrip() {
        let t = TileCoord.containing(latitude: 46.8529, longitude: -121.7604, zoom: 10)
        #expect(t == TileCoord(z: 10, x: 165, y: 360))
        let f = t.fraction(latitude: 46.8529, longitude: -121.7604)
        #expect(f.u >= 0 && f.u < 1 && f.v >= 0 && f.v < 1)
        let back = t.coordinate(u: f.u, v: f.v)
        #expect(abs(back.latitude - 46.8529) < 1e-9 && abs(back.longitude + 121.7604) < 1e-9)
    }

    @Test func bilinearSample() {
        let g = HeightGrid(width: 2, height: 2, samples: [0, 10, 20, 30])
        #expect(abs(g.sample(px: 1.0, py: 1.0) - 15) < 1e-9)
        #expect(abs(g.sample(px: 0.5, py: 0.5) - 0) < 1e-9)
    }

    func selection(camera: SIMD3<Double>) -> (CDLODQuadtree, [CDLODNode]) {
        let tree = CDLODQuadtree(rootMinX: -51_200, rootMinY: -51_200, rootSize: 102_400,
                                 settings: CDLODSettings(levels: 9, finestRange: 300))
        return (tree, tree.select(camera: camera, bounds: ConstantBounds(low: 0, high: 500)))
    }

    @Test func cdlodTilesDomainExactly() {
        let (tree, nodes) = selection(camera: SIMD3(1_234, -2_345, 600))
        let area = nodes.reduce(0.0) { $0 + $1.size * $1.size }
        #expect(abs(area - tree.rootSize * tree.rootSize) < 1e-3)
        // No overlaps: sort and check pairwise for small sets of neighbours.
        for (i, a) in nodes.enumerated() {
            for b in nodes[(i + 1)...] {
                let ox = min(a.minX + a.size, b.minX + b.size) - max(a.minX, b.minX)
                let oy = min(a.minY + a.size, b.minY + b.size) - max(a.minY, b.minY)
                #expect(!(ox > 1e-6 && oy > 1e-6))
            }
        }
    }

    @Test func cdlodFinestNearCameraAndNeighboursDifferByOne() {
        let cam = SIMD3<Double>(100, 100, 300)
        let (_, nodes) = selection(camera: cam)
        let under = nodes.first { cam.x >= $0.minX && cam.x < $0.minX + $0.size && cam.y >= $0.minY && cam.y < $0.minY + $0.size }
        #expect(under?.lod == 0)
        for (i, a) in nodes.enumerated() {
            for b in nodes[(i + 1)...] {
                let touchX = abs(a.minX + a.size - b.minX) < 1e-6 || abs(b.minX + b.size - a.minX) < 1e-6
                let touchY = abs(a.minY + a.size - b.minY) < 1e-6 || abs(b.minY + b.size - a.minY) < 1e-6
                let overlapX = min(a.minX + a.size, b.minX + b.size) - max(a.minX, b.minX) > 1e-6
                let overlapY = min(a.minY + a.size, b.minY + b.size) - max(a.minY, b.minY) > 1e-6
                if (touchX && overlapY) || (touchY && overlapX) {
                    #expect(abs(a.lod - b.lod) <= 1, "neighbours lod \(a.lod) vs \(b.lod)")
                }
            }
        }
    }

    @Test func morphFactorRange() {
        let n = CDLODNode(minX: 0, minY: 0, size: 100, lod: 1, morphStart: 420, morphEnd: 600)
        #expect(cdlodMorph(distance: 100, node: n) == 0)
        #expect(cdlodMorph(distance: 700, node: n) == 1)
        #expect(abs(cdlodMorph(distance: 510, node: n) - 0.5) < 1e-9)
    }
}

import SFContent

@Suite struct GlobalDEMTests {
    @Test func bundledDEMIntegrityAndReferencePoints() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SFTerrainCore/Resources")
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("global_dem.json"))) as? [String: Any]
        let bytes = try Data(contentsOf: url.appendingPathComponent("global_dem.sfdem"))
        #expect(ContentID(data: bytes).hex == meta?["sha256"] as? String)
        #expect(bytes.count < 25_000_000)
        let dem = try GlobalDEM.bundled()
        #expect(dem.width == 4096 && dem.height == 2048)
        #expect(dem.elevation(latitude: 27.99, longitude: 86.93) > 4_500)    // Himalaya (10 km average)
        #expect(dem.elevation(latitude: 31.5, longitude: 35.5) < -200)       // Dead Sea basin
        #expect(dem.elevation(latitude: 0, longitude: -150) < -2_000)        // Pacific
        let denver = dem.elevation(latitude: 39.74, longitude: -104.99)
        #expect(denver > 1_400 && denver < 1_900)
        #expect(dem.elevation(latitude: 89.9, longitude: 0).isFinite && dem.elevation(latitude: -89.9, longitude: 179.99).isFinite)
    }

    @Test func corruptHeaderRejected() {
        #expect(throws: GlobalDEMError.badHeader) { try GlobalDEM(data: Data("NOTADEM".utf8)) }
    }
}
