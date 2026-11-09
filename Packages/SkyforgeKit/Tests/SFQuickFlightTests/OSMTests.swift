// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFMath
import SFImagery
import SFContent
import SFPreview

/// Scripted Overpass transport: never touches the network.
actor ScriptedOSMTransport: HTTPTransport {
    var responses: [Result<Data, TransportError>]
    private(set) var requests: [URL] = []
    init(_ r: [Result<Data, TransportError>]) { responses = r }
    func get(_ url: URL) async throws -> Data {
        requests.append(url)
        guard !responses.isEmpty else { throw TransportError.offline }
        return try responses.removeFirst().get()
    }
}

@Suite struct OSMTests {
    /// The fixture was laid out in metres around this origin (Merritt Island, FL).
    static let origin = GeoOrigin(latitude: 28.34, longitude: -80.685)

    static func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/osm/overpass_sample.json"))
    }
    static func parsed() throws -> OSMData { try OSMParser.parse(try fixture(), origin: origin) }
    static func building(_ d: OSMData, _ id: Int64) throws -> OSMBuilding { try #require(d.buildings.first { $0.id == id }) }
    static func road(_ d: OSMData, _ id: Int64) throws -> OSMRoad { try #require(d.roads.first { $0.id == id }) }
    static func tempCache() throws -> KeyedCache {
        try KeyedCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("sfosm-\(UUID().uuidString)"))
    }

    // MARK: parsing

    @Test func parsesBuildingsAndSkipsDegenerateOnes() throws {
        let d = try Self.parsed()
        // 1005 (2.25 m² shed) and 1007 (two distinct points) are degenerate, 1009 is an outline
        // replaced by its building:part 1010, 1011 is building=no and 1012 is landuse.
        #expect(Set(d.buildings.map(\.id)) == [1001, 1002, 1003, 1004, 1006, 1008, 1010])
        #expect(try Self.building(d, 1010).isPart)
        #expect(try !Self.building(d, 1001).isPart)
    }

    @Test func heightRules() throws {
        let d = try Self.parsed()
        #expect(try Self.building(d, 1001).heightMetres == 6.5)             // house default
        #expect(try Self.building(d, 1002).heightMetres == 24)              // height wins over levels
        #expect(try Self.building(d, 1002).levels == 7)
        #expect(try Self.building(d, 1003).heightMetres == 10)              // 3 levels × 3 + 1
        #expect(try Self.building(d, 1003).levels == 3)
        #expect(try Self.building(d, 1004).heightMetres == 9)               // warehouse default
        #expect(try abs(Self.building(d, 1006).heightMetres - 12.192) < 1e-9) // "40 ft"
        #expect(try Self.building(d, 1008).heightMetres == 7)               // building=yes default
        let part = try Self.building(d, 1010)
        #expect(part.heightMetres == 45 && part.minHeightMetres == 5)
        let defaults: [(String, Double)] = [("house", 6.5), ("residential", 12), ("apartments", 12), ("commercial", 8), ("retail", 8),
                                            ("industrial", 9), ("warehouse", 9), ("hangar", 12), ("yes", 7), ("church", 7)]
        for (kind, h) in defaults { #expect(OSMParser.defaultHeight(kind: kind) == h, "\(kind)") }
        #expect(OSMParser.height(tags: ["building:levels": "2"], kind: "house") == 7)
        #expect(OSMParser.height(tags: ["height": "bogus", "building:levels": "4"], kind: "yes") == 13)
    }

    @Test func footprintsAreLocalCounterClockwiseOpenRings() throws {
        let d = try Self.parsed()
        for b in d.buildings {
            #expect(b.area > 0, "building \(b.id) must be counter-clockwise")
            #expect(b.footprint.first != b.footprint.last)
            #expect(b.footprint.count >= 4)
        }
        let house = try Self.building(d, 1001)
        #expect(house.footprint.count == 4)
        #expect(dist2(house.footprint[0], SIMD2(-100, 50)) < 0.05)
        #expect(abs(house.area - 80) < 0.5)
        #expect(abs(try Self.building(d, 1002).area - 300) < 1)    // clockwise in the source, reversed
        #expect(abs(try Self.building(d, 1003).area - 450) < 1)    // concave L, counter-clockwise
        #expect(abs(try Self.building(d, 1004).area - 450) < 1)    // concave L, clockwise in the source
    }

    @Test func tagsColoursAndMaterials() throws {
        let d = try Self.parsed()
        let house = try Self.building(d, 1001)
        #expect(house.kind == "house" && house.roofMaterial == "roof_tiles" && house.roofColour == nil)
        #expect(house.tags["building"] == "house" && house.tags["addr:street"] == nil)
        let apt = try Self.building(d, 1002)
        #expect(apt.tags["name"] == "Harbour View" && apt.tags["height"] == "24 m")
        let grey = try #require(apt.roofColour)
        #expect(abs(grey.x - grey.y) < 1e-6 && abs(grey.y - grey.z) < 1e-6)
        let shop = try Self.building(d, 1003)
        #expect(shop.roofColour != nil && shop.wallColour != nil)
        #expect(OSMParser.parseColour("#f00") != nil && OSMParser.parseColour("#334455") != nil)
        #expect(OSMParser.parseColour("not-a-colour") == nil && OSMParser.parseColour("#12") == nil)
        #expect(OSMMeshBuilder.roofColour(for: house) == OSMMeshBuilder.roofTerracotta)
    }

    @Test func roadsClassesAndWidths() throws {
        let d = try Self.parsed()
        #expect(Set(d.roads.map(\.id)) == [2001, 2002, 2003, 2004, 2005, 2007, 2008])   // footway 2006 skipped
        let motorway = try Self.road(d, 2001)
        #expect(motorway.highway == .motorway && motorway.lanes == 3 && motorway.points.count == 4)
        #expect(abs(motorway.widthMetres - (3 * 3.6 + 3)) < 1e-9)
        #expect(motorway.tags["ref"] == "I 95")
        #expect(abs(try Self.road(d, 2002).widthMetres - 8) < 1e-9)       // primary: 2 × 3.5 + 1
        #expect(abs(try Self.road(d, 2003).widthMetres - 5.5) < 1e-9)     // residential: 2 × 2.75
        #expect(abs(try Self.road(d, 2004).widthMetres - 3) < 1e-9)       // service: 1 × 3
        let track = try Self.road(d, 2005)
        #expect(track.highway == .track && track.isUnpaved && abs(track.widthMetres - 2.5) < 1e-9)
        #expect(try Self.road(d, 2007).widthMetres == 7.5)                // explicit width
        let link = try Self.road(d, 2008)
        #expect(link.highway == .motorwayLink && link.highway.isLink && abs(link.widthMetres - 5.1) < 1e-9)
        #expect(dist2(motorway.points[0], SIMD2(-500, -200)) < 0.05)
    }

    @Test func unitParsing() {
        func near(_ s: String, _ v: Double) -> Bool { OSMParser.parseLength(s).map { abs($0 - v) < 1e-9 } ?? false }
        #expect(near("12 m", 12))
        #expect(near("12m", 12))
        #expect(near("12.5", 12.5))
        #expect(near("12,5", 12.5))
        #expect(near(" 7 metres ", 7))
        #expect(near("40 ft", 12.192))
        #expect(near("40ft", 12.192))
        #expect(near("40'", 12.192))
        #expect(near("6'6\"", 1.9812))
        #expect(near("1.2 km", 1200))
        #expect(near("15;20", 15))
        #expect(OSMParser.parseLength("tall") == nil)
        #expect(OSMParser.parseLength("") == nil)
        #expect(OSMParser.parseLength("12 parsecs") == nil)
        #expect(OSMParser.parseNumber("3") == 3 && OSMParser.parseNumber("2,5") == 2.5 && OSMParser.parseNumber("x") == nil)
    }

    @Test func invalidJSONThrows() {
        #expect(throws: OSMParser.ParseError.self) { try OSMParser.parse(Data("<html>rate limited</html>".utf8), origin: Self.origin) }
        #expect(throws: Never.self) { _ = try OSMParser.parse(Data(#"{"elements":[]}"#.utf8), origin: Self.origin) }
    }

    // MARK: ear clipping

    static func checkTriangulation(_ poly: [SIMD2<Double>], _ label: String) {
        let tris = OSMGeometry.triangulate(poly)
        let area = abs(OSMGeometry.signedArea(poly))
        var sum = 0.0
        for t in tris {
            let a = poly[t.x], b = poly[t.y], c = poly[t.z]
            let ta = OSMGeometry.signedArea([a, b, c])
            #expect(ta > 0, "\(label): triangle \(t) must be counter-clockwise")
            sum += ta
            // No part of a triangle lies outside: its centroid and (nudged) edge midpoints are inside.
            let g = (a + b + c) / 3
            #expect(OSMGeometry.contains(poly, g), "\(label): triangle \(t) centroid outside")
            for m in [(a + b) / 2, (b + c) / 2, (c + a) / 2] {
                #expect(OSMGeometry.contains(poly, m * 0.98 + g * 0.02), "\(label): triangle \(t) edge outside")
            }
        }
        #expect(abs(sum - area) < 1e-6 * max(1, area), "\(label): \(sum) vs \(area)")
    }

    @Test func earClippingConvexPolygons() {
        let square: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        Self.checkTriangulation(square, "square")
        #expect(OSMGeometry.triangulate(square).count == 2)
        let hexagon = (0..<6).map { k in SIMD2(cos(Double(k) * .pi / 3), sin(Double(k) * .pi / 3)) * 20 }
        Self.checkTriangulation(hexagon, "hexagon")
        Self.checkTriangulation(hexagon.reversed(), "hexagon cw")
        #expect(OSMGeometry.triangulate(hexagon).count == 4)
        // Collinear midpoints and a repeated closing point are tolerated.
        let withMidpoints: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(5, 0), SIMD2(10, 0), SIMD2(10, 5), SIMD2(10, 10), SIMD2(0, 10), SIMD2(0, 0)]
        Self.checkTriangulation(Array(withMidpoints.dropLast()), "collinear")
        #expect(abs(OSMGeometry.triangulate(withMidpoints).map { t in
            OSMGeometry.signedArea([withMidpoints[t.x], withMidpoints[t.y], withMidpoints[t.z]]) }.reduce(0, +) - 100) < 1e-9)
    }

    @Test func earClippingConcavePolygons() {
        let l: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 10), SIMD2(10, 10), SIMD2(10, 25), SIMD2(0, 25)]
        Self.checkTriangulation(l, "L")
        Self.checkTriangulation(l.reversed(), "L cw")
        #expect(OSMGeometry.triangulate(l).count == 4)
        let u: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 20), SIMD2(20, 20), SIMD2(20, 8), SIMD2(10, 8), SIMD2(10, 20), SIMD2(0, 20)]
        Self.checkTriangulation(u, "U")
        Self.checkTriangulation(u.reversed(), "U cw")
        // A comb: many reflex vertices in a row.
        var comb: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(50, 0)]
        for k in stride(from: 4, through: 0, by: -1) {
            let x = Double(k) * 10
            comb += [SIMD2(x + 10, 20), SIMD2(x + 6, 20), SIMD2(x + 6, 5), SIMD2(x + 4, 5), SIMD2(x + 4, 20), SIMD2(x, 20)]
        }
        comb = comb.reduce(into: []) { acc, p in if acc.last != p { acc.append(p) } }
        Self.checkTriangulation(comb, "comb")
        Self.checkTriangulation(comb.reversed(), "comb cw")
        // Four vertices along the tooth tips are collinear and are dropped without a triangle.
        #expect(OSMGeometry.triangulate(comb).count == comb.count - 2 - 4)
        // Random star-shaped (hence simple) polygons with deep notches.
        var rng = Xoshiro256(seed: 0x05E)
        for i in 0..<40 {
            let n = 8 + Int(rng.next() % 50)
            let star = (0..<n).map { k -> SIMD2<Double> in
                let a = Double(k) / Double(n) * 2 * .pi
                return SIMD2(cos(a), sin(a)) * rng.range(5, 60) + SIMD2(1_000, -2_000)
            }
            Self.checkTriangulation(star, "star \(i)")
            Self.checkTriangulation(star.reversed(), "star \(i) cw")
            #expect(OSMGeometry.triangulate(star).count == n - 2)
        }
    }

    // MARK: meshes

    @Test func wallNormalsFaceOutward() throws {
        var buildings = try Self.parsed().buildings
        // A clockwise L handed straight to the mesh builder (bypassing the parser's normalisation).
        let ccwL: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 10), SIMD2(10, 10), SIMD2(10, 25), SIMD2(0, 25)]
        let cwL: [SIMD2<Double>] = ccwL.reversed().map { $0 + SIMD2<Double>(500, 500) }
        buildings.append(OSMBuilding(id: 1, footprint: cwL, heightMetres: 8))
        let soup = OSMMeshBuilder.buildings(buildings) { _, _ in 3 }
        let rings = buildings.map(\.footprint)
        var walls = 0, roofs = 0, undersides = 0, slopes = 0
        let hipped = buildings.filter { b in
            var r = b.footprint; if OSMGeometry.signedArea(r) < 0 { r.reverse() }
            return b.minHeightMetres <= 0 && OSMMeshBuilder.hippedRoof(b, ring: r) != nil
        }
        for t in 0..<soup.triangleCount {
            let a = soup.positions[3 * t], b = soup.positions[3 * t + 1], c = soup.positions[3 * t + 2]
            let n = soup.normals[3 * t]
            #expect(dist3(n, faceNormal(a, b, c)) < 1e-4, "stored normal follows the winding")
            #expect(soup.material[t] == .opaque)
            let g = (a + b + c) / 3
            let gxy = SIMD2(Double(g.x), Double(g.y))
            if abs(n.z) < 1e-3 {
                walls += 1
                let nxy = SIMD2(Double(n.x), Double(n.y))
                #expect(!rings.contains { OSMGeometry.contains($0, gxy + nxy * 0.05) }, "wall \(t) normal points inside")
                #expect(rings.contains { OSMGeometry.contains($0, gxy - nxy * 0.05) }, "wall \(t) has no building behind it")
            } else if n.z > 0.999 {
                roofs += 1
                #expect(rings.contains { OSMGeometry.contains($0, gxy) })
            } else if n.z < -0.999 {
                undersides += 1
            } else if n.z > 0.5 && hipped.contains(where: { OSMGeometry.contains($0.footprint, gxy) }) {
                slopes += 1                          // hipped-roof slope, facing up and outward
            } else {
                Issue.record("unexpected sloped triangle \(n)")
            }
        }
        // Ground-standing walls carry a darker contact band below the main wall (4 triangles per edge);
        // floating parts (min_height) keep 2.
        let expectedWalls = buildings.map { $0.footprint.count * ($0.minHeightMetres > 0 ? 2 : 4) }.reduce(0, +)
        #expect(walls == expectedWalls, "\(walls) vs \(expectedWalls)")
        #expect(!hipped.isEmpty && slopes <= 6 * hipped.count && slopes >= 4 * hipped.count, "slopes \(slopes)")
        #expect(roofs == rings.map { $0.count - 2 }.reduce(0, +) - 2 * hipped.count)
        #expect(undersides == 2)   // only the floating part 1010 (a rectangle)
    }

    @Test func smallHousesGetHippedRoofs() {
        let rect: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(12, 0), SIMD2(12, 8), SIMD2(0, 8)]
        let house = OSMBuilding(id: 1, footprint: rect, heightMetres: 6, kind: "house")
        let hip = OSMMeshBuilder.hippedRoof(house, ring: rect)
        #expect(hip?.first == 0 && hip?.short == 8)
        // Ridge on the long axis, inset half the short side (4 m) from each end.
        #expect(hip.map { simdLength($0.ridgeA - SIMD2(4, 4)) < 1e-9 && simdLength($0.ridgeB - SIMD2(8, 4)) < 1e-9 } == true)
        let soup = OSMMeshBuilder.buildings([house], foundation: 0) { _, _ in 10 }
        let ridge = 16 + 4 * tan(30 * Double.pi / 180)
        #expect(abs(Double(soup.positions.map(\.z).max()!) - ridge) < 1e-3)
        #expect(soup.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        // A square house gets a pyramid (no degenerate ridge triangles).
        let sq = OSMMeshBuilder.buildings([OSMBuilding(id: 2, footprint: [SIMD2(0, 0), SIMD2(9, 0), SIMD2(9, 9), SIMD2(0, 9)], heightMetres: 5, kind: "house")]) { _, _ in 0 }
        #expect(sq.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        #expect(sq.triangleCount == 16 + 4)   // walls with contact band + pyramid
        // Long axis on edges 1/3 (first == 1) indexes every edge modulo 4.
        let tall: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(8, 0), SIMD2(8, 12), SIMD2(0, 12)]
        let hip2 = OSMMeshBuilder.hippedRoof(OSMBuilding(id: 7, footprint: tall, heightMetres: 6, kind: "house"), ring: tall)
        #expect(hip2?.first == 1 && hip2?.short == 8)
        // Flat-tagged, large, non-house and L-shaped buildings keep flat roofs.
        #expect(OSMMeshBuilder.hippedRoof(OSMBuilding(id: 3, footprint: rect, heightMetres: 6, kind: "house", tags: ["roof:shape": "flat"]), ring: rect) == nil)
        let big = rect.map { $0 * 3 }
        #expect(OSMMeshBuilder.hippedRoof(OSMBuilding(id: 4, footprint: big, heightMetres: 6, kind: "house"), ring: big) == nil)
        #expect(OSMMeshBuilder.hippedRoof(OSMBuilding(id: 5, footprint: rect, heightMetres: 6, kind: "industrial"), ring: rect) == nil)
        #expect(OSMMeshBuilder.hippedRoof(OSMBuilding(id: 6, footprint: rect, heightMetres: 6, kind: "commercial", tags: ["roof:shape": "gabled"]), ring: rect) != nil)
    }

    @Test func buildingSitsOnMinimumGroundHeight() throws {
        let ground: (Double, Double) -> Double = { x, y in 50 + 0.2 * x + 0.1 * y }
        let b = try Self.building(try Self.parsed(), 1003)   // the concave L
        let lowest = b.footprint.map { ground($0.x, $0.y) }.min()!
        #expect(abs(OSMMeshBuilder.baseHeight(b.footprint, ground: ground) - lowest) < 1e-9)

        let flush = OSMMeshBuilder.buildings([b], foundation: 0, ground: ground)
        let zs = flush.positions.map { Double($0.z) }
        #expect(abs(zs.min()! - lowest) < 1e-3)
        #expect(abs(zs.max()! - (lowest + b.heightMetres)) < 1e-3)

        let sunk = OSMMeshBuilder.buildings([b], ground: ground)
        #expect(abs(Double(sunk.positions.map(\.z).min()!) - (lowest - 1)) < 1e-3)
        // A dip in the middle of the footprint lowers the base too.
        let square: [SIMD2<Double>] = [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]
        #expect(OSMMeshBuilder.baseHeight(square) { x, y in x * x + y * y < 4 ? 40 : 50 } == 40)
    }

    @Test func coloursAreDeterministicAndVaried() throws {
        let d = try Self.parsed()
        let once = OSMMeshBuilder.buildings(d.buildings) { _, _ in 0 }
        let twice = OSMMeshBuilder.buildings(d.buildings) { _, _ in 0 }
        #expect(once.albedo == twice.albedo && once.positions == twice.positions)
        let walls = (0..<200).map { i in
            OSMMeshBuilder.wallColour(for: OSMBuilding(id: Int64(i), footprint: [SIMD2(Double(i) * 37, 11), SIMD2(Double(i) * 37 + 9, 11),
                                                                              SIMD2(Double(i) * 37 + 9, 20)], heightMetres: 7))
        }
        #expect(Set(walls.map { SIMD3<Int>(Int($0.x * 1000), Int($0.y * 1000), Int($0.z * 1000)) }).count > 5)
        #expect(walls.allSatisfy { $0.max() < 0.75 && $0.min() > 0.1 })   // muted: no pure whites or blacks
    }

    @Test func roadRibbonsDrapeOverGround() throws {
        let d = try Self.parsed()
        let ground: (Double, Double) -> Double = { x, y in 10 + 0.05 * x - 0.02 * y }
        let soup = OSMMeshBuilder.roads(d.roads, lift: 0.3, maxSegment: 20, ground: ground)
        #expect(soup.triangleCount > 0)
        #expect(soup.material.allSatisfy { $0 == .road })
        for t in 0..<soup.triangleCount {
            #expect(soup.normals[3 * t].z > 0.99, "road faces up")
            for k in 0..<3 {
                let p = soup.positions[3 * t + k]
                #expect(abs(Double(p.z) - (ground(Double(p.x), Double(p.y)) + 0.3)) < 1e-3)
            }
        }
        // A straight road: 150 m at ≤ 20 m per quad → 8 quads, 7.5 m wide.
        let straight = try Self.road(d, 2007)
        let s = OSMMeshBuilder.roads([straight]) { _, _ in 0 }
        #expect(s.triangleCount == 16)
        let xs = s.positions.map(\.x)
        #expect(abs(Double(xs.max()! - xs.min()!) - 7.5) < 0.05)
        var tunnel = straight
        tunnel.tags["tunnel"] = "yes"
        #expect(OSMMeshBuilder.roads([tunnel]) { _, _ in 0 }.triangleCount == 0)
    }

    // MARK: service and query

    @Test func serviceCachesThenServesOffline() async throws {
        let cache = try Self.tempCache()
        let body = try Self.fixture()
        let online = ScriptedOSMTransport([.success(body)])
        let first = await OSMService(transport: online, cache: cache).data(around: Self.origin, halfExtent: 500)
        let data = try #require(first)
        #expect(data == (try Self.parsed()))
        let requests = await online.requests
        #expect(requests.count == 1 && requests.first?.host == "overpass-api.de")
        let key = OverpassQuery(origin: Self.origin, halfExtent: 500).cacheKey
        #expect(key.hasPrefix("osm/"))
        #expect(await cache.get(key) == body)

        // A new session in airplane mode reads the content store without touching the transport.
        let offline = ScriptedOSMTransport([])
        let svc = OSMService(transport: offline, cache: cache)
        #expect(await svc.data(around: Self.origin, halfExtent: 500) == data)
        #expect(await svc.lastSource == .disk)
        #expect(await offline.requests.isEmpty)
        // A forced refresh that fails falls back to the cache.
        #expect(await svc.data(around: Self.origin, halfExtent: 500, refresh: true) == data)
        #expect(await svc.networkRequests == 1)
    }

    @Test func serviceReturnsNilOfflineWithNothingCached() async throws {
        #expect(await OSMService(transport: ScriptedOSMTransport([]), cache: nil).data(around: Self.origin, halfExtent: 500) == nil)
        let cache = try Self.tempCache()
        let svc = OSMService(transport: ScriptedOSMTransport([.failure(.status(429)), .success(Data("<html>busy</html>".utf8))]), cache: cache)
        #expect(await svc.data(around: Self.origin, halfExtent: 500) == nil)       // rate limited
        #expect(await svc.data(around: Self.origin, halfExtent: 500) == nil)       // HTML error page is not JSON
        #expect(await cache.get(OverpassQuery(origin: Self.origin, halfExtent: 500).cacheKey) == nil)
    }

    @Test func partialResponsesAreNotCached() async throws {
        let cache = try Self.tempCache()
        let partial = Data(#"{"remark":"runtime error: Query timed out in \"query\" at line 3 after 61 seconds.","elements":[]}"#.utf8)
        let svc = OSMService(transport: ScriptedOSMTransport([.success(partial)]), cache: cache)
        #expect(await svc.data(around: Self.origin, halfExtent: 500) == OSMData())
        #expect(await cache.get(OverpassQuery(origin: Self.origin, halfExtent: 500).cacheKey) == nil)
    }

    @Test func queryURLIsWellFormed() throws {
        let q = OverpassQuery(origin: Self.origin, halfExtent: 1_000)
        #expect(q.cacheKey == "osm/28.330,-80.696,28.350,-80.674")
        #expect(q.south < 28.34 && q.north > 28.34 && q.west < -80.685 && q.east > -80.685)
        #expect(q.ql.hasPrefix("[out:json][timeout:60];"))
        #expect(q.ql.hasSuffix("out geom;"))
        #expect(q.ql.contains(#"way["building"](28.330,-80.696,28.350,-80.674);"#))
        #expect(q.ql.contains(#"way["building:part"]"#))
        #expect(q.ql.contains("motorway|") && q.ql.contains("|residential|") && q.ql.contains("|track"))
        let url = q.url
        #expect(url.scheme == "https" && url.host == "overpass-api.de" && url.path == "/api/interpreter")
        let s = url.absoluteString
        #expect(s.hasPrefix("https://overpass-api.de/api/interpreter?data="))
        #expect(!s.contains(" ") && !s.contains("\"") && !s.contains("[") && !s.contains("\n") && !s.contains(";"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.count == 1 && items[0].name == "data" && items[0].value == q.ql)
        #expect(OSMData.attribution == "Buildings and roads: © OpenStreetMap contributors, ODbL 1.0")
    }
}

