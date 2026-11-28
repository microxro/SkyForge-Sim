// SKYFORGE — Apache-2.0
// Quick Flight vertical slice: the SkyWorld airport region (preview scene j's world), the SF-1
// Trainer flight model, instruments and input mapping, independent of any GPU. The Metal world
// renderer and the SwiftUI screen drive this; tests fly it headless on Linux.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel
import SFInstruments
import SFInput
import SFWorldGen
import SFPreview
import SFWeather

/// Terrain heights from the procedural recipe for the flight model (NED north/east ↔ world y/x).
public struct RecipeTerrain: TerrainHeightProvider {
    public let recipe: TerrainRecipe
    public init(_ r: TerrainRecipe) { recipe = r }
    public func elevation(north: Double, east: Double) -> Double { recipe.height(east, north) }
}

/// Anything Quick Flight can fly over: terrain heights and a runway to start from.
public protocol FlightWorld: Sendable {
    var runwayThreshold: SIMD2<Double> { get }      // low-numbered threshold, world x east / y north (m)
    var runwayHeading: Double { get }               // true heading from that threshold (rad)
    var runwayLengthMetres: Double { get }
    var runwayElevation: Double { get }             // m AMSL
    func height(_ x: Double, _ y: Double) -> Double
}

extension FlightWorld {
    public var runwayDirection: SIMD2<Double> { SIMD2(sin(runwayHeading), cos(runwayHeading)) }
}

/// Flight-model terrain backed by any FlightWorld.
public struct FlightWorldTerrain: TerrainHeightProvider {
    public let world: any FlightWorld
    public init(_ w: any FlightWorld) { world = w }
    public func elevation(north: Double, east: Double) -> Double { world.height(east, north) }
}

public enum QuickFlightStart: String, Sendable, CaseIterable {
    case runway, final
}

/// Scene density for a device class (triangles scale roughly with 1/step²).
public struct QuickFlightDetail: Sendable, Equatable {
    public var nearHalfExtent: Double, nearStep: Double
    public var midHalfExtent: Double, midStep: Double
    public var farHalfExtent: Double, farStep: Double
    public var objectRadius: Double
    public var treeDetailRadius: Double
    /// Cap on instanced trees; farther trees are thinned first (`buildEnvironmentInstanced`).
    public var maxTrees: Int = 1_000_000
    public static let phone = QuickFlightDetail(nearHalfExtent: 2_000, nearStep: 12, midHalfExtent: 7_000, midStep: 48,
                                                farHalfExtent: 20_000, farStep: 200, objectRadius: 1_600, treeDetailRadius: 300)
    public static let tablet = QuickFlightDetail(nearHalfExtent: 2_500, nearStep: 9, midHalfExtent: 8_000, midStep: 36,
                                                 farHalfExtent: 24_000, farStep: 160, objectRadius: 2_200, treeDetailRadius: 450)
    public static let desktop = QuickFlightDetail(nearHalfExtent: 3_000, nearStep: 8, midHalfExtent: 9_000, midStep: 32,
                                                  farHalfExtent: 28_000, farStep: 140, objectRadius: 2_400, treeDetailRadius: 550,
                                                  maxTrees: 58_000)   // 105k uncapped kept SkyWorld high at its budget; 65k left ~0 margin against CI variance (run 42724229611: 16.95 ms)
}

public struct QuickFlightWorld: FlightWorld {
    public let generator: WorldGenerator
    public let runway: RunwaySpec
    public let runwayElevation: Double
    public var recipe: TerrainRecipe { generator.terrain }

    public init(seed: UInt64 = 1) {
        let s = PreviewScenes.setup(.airportFinal, seed: seed)
        generator = s.generator
        runway = s.runway!
        runwayElevation = s.runwayElevation
    }

    public var runwayThreshold: SIMD2<Double> { runway.threshold }
    public var runwayHeading: Double { runway.heading }
    public var runwayLengthMetres: Double { runway.length }
    public func height(_ x: Double, _ y: Double) -> Double { recipe.height(x, y) }
    public var runwayCentre: SIMD2<Double> { runway.threshold + runwayDirection * runway.length / 2 }

    /// Static environment mesh around the airfield (no view culling: the camera moves), trees baked in.
    public func buildEnvironment(detail d: QuickFlightDetail, origin: SIMD3<Double>? = nil) -> TriangleSoup {
        build(detail: d, origin: origin, collectTrees: false).soup
    }

    /// The environment without trees, plus the trees as a list for GPU instancing (the Metal renderer
    /// draws and culls them per 400 m cell; baked into the mesh they doubled SkyWorld's shadow cost).
    public func buildEnvironmentInstanced(detail d: QuickFlightDetail) -> (soup: TriangleSoup, trees: [Tree]) {
        build(detail: d, origin: nil, collectTrees: true)
    }

