// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery
import SFPreview

@Suite struct BuildingPackTests {
    /// A two-building pack written the way `tools/fetch_buildings.py` writes it.
    static func pack() -> Data {
        var d = Data("SFB1".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(47.53.bitPattern.littleEndian); put((-122.30).bitPattern.littleEndian); put(UInt32(2).littleEndian)
        // 20 m × 10 m, 12.5 m high, class "commercial" (4), flat roof, surveyed height.
        put(Int32(1_000).littleEndian); put(Int32(2_000).littleEndian); put(UInt16(125).littleEndian); put(UInt16(0).littleEndian)
        d.append(contentsOf: [4, 1, 3, 1, 0, 0, 0, 0, 0, 0]); put(UInt16(4).littleEndian)
        for (dx, dy) in [(200, 0), (0, 100), (-200, 0)] { put(Int16(dx).littleEndian); put(Int16(dy).littleEndian) }
        // 8 m × 8 m house without a height, clockwise ring.
        put(Int32(-5_000).littleEndian); put(Int32(0).littleEndian); put(UInt16(0).littleEndian); put(UInt16(0).littleEndian)
        d.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 200, 180, 160]); put(UInt16(4).littleEndian)
        for (dx, dy) in [(0, 80), (80, 0), (0, -80)] { put(Int16(dx).littleEndian); put(Int16(dy).littleEndian) }
        return d
    }

    @Test func parsesFootprintsHeightsAndKinds() throws {
        let origin = GeoOrigin(latitude: 47.53, longitude: -122.30)
        let b = try BuildingPack.parse(Self.pack(), origin: origin)
        #expect(b.count == 2)
        #expect(b[0].kind == "commercial" && abs(b[0].heightMetres - 12.5) < 1e-9 && b[0].levels == 3)
        #expect(b[0].tags["roof:shape"] == "flat")
        #expect(abs(b[0].area - 200) < 2, "area \(b[0].area)")
        #expect(abs(b[0].footprint[0].x - 100) < 0.5 && abs(b[0].footprint[0].y - 200) < 0.5)
        #expect(b[1].kind == "house" && b[1].heightMetres > 4 && b[1].heightMetres < 9, "estimated height \(b[1].heightMetres)")
        #expect(b[1].area > 0, "clockwise rings are turned counter-clockwise")
        #expect(b[1].wallColour != nil && b[1].roofColour == nil)
    }

    @Test func filterAndCorruptData() throws {
        let origin = GeoOrigin(latitude: 47.53, longitude: -122.30)
        let near = try BuildingPack.parse(Self.pack(), origin: origin) { c, _, _ in c.x > 0 }
        #expect(near.count == 1 && near[0].kind == "commercial")
        #expect(throws: BuildingPack.ParseError.badMagic) { try BuildingPack.parse(Data("nope".utf8) + Data(count: 40), origin: origin) }
        #expect(throws: BuildingPack.ParseError.truncated) { try BuildingPack.parse(Self.pack().prefix(60), origin: origin) }
    }

    @Test func showcasePacksCarryBuildings() throws {
        for a in Showcase.airports {
            let d = try #require(Showcase.buildingData(for: a.ident), "\(a.ident) has no buildings.sfb")
            let origin = GeoOrigin(latitude: 0, longitude: 0)   // only the count matters here
            let n = try BuildingPack.parse(d, origin: origin) { _, _, _ in true }.count
            #expect(n > 3_000, "\(a.ident): \(n) footprints")
        }
    }
}

@Suite struct BuildingMeshTests {
    static let box = OSMBuilding(id: 1, footprint: [SIMD2(0, 0), SIMD2(40, 0), SIMD2(40, 25), SIMD2(0, 25)], heightMetres: 19, kind: "office")
    static let house = OSMBuilding(id: 2, footprint: [SIMD2(100, 0), SIMD2(112, 0), SIMD2(112, 8), SIMD2(100, 8)], heightMetres: 6.5, kind: "house")