private func dist2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { ((a - b) * (a - b)).sum().squareRoot() }
private func dist3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { ((a - b) * (a - b)).sum().squareRoot() }
private func faceNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
    let u = b - a, v = c - a
    let n = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
    return n / (n * n).sum().squareRoot()
}

@Suite struct OSMRegionIntegrationTests {
    /// Region + OSM fixture: the mesh merges roads and buildings, trees avoid footprints, attribution holds.
    @Test func regionMeshesOSMAndTreesAvoidBuildings() async throws {
        let a = Showcase.defaultAirport
        let p = RealWorldDetail.phone
        let d = RealWorldDetail(nearHalf: 600, nearStep: 40, midHalf: 2_000, midStep: 200, farHalf: 8_000, farStep: 1_000,
                                imageryNearSize: Int(Double(p.imageryNearSize) * 600 / p.nearHalf),
                                imageryFarSize: Int(Double(p.imageryFarSize) * 8_000 / p.farHalf), treeRadius: 600, maxTrees: 50_000)
        var region = try await RealWorldRegion.load(airport: a.ident, detail: d, transport: Showcase.transport(for: a.ident, fallback: nil), cache: nil)
        #expect(region.osm == nil, "offline and uncached: no OSM")
        #expect(region.buildings == region.fallbackBuildings, "procedural fallback stands in for OSM")
        region.fallbackBuildings = []
        // A large building over the field centre must clear the trees there.
        let square = [SIMD2<Double>(-300, -300), SIMD2(300, -300), SIMD2(300, 300), SIMD2(-300, 300)]
        let before = region.trees().filter { abs(Double($0.position.x)) < 300 && abs(Double($0.position.y)) < 300 }.count
        region.osm = OSMData(buildings: [OSMBuilding(id: 1, footprint: square, heightMetres: 10, minHeightMetres: 0, levels: nil, kind: "yes",
                                                     isPart: false, roofColour: nil, roofMaterial: nil, wallColour: nil, tags: [:])], roads: [])
        let after = region.trees().filter { abs(Double($0.position.x)) < 300 && abs(Double($0.position.y)) < 300 }.count
        #expect(after == 0, "no trees inside the footprint (had \(before))")
        let mesh = try #require(region.osmMesh())
        #expect(mesh.triangleCount >= 10, "walls and roof")
    }
}