    func build(detail d: QuickFlightDetail, origin: SIMD3<Double>?, collectTrees: Bool) -> (soup: TriangleSoup, trees: [Tree]) {
        var collected: [Tree] = []
        let focus = runwayCentre
        var b = SceneBuilder(generator: generator, origin: origin ?? SIMD3(focus.x, focus.y, 0))
        b.airfield = runway
        b.townImpostor = (focus, d.objectRadius)
        b.addTerrain(centre: focus, halfExtent: d.nearHalfExtent, step: d.nearStep)
        b.addTerrain(centre: focus, halfExtent: d.midHalfExtent, step: d.midStep, skipInside: d.nearHalfExtent - d.midStep, lower: 0.5, far: true)
        b.addTerrain(centre: focus, halfExtent: d.farHalfExtent, step: d.farStep, skipInside: d.midHalfExtent - d.farStep, lower: 1.5, far: true)
        b.addWater(centre: focus, halfExtent: d.nearHalfExtent * 1.4, step: 10)
        let r = d.objectRadius
        let cs = WorldGenerator.chunkSize
        // Objects around the airfield and around the final approach (the 3 nm final start is ~4 km from
        // the runway centre, beyond the object radius, so its whole foreground used to be bare fields).
        let foci = [focus, runway.threshold - runwayDirection * 2_600]
        func nearest(_ p: SIMD2<Double>) -> (dist: Double, focus: SIMD2<Double>) {
            foci.map { f -> (Double, SIMD2<Double>) in let d = p - f; return ((d * d).sum().squareRoot(), f) }.min { $0.0 < $1.0 }!
        }
        let lo = SIMD2(foci.map(\.x).min()! - r, foci.map(\.y).min()! - r), hi = SIMD2(foci.map(\.x).max()! + r, foci.map(\.y).max()! + r)
        var roads: [Road] = [], chunkTrees: [(tree: Tree, dist: Double)] = [], chunkBuildings: [Building] = []
        for cy in Int((lo.y / cs).rounded(.down))...Int((hi.y / cs).rounded(.down)) {
            for cx in Int((lo.x / cs).rounded(.down))...Int((hi.x / cs).rounded(.down)) {
                let centre = SIMD2((Double(cx) + 0.5) * cs, (Double(cy) + 0.5) * cs)
                if nearest(centre).dist > r + cs { continue }
                let chunk = generator.generateChunk(cx: cx, cy: cy)
                b.addRoads(chunk.roads, near: nearest(centre).focus, radius: r * 1.3)
                roads += chunk.roads
                for bl in chunk.buildings where nearest(bl.center).dist < r { b.addBuilding(bl); chunkBuildings.append(bl) }
                for lot in chunk.parkingLots { b.addParkingLot(lot) }
                for t in chunk.trees {
                    let dist = nearest(SIMD2(t.position.x, t.position.y)).dist
                    if !SceneBuilder.keepTree(t.position, dist: dist, radius: r) { continue }
                    chunkTrees.append((t, dist))
                }
            }
        }
        let village = villageCluster(avoid: chunkBuildings)
        let laneFootprints = village.lanes.map { Building(center: $0.center, halfSize: $0.halfSize, heading: $0.heading, baseHeight: 0, wallHeight: 0,
                                                          roof: .flat, roofPitch: 0, kind: .house, wallColour: .zero, roofColour: .zero, variant: 0) }
        let steads = parcelFarmsteads(b.soup.fieldPattern, foci: foci, radius: r, roads: roads)
            .filter { f in !f.buildings.contains { Self.inside($0.center, village.gardens + laneFootprints, margin: 30) } }
        let farms = steads.flatMap(\.buildings) + village.buildings
        for t in village.lanes { b.addGroundPatch(center: t.center, halfSize: t.halfSize, heading: t.heading, colour: srgb(118, 112, 102)) }
        for f in steads where f.yard.halfSize.x > 0 {
            b.addGroundPatch(center: f.yard.center, halfSize: f.yard.halfSize, heading: f.heading, colour: srgb(160, 152, 134))   // gravel, pale enough to read at final range (round 51)
            if let t = f.track { b.addGroundPatch(center: t.center, halfSize: t.halfSize, heading: t.heading, colour: srgb(146, 132, 108)) }
        }
        for bl in farms { b.addBuilding(bl) }
        let yards = village.gardens + laneFootprints + steads.map { Building(center: $0.yard.center, halfSize: $0.yard.halfSize, heading: $0.heading, baseHeight: 0, wallHeight: 0,
                                          roof: .flat, roofPitch: 0, kind: .house, wallColour: .zero, roofColour: .zero, variant: 0) }
        for (t, dist) in chunkTrees where !Self.inside(SIMD2(t.position.x, t.position.y), yards, margin: 3) {
            if collectTrees { collected.append(t) } else { b.addTree(t, detail: dist < d.treeDetailRadius ? 2 : 1) }
        }
        for t in steads.flatMap(\.trees) + village.trees {
            if collectTrees { collected.append(t) } else { b.addTree(t, detail: 2) }
        }
        let hedges = hedgerowTrees(b.soup.fieldPattern, foci: foci, radius: r).filter { !Self.inside(SIMD2($0.position.x, $0.position.y), yards, margin: 2) }
        if collectTrees { collected += hedges } else { for t in hedges { b.addTree(t, detail: 1) } }
        if collectTrees && collected.count > d.maxTrees {
            // Thin only trees farther than 1 km from both foci, by a stable per-tree hash, to the cap.
            let nearCount = collected.filter { nearest(SIMD2($0.position.x, $0.position.y)).dist <= 1_000 }.count
            let keepFar = Double(max(0, d.maxTrees - nearCount)) / Double(max(1, collected.count - nearCount))
            collected = collected.filter { t in
                nearest(SIMD2(t.position.x, t.position.y)).dist <= 1_000
                    || Hash.unit(Hash.int(Int(t.position.x * 4), Int(t.position.y * 4), seed: 0x51C7)) < keepFar
            }
        }
        b.addRunway(runway, elevation: runwayElevation)
        b.addAirportKit(runway, elevation: runwayElevation)
        return (b.soup, collected)
    }

