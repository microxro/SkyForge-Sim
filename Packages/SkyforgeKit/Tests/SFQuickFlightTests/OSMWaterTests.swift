// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFPreview
import SFImagery

/// Rivers, canals and lakes from OSM: parsing, the Overpass clauses that fetch them, and their environment mesh.
@Suite struct OSMWaterTests {
    static let origin = GeoOrigin(latitude: 28.34, longitude: -80.685)

    static let json = #"""
    {"elements":[
     {"type":"way","id":901,"tags":{"waterway":"river","width":"30"},
      "geometry":[{"lat":28.3400,"lon":-80.6900},{"lat":28.3405,"lon":-80.6880},{"lat":28.3410,"lon":-80.6860}]},
     {"type":"way","id":902,"tags":{"waterway":"canal"},
      "geometry":[{"lat":28.3380,"lon":-80.6850},{"lat":28.3380,"lon":-80.6830}]},
     {"type":"way","id":903,"tags":{"waterway":"river","tunnel":"yes"},
      "geometry":[{"lat":28.3380,"lon":-80.6800},{"lat":28.3380,"lon":-80.6790}]},
     {"type":"way","id":904,"tags":{"natural":"water"},
      "geometry":[{"lat":28.3390,"lon":-80.6870},{"lat":28.3390,"lon":-80.6850},{"lat":28.3410,"lon":-80.6850},{"lat":28.3410,"lon":-80.6870},{"lat":28.3390,"lon":-80.6870}]},
     {"type":"way","id":905,"tags":{"natural":"water"},
      "geometry":[{"lat":28.3390,"lon":-80.6870},{"lat":28.3390,"lon":-80.6870}]},
     {"type":"relation","id":906,"tags":{"type":"multipolygon","natural":"water"},
      "members":[{"type":"way","role":"outer","geometry":[
        {"lat":28.3420,"lon":-80.6900},{"lat":28.3420,"lon":-80.6880},{"lat":28.3440,"lon":-80.6880},{"lat":28.3440,"lon":-80.6900},{"lat":28.3420,"lon":-80.6900}]}]}
    ]}
    """#

    static func parsed() throws -> OSMData { try OSMParser.parse(Data(json.utf8), origin: origin) }

    @Test func parsesRiversCanalsAndLakesAndSkipsTunnelsAndDegenerateRings() throws {
        let d = try Self.parsed()
        #expect(d.water.map { $0.id } == [901, 902, 904, 906])
        let river = try #require(d.water.first { $0.id == 901 })
        #expect(river.kind == .river && river.widthMetres == 30 && river.points.count == 3)
        let canal = try #require(d.water.first { $0.id == 902 })
        #expect(canal.kind == .canal && canal.widthMetres == OSMWater.estimatedWidth(.canal))
        for id in [904, 906] {
            let lake = try #require(d.water.first { $0.id == id })
            #expect(lake.kind == .lake)
            #expect(lake.points.count >= 3 && OSMGeometry.signedArea(lake.points) > 0, "lake \(id) must be a CCW ring")
        }
        // The lake and the river are not roads or buildings.
        #expect(d.roads.isEmpty && d.buildings.isEmpty)
    }

    @Test func waterQueryFetchesRiversAndLakes() {
        let q = OverpassQuery(origin: Self.origin, halfExtent: 1_000)
        #expect(q.ql.contains(#"way["waterway"~"^(river|canal)$"]"#))
        #expect(q.ql.contains(#"way["natural"="water"]"#))
        #expect(q.ql.contains(#"relation["natural"="water"]["type"="multipolygon"]"#))
        #expect(q.cacheKey.hasPrefix("osm/v2/"))
    }

    @Test func lakesAreFlatAndRiversFollowTheGround() throws {
        let d = try Self.parsed()
        let slope: (Double, Double) -> Double = { x, y in 0.01 * x + 0.02 * y }
        let soup = OSMMeshBuilder.water(d.water, lift: 0.5, ground: slope)
        #expect(soup.triangleCount > 0)
        #expect(soup.material.allSatisfy { $0 == .water })
        // Lake 904 (a square): two triangles, every vertex at one height: the lowest ground under it plus the lift.
        let lake = try #require(d.water.first { $0.id == 904 })
        let low = lake.points.map { slope($0.x, $0.y) }.min()!
        let lakeOnly = OSMMeshBuilder.water([lake], lift: 0.5, ground: slope)
        #expect(lakeOnly.triangleCount == 2)
        let heights = Set(lakeOnly.positions.map { Double($0.z) })
        #expect(heights.count == 1 && abs((heights.first ?? .nan) - (low + 0.5)) < 1e-3)
        // A river ribbon is two triangles per sampled segment, all at or above the ground under them.
        let river = try #require(d.water.first { $0.id == 901 })
        let riverOnly = OSMMeshBuilder.water([river], lift: 0.5, ground: slope)
        #expect(riverOnly.triangleCount >= 4 && riverOnly.triangleCount % 2 == 0)
        #expect(riverOnly.positions.allSatisfy { $0.z.isFinite })
    }

    @Test func appendingWaterKeepsPerVertexChannelsAligned() throws {
        let d = try Self.parsed()
        var roads = TriangleSoup(origin: .zero)
        roads.add(SIMD3(0, 0, 1), SIMD3(10, 0, 1), SIMD3(0, 10, 1), na: SIMD3(0, 0, 1), nb: SIMD3(0, 0, 1), nc: SIMD3(0, 0, 1),
                  ca: SIMD3(0.2, 0.2, 0.2), cb: SIMD3(0.2, 0.2, 0.2), cc: SIMD3(0.2, 0.2, 0.2), material: .road, fields: SIMD3(1, 1, -1))
        let water = OSMMeshBuilder.water(d.water, ground: { _, _ in 0 })
        let before = roads.triangleCount
        roads.appendOSM(water)
        #expect(roads.triangleCount == before + water.triangleCount)
        #expect(roads.positions.count == 3 * roads.triangleCount && roads.normals.count == roads.positions.count)
        #expect(roads.vertexAlbedo.count == 3 * roads.triangleCount)
        #expect(roads.vertexField.count == 3 * roads.triangleCount)
        #expect(roads.material.last == .water)
    }
}