    @Test func wallsCarryFacadeCoordinates() {
        let m = BuildingMeshBuilder.build([Self.box], ground: { _, _ in 10 })
        #expect(m.buildingCount == 1 && m.cells.count == 1)
        #expect(m.vertices.count % BuildingMesh.stride == 0 && m.indices.count % 3 == 0)
        #expect(m.indices.allSatisfy { Int($0) < m.vertexCount })
        var walls = 0, roofs = 0, top: Float = 0
        for i in 0..<m.vertexCount {
            let mat = m.material(i)
            if mat == Material.wall.rawValue {
                walls += 1
                let n = m.normal(i)
                #expect(abs(n.z) < 0.02 && abs((n * n).sum().squareRoot() - 1) < 0.02, "walls are vertical")
                // Storeys: 19 m of offices at 3.8 m.
                #expect(m.vertices[i * 32 + 31] == 5 && m.vertices[i * 32 + 29] == BuildingStyle.commercial.rawValue)
            } else { #expect(mat == Material.roof.rawValue); roofs += 1 }
            top = max(top, m.position(i).z)
        }
        #expect(walls == 16 && roofs >= 4)
        #expect(top >= 29 && top < 33, "roof at 29 m plus a parapet and plant, got \(top)")
        // Outward walls: every wall vertex's normal points away from the centroid.
        for i in 0..<m.vertexCount where m.material(i) == Material.wall.rawValue {
            let p = m.position(i), n = m.normal(i)
            #expect((SIMD2(p.x - 20, p.y - 12.5) * SIMD2(n.x, n.y)).sum() > 0)
        }
        #expect(m.cells[0].min.z < 10 && m.cells[0].max.z >= 29)
    }

    @Test func housesGetPitchedRoofs() {
        let m = BuildingMeshBuilder.build([Self.house], ground: { _, _ in 0 })
        var sloped = 0, ridge: Float = 0, eave: Float = 100
        for i in 0..<m.vertexCount where m.material(i) == Material.roof.rawValue {
            let n = m.normal(i)
            if n.z > 0.5 && n.z < 0.98 { sloped += 1 }
            ridge = max(ridge, m.position(i).z); eave = min(eave, m.position(i).z)
        }
        #expect(sloped >= 16, "four sloped roof planes")
        #expect(ridge > eave + 1 && ridge < 9, "ridge \(ridge) above eave \(eave)")
    }

    @Test func insetRejectsOffsetsDeeperThanTheFootprint() {
        let ring = Self.house.footprint
        #expect(BuildingMeshBuilder.inset(ring, by: 2) != nil)
        #expect(BuildingMeshBuilder.inset(ring, by: 4.5) == nil)
        let l = BuildingMeshBuilder.inset(ring, by: 1)!
        #expect(abs(OSMGeometry.signedArea(l) - 10 * 6) < 1e-6)
    }

    @Test func cellsAreContiguousAndDeterministic() {
        var list: [OSMBuilding] = []
        for k in 0..<60 {
            let x = Double(k % 10) * 130, y = Double(k / 10) * 170
            list.append(OSMBuilding(id: Int64(k), footprint: [SIMD2(x, y), SIMD2(x + 14, y), SIMD2(x + 14, y + 9), SIMD2(x, y + 9)],
                                    heightMetres: 5 + Double(k % 7) * 9, kind: k % 3 == 0 ? "house" : "yes"))
        }
        let a = BuildingMeshBuilder.build(list, ground: { x, _ in x * 0.01 }), b = BuildingMeshBuilder.build(list.reversed(), ground: { x, _ in x * 0.01 })
        #expect(a.buildingCount == 60 && a.cells.count > 3)
        var next = 0
        for c in a.cells { #expect(c.indexStart == next); next += c.indexCount }
        #expect(next == a.indices.count)
        #expect(a.vertices == b.vertices && a.indices == b.indices, "independent of the input order")
        for c in a.cells {
            for k in c.indexStart..<(c.indexStart + c.indexCount) {
                let p = a.position(Int(a.indices[k]))
                #expect(p.x >= c.min.x - 1e-3 && p.x <= c.max.x + 1e-3 && p.z >= c.min.z - 1e-3 && p.z <= c.max.z + 1e-3)
            }
        }
    }

    /// Boeing Field from the bundled pack: real footprints stand in for the procedural fallback.
    @Test func showcaseRegionUsesBundledFootprints() async throws {
        let ident = "KBFI"
        let p = RealWorldDetail.phone
        var d = RealWorldDetail(nearHalf: 1_200, nearStep: 40, midHalf: 3_000, midStep: 200, farHalf: 8_000, farStep: 1_000,
                                imageryNearSize: Int(Double(p.imageryNearSize) * 1_200 / p.nearHalf),
                                imageryFarSize: Int(Double(p.imageryFarSize) * 8_000 / p.farHalf), treeRadius: 300, maxTrees: 1_000)
        d.buildingRadius = 1_800; d.buildingFullRadius = 1_200
        let region = try await RealWorldRegion.load(airport: ident, detail: d, transport: Showcase.transport(for: ident, fallback: nil), cache: nil)
        #expect(region.buildings.count > 400, "\(region.buildings.count) footprints near Boeing Field")
        #expect(region.fallbackBuildings.isEmpty)
        #expect(region.attribution.contains(OSMData.attribution))
        for b in region.buildings {
            let c = OSMGeometry.centroid(b.footprint)
            let r = (c * c).sum().squareRoot()
            // (The filter uses the vertex mean, this the area centroid: a few metres apart on long footprints.)
            #expect(r < 1_300 || (r < 1_900 && (b.heightMetres >= 14 || b.area >= 550)))
        }
        let mesh = try #require(region.buildingMesh())
        #expect(mesh.buildingCount > 400 && mesh.triangleCount > 10_000)
    }
}