    /// Farmsteads in a corner of about one farmed parcel in six: a house, a barn and a shed on the parcel
    /// axes, clear of the hedgerows, roads, water and the runway approach. Farms used to line only the
    /// rural roads, and none reached the open fields the SkyWorld final camera looks across (art round 49).
    struct Patch { var center: SIMD2<Double>; var halfSize: SIMD2<Double>; var heading: Double }
    struct Farmstead { var buildings: [Building]; var yard: Patch; var heading: Double; var track: Patch?; var trees: [Tree] }

    func parcelFarmsteads(_ fieldPattern: FieldPattern?, foci: [SIMD2<Double>], radius r: Double, roads: [Road]) -> [Farmstead] {
        var out: [Farmstead] = []
        guard let pattern = fieldPattern, let grid = pattern.parcels else { return out }
        let a = Double(FieldPattern.angle)
        let du = SIMD2(cos(a), sin(a)), dv = SIMD2(-sin(a), cos(a))
        let halfU = Double(FieldPattern.parcelU) / 2, halfV = Double(FieldPattern.parcelV) / 2
        let houseWalls = [srgb(206, 196, 172), srgb(188, 176, 156), srgb(214, 208, 196), srgb(170, 150, 124)]
        let houseRoofs = [srgb(118, 64, 48), srgb(96, 90, 86), srgb(134, 82, 58)]
        func roadDistance(_ p: SIMD2<Double>) -> Double {
            var best = Double.infinity
            for road in roads {
                for k in 0..<max(0, road.points.count - 1) {
                    let s0 = road.points[k], s1 = road.points[k + 1], e = s1 - s0
                    if min(s0.x, s1.x) > p.x + 40 || max(s0.x, s1.x) < p.x - 40 || min(s0.y, s1.y) > p.y + 40 || max(s0.y, s1.y) < p.y - 40 { continue }
                    let t = max(0, min(1, ((p - s0) * e).sum() / max(1e-9, (e * e).sum())))
                    let q = s0 + e * t - p
                    best = min(best, (q * q).sum().squareRoot())
                }
            }
            return best
        }
        for gy in 0..<grid.height {
            for gx in 0..<grid.width {
                let key = SIMD2(grid.iu0 + Int32(gx), grid.iv0 + Int32(gy))
                guard grid.isOn(key) else { continue }
                let h = Hash.int(Int(key.x), Int(key.y), seed: 0xFA57)
                if Hash.unit(h) > 0.17 { continue }
                let c = pattern.parcelCentre(key)
                let centre = SIMD2(Double(c.x), Double(c.y))
                guard foci.contains(where: { f in let e = centre - f; return (e * e).sum() < r * r }) else { continue }
                let heading = h & 4 == 0 ? a : a + Double.pi / 2
                let along = SIMD2(cos(heading), sin(heading)), across = SIMD2(-sin(heading), cos(heading))
                let su: Double = h & 1 == 0 ? 1 : -1, sv: Double = h & 2 == 0 ? 1 : -1
                // The parcel centre ignores the grid's ±22 m warp: try the four corners, keep the first whose
                // buildings all sit inside this parcel and clear of its hedges.
                for (cu, cv) in [(su, sv), (su, -sv), (-su, sv), (-su, -sv)] {
                    let yard = centre + du * cu * (halfU - 30) + dv * cv * (halfV - 38)
                    let inward = centre - yard   // barn and shed toward the parcel's middle
                    let ia = along * (((inward * along).sum() < 0) ? -1.0 : 1.0), ic = across * (((inward * across).sum() < 0) ? -1.0 : 1.0)
                    let house = yard, barn = yard + ia * 21 + ic * 9, shed = yard - ia * 2 + ic * 17
                    let parts: [(SIMD2<Double>, SIMD2<Double>, BuildingKind, Bool)] = [
                        (house, SIMD2(5.5, 7), .house, false), (barn, SIMD2(9, 13), .barn, false), (shed, SIMD2(3.5, 5), .barn, true)]
                    // Gravel yard under and between the three buildings (house −8…32 m along, −9…28 m across).
                    // The yard shrinks to fit the parcel rather than costing the farmstead (round 50: a full-size yard
                    // that touched a hedge dropped both farms in the SkyWorld foreground).
                    var yardC = yard + ia * 12 + ic * 9.5, yardHalf = SIMD2(20.0, 18.5)
                    func corners(_ c: SIMD2<Double>, _ hs: SIMD2<Double>) -> [SIMD2<Double>] {
                        [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { c + ia * ($0.0 * hs.x) + ic * ($0.1 * hs.y) }
                    }
                    func clear(_ p: SIMD2<Double>) -> Bool {
                        let q = p - runway.threshold
                        let alongRwy = (q * runwayDirection).sum(), acrossRwy = abs(q.x * runwayDirection.y - q.y * runwayDirection.x)
                        // Off the runway and its approach, and none on the final path under the aircraft (round 49).
                        return !recipe.isWater(p.x, p.y) && roadDistance(p) > 16
                            && !(alongRwy > -1_200 && alongRwy < runway.length + 400 && acrossRwy < 260)
                            && !(alongRwy > -4_500 && acrossRwy < 40)
                    }
                    let fits = parts.allSatisfy { p, half, _, _ in
                        let hd = pattern.hedge(Float(p.x), Float(p.y))
                        return hd.parcel == key && Double(hd.distance) > (half * half).sum().squareRoot() + 4 && clear(p)
                    }
                    if !fits { continue }
                    func yardFits(_ c: SIMD2<Double>, _ hs: SIMD2<Double>) -> Bool {
                        corners(c, hs).allSatisfy { p in let hd = pattern.hedge(Float(p.x), Float(p.y)); return hd.parcel == key && hd.distance > 2 }
                    }
                    var hasYard = true
                    if !yardFits(yardC, yardHalf) {
                        yardC = yard + ia * 10 + ic * 7; yardHalf = SIMD2(16, 14)
                        hasYard = yardFits(yardC, yardHalf)
                    }
                    let wall = houseWalls[Int((h >> 8) % UInt64(houseWalls.count))]
                    let roofC = houseRoofs[Int((h >> 12) % UInt64(houseRoofs.count))]
                    // Weathered barn red and grey or dark-green metal roofs (round 49: saturated red boxes).
                    let tone = Float(0.88 + 0.24 * Hash.unit(Hash.int(Int(key.x), Int(key.y), seed: 0xBA42)))
                    let barnWall = SIMD3<Float>(0.26, 0.11, 0.09) * tone   // more weathered (round 50: still saturated)
                    let barnRoof = h & 8 == 0 ? srgb(98, 100, 102) : srgb(62, 78, 66)
                    var buildings: [Building] = []
                    for (p, half, kind, isShed) in parts {
                        buildings.append(Building(center: p, halfSize: half, heading: heading, baseHeight: height(p.x, p.y),
                                                  wallHeight: isShed ? 3.2 : (kind == .barn ? 6.5 : 5.6), roof: .gabled,
                                                  roofPitch: kind == .barn ? 0.75 : 0.6, kind: kind,
                                                  wallColour: isShed ? srgb(118, 104, 84) : (kind == .barn ? barnWall : wall),
                                                  roofColour: kind == .barn ? barnRoof : roofC,
                                                  variant: UInt32(truncatingIfNeeded: h >> 16) &+ (isShed ? 2 : kind == .barn ? 1 : 0)))
                    }
                    // Track from the yard's outer edge to the nearest hedge (the parcel's corner side).
                    var track: Patch?
                    if !hasYard { yardHalf = .zero }
                    let start = yardC - ic * yardHalf.y
                    var len = 0.0
                    while len < 60 {
                        let p = start - ic * (len + 2)
                        let hd = pattern.hedge(Float(p.x), Float(p.y))
                        if hd.parcel != key || hd.distance < 1.5 { break }
                        len += 2
                    }
                    if len >= 4 && hasYard {
                        track = Patch(center: start - ic * (len / 2) + ia * 4, halfSize: SIMD2(1.6, len / 2 + 0.5),
                                      heading: heading)
                    }
                    // Two or three yard trees beside the house, clear of the buildings.
                    var trees: [Tree] = []
                    for (k, off) in [(-12.0, -2.0), (-10.0, 14.0), (34.0, -4.0)].enumerated() where k < 2 || h & 16 == 0 {
                        let p = yard + ia * off.0 + ic * off.1
                        let hd = pattern.hedge(Float(p.x), Float(p.y))
                        if hd.parcel != key || hd.distance < 3 || Self.inside(p, buildings, margin: 3) { continue }
                        let ht = 9 + Hash.unit(Hash.int(Int(p.x * 3), Int(p.y * 3), seed: 0x7EE5)) * 5
                        let tint = Float(0.85 + 0.3 * Hash.unit(Hash.int(Int(p.y * 3), Int(p.x * 3), seed: 0x0C02)))
                        trees.append(Tree(position: SIMD3(p.x, p.y, height(p.x, p.y)), height: ht, crownRadius: ht * 0.34, conifer: false,
                                          colour: SIMD3<Float>(0.050, 0.075, 0.034) * tint))
                    }
                    out.append(Farmstead(buildings: buildings, yard: Patch(center: yardC, halfSize: yardHalf, heading: heading),
                                         heading: heading, track: track, trees: trees))
                    break
                }
            }
        }
        return out
    }

    /// A village beside the approach, about 190 m right of the centreline 1,450 m before the threshold, so the
    /// SkyWorld final camera sees a church, two streets of houses and a few barns in the right foreground (art round
    /// 53: at 1.1 km ahead and 340 m out the hamlet was ~100×25 px and read only as "some buildings").
    func villageCluster(avoid existing: [Building] = []) -> (buildings: [Building], lanes: [Patch], gardens: [Building], trees: [Tree]) {
        let dir = runwayDirection, right = SIMD2(dir.y, -dir.x)
        // ~550 m ahead of the final start (2 km out), 190 m right.
        let centre = runway.threshold - dir * 1_450 + right * 190
        let lane = right                                          // the main street runs away from the runway
        let across = SIMD2(-lane.y, lane.x)
        let heading = atan2(lane.y, lane.x), headingD = atan2(dir.y, dir.x)
        var buildings: [Building] = [], gardens: [Building] = [], trees: [Tree] = []
        let walls = [srgb(214, 204, 182), srgb(196, 182, 160), srgb(222, 214, 200), srgb(180, 160, 134), srgb(204, 196, 186)]
        let roofs = [srgb(122, 66, 50), srgb(104, 98, 94), srgb(138, 84, 60), srgb(92, 62, 52)]
        func put(_ p: SIMD2<Double>, _ half: SIMD2<Double>, _ hd: Double, _ kind: BuildingKind, _ wall: SIMD3<Float>, _ roof: SIMD3<Float>,
                 _ wallH: Double, _ pitch: Double, _ v: UInt32) {
            guard !recipe.isWater(p.x, p.y), !Self.inside(p, existing, margin: max(half.x, half.y) + 3),
                  !Self.inside(p, buildings, margin: max(half.x, half.y) + 2) else { return }
            buildings.append(Building(center: p, halfSize: half, heading: hd, baseHeight: height(p.x, p.y), wallHeight: wallH, roof: .gabled,
                                      roofPitch: pitch, kind: kind, wallColour: wall, roofColour: roof, variant: v))
            gardens.append(Building(center: p, halfSize: half + 4, heading: hd, baseHeight: 0, wallHeight: 0, roof: .flat, roofPitch: 0,
                                    kind: .house, wallColour: .zero, roofColour: .zero, variant: 0))
        }
        func house(_ p: SIMD2<Double>, _ hd: Double, _ out: SIMD2<Double>, _ h: UInt64) {
            let half = SIMD2(5.0 + 1.5 * Hash.unit(h >> 24), 4.5 + 1.0 * Hash.unit(h >> 32))
            put(p, half, hd, .house, walls[Int(h % UInt64(walls.count))], roofs[Int((h >> 4) % UInt64(roofs.count))],
                5.4 + 1.2 * Hash.unit(h >> 40), 0.7, UInt32(truncatingIfNeeded: h))
            // A garden tree behind most houses.
            if Hash.unit(h >> 44) < 0.7 {
                let tp = p + out * 14 + SIMD2(-out.y, out.x) * (Hash.unit(h >> 48) - 0.5) * 8
                let ht = 8 + 5 * Hash.unit(h >> 52)
                trees.append(Tree(position: SIMD3(tp.x, tp.y, height(tp.x, tp.y)), height: ht, crownRadius: ht * 0.36, conifer: false,
                                  colour: SIMD3<Float>(0.052, 0.078, 0.036) * Float(0.9 + 0.2 * Hash.unit(h >> 56))))
            }
        }
        // The church at the crossroads, its tower toward the runway.
        put(centre + across * 18 + lane * 20, SIMD2(11, 6), heading, .church, srgb(206, 200, 188), srgb(86, 84, 82), 8, 0.9, 0xC4)
        // Main street: houses both sides, gable ends to the street, every ~24 m, a few gaps.
        for k in 0...10 {
            for side in [-1.0, 1.0] {
                let h = Hash.int(k, side > 0 ? 1 : 0, seed: 0x711A)
                if Hash.unit(h) < 0.15 { continue }
                let p = centre + lane * (Double(k) * 24 + 6 * (Hash.unit(h >> 8) - 0.5)) + across * side * (16 + 4 * Hash.unit(h >> 16))
                house(p, heading + .pi / 2, across * side, h)
            }
        }
        // Cross street along the approach through the crossroads.
        for k in -5...5 where k != 0 {
            for side in [-1.0, 1.0] {
                let h = Hash.int(k, side > 0 ? 3 : 2, seed: 0x711B)
                if Hash.unit(h) < 0.2 { continue }
                let p = centre + dir * (Double(k) * 24 + 6 * (Hash.unit(h >> 8) - 0.5)) + lane * side * (16 + 4 * Hash.unit(h >> 16))
                house(p, headingD + .pi / 2, lane * side, h)
            }
        }
        // Barns at the outer end of the main street.
        for k in 0..<3 {
            let h = Hash.int(k, 7, seed: 0x711C)
            let p = centre + lane * (275 + 30 * Double(k)) + across * (k % 2 == 0 ? 22.0 : -24.0)
            let tone = Float(0.85 + 0.3 * Hash.unit(h))
            put(p, SIMD2(12, 7), heading, .barn, SIMD3<Float>(0.26, 0.11, 0.09) * tone, k == 1 ? srgb(80, 92, 74) : srgb(96, 94, 92),
                6.5, 0.6, UInt32(truncatingIfNeeded: h))
        }
        let lanes = [Patch(center: centre + lane * 140, halfSize: SIMD2(150, 3.0), heading: heading),
                     Patch(center: centre, halfSize: SIMD2(135, 3.0), heading: headingD)]
        return (buildings, lanes, gardens, trees)
    }

    /// Whether a point is within `margin` of any footprint in `buildings`.
    static func inside(_ p: SIMD2<Double>, _ buildings: [Building], margin: Double) -> Bool {
        buildings.contains { b in
            let d = p - b.center, lim = b.halfSize.x + b.halfSize.y + margin   // covers any heading (a fixed 60 m cut missed long lanes)
            if abs(d.x) > lim || abs(d.y) > lim { return false }
            let c = cos(b.heading), s = sin(b.heading)
            return abs(c * d.x + s * d.y) < b.halfSize.x + margin && abs(-s * d.x + c * d.y) < b.halfSize.y + margin
        }
    }

    /// Broadleaf trees along the hedgerows of farmed parcels (every ~9 m with gaps, ~22 % kept), so the
    /// farmland reads as hedged fields with 3D trees instead of flat paint. Clear of the runway and its
    /// approach surface.
    func hedgerowTrees(_ fieldPattern: FieldPattern?, foci: [SIMD2<Double>], radius r: Double) -> [Tree] {
        var out: [Tree] = []
        guard let pattern = fieldPattern, let grid = pattern.parcels else { return out }
        let step = 9.0
        for f in foci {
            var y = f.y - r
            while y < f.y + r {
                var x = f.x - r
                while x < f.x + r {
                    defer { x += step }
                    let dx = x - f.x, dy = y - f.y, dist = (dx * dx + dy * dy).squareRoot()
                    if dist > r { continue }
                    // Each focus covers its own disc; skip points the other focus also covers (no doubles).
                    if foci.first(where: { g in let e = SIMD2(x, y) - g; return (e * e).sum() < r * r }) != f { continue }
                    let h = pattern.hedge(Float(x), Float(y))
                    if h.distance > 2.5 || !grid.isOn(h.parcel) { continue }
                    let u = Hash.unit(Hash.int(Int(x * 2), Int(y * 2), seed: 0x4ED6))
                    if u > 0.22 { continue }
                    // Runway strip and approach: no trees within 150 m of the centreline from 900 m before
                    // the threshold to the far end.
                    let q = SIMD2(x, y) - runway.threshold
                    let along = (q * runwayDirection).sum(), across = abs(q.x * runwayDirection.y - q.y * runwayDirection.x)
                    if along > -900 && along < runway.length + 300 && across < 150 { continue }
                    let ht = 9 + Hash.unit(Hash.int(Int(x * 3), Int(y * 3), seed: 0x7A11)) * 7
                    let tint = Float(0.85 + 0.3 * Hash.unit(Hash.int(Int(y * 3), Int(x * 3), seed: 0x0C01)))
                    let tree = Tree(position: SIMD3(x, y, height(x, y)), height: ht, crownRadius: ht * 0.32, conifer: false,
                                    colour: SIMD3<Float>(0.052, 0.078, 0.036) * tint)
                    if SceneBuilder.keepTree(tree.position, dist: dist, radius: r) { out.append(tree) }
                }
                y += step
            }
        }
        return out
    }

    /// Aircraft mesh in body axes (x forward, y right, z down) with smooth normals. Skin triangles carry
    /// the base paint and the `airframe` / `airSurface` materials: the world shader draws glazing, livery,
    /// seams and markings per pixel from the body coordinates (`AircraftLivery` holds the same zones).
    public static func aircraftMesh(accent: SIMD3<Float> = AircraftLivery.navy) -> TriangleSoup {
        var soup = TriangleSoup(origin: .zero)
        func f(_ n: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(n.x), Float(n.y), Float(n.z)) }
        for t in AircraftMesh.build() {
            let colour: SIMD3<Float>, mat: Material
            switch t.part {
            case .fuselage: colour = AircraftLivery.white; mat = .airframe
            case .surface: colour = AircraftLivery.white; mat = .airSurface
            case .glass: colour = SIMD3(0.55, 0.04, 0.03); mat = .glass          // beacon lens
            case .metal: colour = SIMD3(0.78, 0.79, 0.80); mat = .metal
            case .tyre: colour = SIMD3(0.012, 0.012, 0.013); mat = .opaque
            case .prop: colour = SIMD3(0.016, 0.016, 0.018); mat = .prop
            }
            soup.add(t.a, t.b, t.c, na: f(t.na), nb: f(t.nb), nc: f(t.nc), colour: colour, material: mat)
        }
        _ = accent
        return soup
    }