@Suite struct ProceduralFallbackTests {
    /// Boeing Field (city): built-up imagery grows fallback buildings, never on the runway/apron or water.
    @Test func cityAirportGrowsFallbackBuildingsOffTheAirfield() async throws {
        let ident = "KBFI"
        let p = RealWorldDetail.phone
        let d = RealWorldDetail(nearHalf: 1_200, nearStep: 40, midHalf: 3_000, midStep: 200, farHalf: 8_000, farStep: 1_000,
                                imageryNearSize: Int(Double(p.imageryNearSize) * 1_200 / p.nearHalf),
                                imageryFarSize: Int(Double(p.imageryFarSize) * 8_000 / p.farHalf), treeRadius: 300, maxTrees: 1_000)
        let region = try await RealWorldRegion.load(airport: ident, detail: d, transport: Showcase.transport(for: ident, fallback: nil), cache: nil)
        let b = region.fallbackBuildings
        #expect(b.count > 50, "fallback buildings in Seattle: \(b.count)")
        for x in b {
            let c = OSMGeometry.centroid(x.footprint)
            #expect(!region.apronOrRunway(c.x, c.y))
            if let g = region.ground.ground(c.x, c.y) { #expect(g.water < 0.5) }
            #expect(OSMGeometry.signedArea(x.footprint) > 0, "counter-clockwise footprint")
        }
        #expect(region.proceduralBuildings() == b, "deterministic")
    }
}

@Suite struct IsolatedBuildingTests {
    @Test func loneBoxesAreDroppedClustersKept() {
        func box(_ x: Double, _ y: Double, _ id: Int64) -> OSMBuilding {
            OSMBuilding(id: id, footprint: [SIMD2(x - 4, y - 4), SIMD2(x + 4, y - 4), SIMD2(x + 4, y + 4), SIMD2(x - 4, y + 4)], heightMetres: 6)
        }
        let cluster = (0..<4).map { box(Double($0) * 40, 0, Int64($0)) }
        let lone = box(500, 500, 99)
        let kept = RealWorldRegion.dropIsolated(cluster + [lone])
        #expect(kept.count == 4 && !kept.contains { $0.id == 99 })
    }
}