    /// Mesh for a fleet aircraft id (`AircraftCatalog`): the SF-1 keeps its per-pixel livery; the other types use
    /// plain paint per part (`AircraftVariants`), with a dark glazed canopy. Unknown ids fall back to the SF-1.
    public static func aircraftMesh(for id: String, accent: SIMD3<Float> = AircraftLivery.navy) -> TriangleSoup {
        guard let variant = AircraftVariants.build(id: id) else { return aircraftMesh(accent: accent) }
        var soup = TriangleSoup(origin: .zero)
        func f(_ n: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(n.x), Float(n.y), Float(n.z)) }
        let style = variant.style
        for t in variant.triangles {
            let colour: SIMD3<Float>, mat: Material
            switch t.part {
            case .fuselage: colour = style.skin; mat = .paint
            case .surface: colour = style.surface; mat = .paint
            case .glass: colour = style.canopy; mat = .glass
            case .metal: colour = SIMD3(0.62, 0.63, 0.64); mat = .metal
            case .tyre: colour = SIMD3(0.012, 0.012, 0.013); mat = .opaque
            case .prop: colour = SIMD3(0.016, 0.016, 0.018); mat = .prop
            }
            soup.add(t.a, t.b, t.c, na: f(t.na), nb: f(t.nb), nc: f(t.nc), colour: colour, material: mat)
        }
        return soup
    }
}

public struct QuickFlightSession: Sendable {
    public let world: any FlightWorld
    public let aircraft: AircraftConfig
    public let model: FlightModel
    public private(set) var environment: FlightEnvironment
    /// Airframe icing index (0 clean … 1 heavily iced), driven from the weather each step.
    public private(set) var iceIndex: Double = 0
    private var weather: WeatherState?
    public private(set) var state: AircraftState
    public private(set) var inputs = ControlInputs()
    public private(set) var instruments = InstrumentSystem()
    public var mapper = InputMapper(profiles: [.defaults, .touchDefaults, .keyboardMouseDefaults])
    /// Mouse-look offsets for the chase camera (radians, and a fraction of view pitch). Decay to forward when released.
    public var lookYaw = 0.0
    public var lookPitch = 0.0

    /// Applies one frame of mouse-look. `delta` is nil when look is off, so the view eases back to forward.
    public mutating func applyLook(_ delta: (dx: Double, dy: Double)?, dt: Double) {
        guard dt.isFinite, dt >= 0 else { return }
        guard let d = delta, d.dx.isFinite, d.dy.isFinite else {
            let k = min(1, 3 * dt)
            lookYaw -= lookYaw * k
            lookPitch -= lookPitch * k
            return
        }
        lookYaw = min(0.9 * .pi, max(-0.9 * .pi, lookYaw + d.dx * 0.004))
        lookPitch = min(0.6, max(-0.6, lookPitch + d.dy * 0.003))
    }
    public private(set) var crashed = false
    public private(set) var time = 0.0
    private var accumulator = 0.0
    private var lastFlapAction = false
    public static let dt = 1.0 / 120
    /// Optional control filter applied to the pilot's inputs before each step (a fly-by-wire limiter).
    public var inputFilter: (@Sendable (ControlInputs, AircraftState, FlightOutputs) -> ControlInputs)?
    /// Airspeed (m/s) below which a retractable aircraft's gear is commanded down; nil leaves the gear alone.
    public var gearDownBelowSpeed: Double?
    /// Landing-gear travel: `inputs.gear` follows its position over time for retractable aircraft.
    public private(set) var gearActuator = GearActuator()
    /// Lowest point of the gear below the centre of gravity (m).
    public var gearHeight: Double { aircraft.gear.map { $0.position.z }.max() ?? 1.25 }

    /// - Parameters:
    ///   - aircraft: the aircraft to fly (default: the SF-1 Trainer).
    ///   - approachSpeed: true airspeed (m/s) and `approachFlaps` for the `.final` start.
    public init(world: any FlightWorld = QuickFlightWorld(), start: QuickFlightStart = .runway,
                aircraft: AircraftConfig = .sf1Trainer, approachSpeed: Double = 34, approachFlaps: Double = 0.5,
                wind: SIMD3<Double> = .zero, weather: WeatherState? = nil) {
        self.world = world
        self.aircraft = aircraft
        model = FlightModel(config: aircraft)
        let gear = aircraft.gear.map { $0.position.z }.max() ?? 1.25
        self.weather = weather
        environment = FlightEnvironment(windNED: wind, temperatureOffset: weather?.isaDeviation ?? 0,
                                        terrain: FlightWorldTerrain(world))
        let dir = world.runwayDirection
        let hdg = world.runwayHeading
        switch start {
        case .runway:
            let p = world.runwayThreshold + dir * 60
            state = AircraftState(positionNED: SIMD3(p.y, p.x, -(world.runwayElevation + gear - 0.03)), velocityBody: .zero,
                                  attitude: Quaternion(roll: 0, pitch: 0, yaw: hdg), bodyRates: .zero)
            inputs.brakes = 0
        case .final:
            let dist = 2_000.0
            let p = world.runwayThreshold - dir * dist
            let alt = world.runwayElevation + 15 + dist * tan(3 * Double.pi / 180)
            let trim = model.trimLevel(trueAirspeed: approachSpeed, altitude: alt, flaps: approachFlaps, environment: environment)
            var s = trim.state
            s.positionNED = SIMD3(p.y, p.x, -alt)
            s.attitude = Quaternion(roll: 0, pitch: trim.alpha, yaw: hdg)
            state = s
            inputs = trim.inputs
        }
        gearActuator = GearActuator(position: inputs.gear)
    }

    public var data: InstrumentData { instruments.data }
    /// Aircraft position in world coordinates (x east, y north, z up).
    public var positionENU: SIMD3<Double> { SIMD3(state.positionNED.y, state.positionNED.x, -state.positionNED.z) }
    /// Columns of the body (x fwd, y right, z down) → world ENU rotation.
    public var bodyToENUColumns: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        func enu(_ b: SIMD3<Double>) -> SIMD3<Double> { let n = state.attitude.rotate(b); return SIMD3(n.y, n.x, -n.z) }
        return (enu(SIMD3(1, 0, 0)), enu(SIMD3(0, 1, 0)), enu(SIMD3(0, 0, 1)))
    }
    public var heightAboveGround: Double {
        state.altitude - environment.terrain.elevation(north: state.positionNED.x, east: state.positionNED.y)
    }

    /// Advances real time `dt` with the given device state (fixed 120 Hz steps, at most 8 per call).
    public mutating func update(realDt: Double, device: InputMapper.DeviceState) {
        guard !crashed else { return }
        let out = mapper.evaluate(device, dt: realDt)
        // Elevator trim (held keys or scroll with Option) offsets the pitch command.
        inputs.elevator = min(1, max(-1, (out.axes[.pitch] ?? 0) + 0.5 * (out.axes[.elevatorTrim] ?? 0)))
        inputs.aileron = out.axes[.roll] ?? 0
        inputs.rudder = out.axes[.yaw] ?? 0
        if let t = out.axes[.throttle] { inputs.throttle = max(0, min(1, t)) }
        inputs.brakes = max(0, out.axes[.brakes] ?? 0)
        let flapEvent = out.actions.contains(.flapsDown) || out.actions.contains(.flapsUp)
        if flapEvent && !lastFlapAction {
            inputs.flaps = max(0, min(1, inputs.flaps + (out.actions.contains(.flapsDown) ? 0.5 : -0.5)))
        }
        lastFlapAction = flapEvent
        accumulator = min(accumulator + realDt, 8 * Self.dt)
        while accumulator >= Self.dt {
            step()
            accumulator -= Self.dt
        }
    }

    /// Integrates airframe icing from the weather at the aircraft's altitude.
    private mutating func updateIcing() {
        guard let w = weather else { return }
        let altitude = state.altitude + environment.originHeight
        let e = IcingConditions.exposure(altitude: altitude, isaDeviation: w.isaDeviation, cloudLayers: w.cloudLayers,
                                         visibilityMetres: w.visibilityMetres, precipitation: w.precipitation)
        let v = state.velocityBody
        let tas = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        iceIndex = IcingModel.step(index: iceIndex, liquidWater: e.liquidWater, tas: tas, temperatureK: e.temperatureK, dt: Self.dt)
        environment.iceIndex = iceIndex
    }

    /// One fixed simulation step with the current inputs.
    public mutating func step() {
        updateIcing()
        var o = model.outputs(state, inputs: inputs, environment: environment)
        if aircraft.retractableGear, let downBelow = gearDownBelowSpeed {
            let commandDown = o.weightOnWheels || o.trueAirspeed < downBelow
            inputs.gear = gearActuator.update(commandDown: commandDown, dt: Self.dt)
            o = model.outputs(state, inputs: inputs, environment: environment)
        }
        var applied = inputs
        if let filter = inputFilter { applied = filter(inputs, state, o); o = model.outputs(state, inputs: applied, environment: environment) }
        lastOutputs = o
        let rho = ISA.state(geometricAltitude: state.altitude).density
        instruments.update(state: state, outputs: o, environment: environment, inputs: applied,
                           rpm: PropellerRPM.rpm(throttle: applied.throttle, trueAirspeed: o.trueAirspeed, density: rho, config: aircraft), dt: Self.dt)
        let vBefore = state.velocityNED.z
        state = model.step(state, inputs: applied, environment: environment, dt: Self.dt)
        time += Self.dt
        // Crash: hard ground contact (> 600 fpm at contact) or the airframe below the surface. Heights are
        // relative to the gear, which is 1.25 m below the centre of gravity on the SF-1 (the original 0.3 m and -0.5 m).
        let belowGear = heightAboveGround - gearHeight
        if belowGear < -0.95 && vBefore > 3.0 { crashed = true }
        if belowGear < -1.75 { crashed = true }
    }

    /// Places the aircraft in a given state (a mission's airborne start) with the control inputs that hold it.
    public mutating func place(state s: AircraftState, inputs i: ControlInputs) {
        state = s
        inputs = i.sanitized
        gearActuator = GearActuator(position: inputs.gear, travelTime: gearActuator.travelTime)
        accumulator = 0
    }

    /// Flight-model outputs from the last step (airspeed, load, weight on wheels), for gameplay layers.
    public private(set) var lastOutputs: FlightOutputs?

    /// Ends the flight (an overstressed airframe, for example).
    public mutating func markCrashed() { crashed = true }

    /// Wakes of other aircraft (AI traffic); their induced velocity adds to the air mass at this aircraft.
    public mutating func setWakes(_ wakes: [WakeVortexPair]) { environment.wakes = wakes }

    /// Sets inputs directly (autopilots, tests).
    public mutating func setInputs(_ i: ControlInputs) { inputs = i.sanitized }

    /// Chase camera: behind and above the aircraft along its track, looking slightly ahead.
    /// `orbit` swings the camera around the aircraft (radians, 0 = directly behind).
    public func chaseCamera(distance: Double = 22, height: Double = 5, orbit: Double = 0) -> (position: SIMD3<Double>, target: SIMD3<Double>) {
        let e = state.attitude.euler
        // Mouse-look (lookYaw) adds to the track heading, so orbit and look compose.
        let yaw = e.yaw + lookYaw
        let fwd = SIMD3(sin(yaw), cos(yaw), 0)
        let p = positionENU
        let a = yaw + orbit
        let behind = SIMD3(sin(a), cos(a), 0)
        var cam = p - behind * distance + SIMD3(0, 0, height)
        let ground = world.height(cam.x, cam.y) + 2
        cam.z = max(cam.z, ground)
        // Look ahead along the track when behind the aircraft; when swung to the side, look at the aircraft.
        // Mouse-look pitch raises or lowers the target.
        let ahead = max(0, cos(orbit)) * 30
        return (cam, p + fwd * ahead + SIMD3(0, 0, 1 + lookPitch * 30))
    }
}
