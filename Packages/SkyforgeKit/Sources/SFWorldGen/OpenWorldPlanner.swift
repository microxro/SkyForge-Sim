// SKYFORGE — Apache-2.0
// Original-world planner: seeded settlement sites, street networks, building lots and landmarks,
// fitted to the terrain. Deterministic: a pure function of (seed, terrain, extent). No Apple frameworks,
// so it runs in Linux tests and CI.
import Foundation
import SFMath

/// Terrain the planner reads. Local ENU metres: x east, y north, origin at the world centre.
public protocol OpenWorldTerrain: Sendable {
    /// Ground height in metres.
    func height(_ x: Double, _ y: Double) -> Double
    /// True where the ground is water (sea, lake or river). Nothing is built on water.
    func isWater(_ x: Double, _ y: Double) -> Bool
}

public enum SettlementTier: Int, Sendable, Codable, CaseIterable, Comparable {
    case hamlet, village, town, city, metropolis

    public static func < (lhs: SettlementTier, rhs: SettlementTier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Radius of the built-up area, metres.
    public var radius: Double {
        switch self {
        case .hamlet: return 220
        case .village: return 450
        case .town: return 1_000
        case .city: return 2_000
        case .metropolis: return 3_200
        }
    }

    /// Lot attempts per settlement. Lots that fail the terrain, road or overlap tests are dropped.
    public var lotAttempts: Int {
        switch self {
        case .hamlet: return 40
        case .village: return 160
        case .town: return 900
        case .city: return 2_400
        case .metropolis: return 4_800
        }
    }
}

public enum StreetPattern: Int, Sendable, Codable { case grid, radial, organic }

public struct SettlementSite: Sendable, Equatable {
    public var centre: SIMD2<Double>
    public var tier: SettlementTier
    public var seed: UInt64
}

/// A building footprint on the ground. The renderer picks materials from the region palette.
public struct LotPlan: Sendable, Equatable {
    public var centre: SIMD2<Double>
    /// x runs along `heading`, y across it (metres).
    public var halfSize: SIMD2<Double>
    /// Radians from east.
    public var heading: Double
    /// Ground elevation under the centre (m).
    public var ground: Double
    public var wallHeight: Double
    public var kind: BuildingKind
}

public enum LandmarkKind: Int, Sendable, Codable, CaseIterable {
    case cathedral, clockTower, waterTower, lighthouse
}

public struct Landmark: Sendable, Equatable {
    public var kind: LandmarkKind
    public var position: SIMD2<Double>
    public var ground: Double
    public var height: Double
}

public struct SettlementPlan: Sendable {
    public var site: SettlementSite
    public var name: String
    public var pattern: StreetPattern
    public var roads: [Road]
    public var lots: [LotPlan]
    public var landmarks: [Landmark]
    public var contentHash: UInt64
}

public struct OpenWorldPlan: Sendable {
    public var settlements: [SettlementPlan]
    public var airports: [AirportLayout]
}

public struct OpenWorldPlanner: Sendable {
    public let seed: UInt64
    public let terrain: any OpenWorldTerrain
    /// Half-width of the planned square, metres.
    public let extent: Double
    /// Site grid cell size, metres. Each cell holds at most one settlement.
    public let cellSize: Double

    public init(seed: UInt64, terrain: any OpenWorldTerrain, extent: Double = 30_000, cellSize: Double = 6_000) {
        self.seed = seed
        self.terrain = terrain
        self.extent = max(1_000, extent)
        self.cellSize = max(1_000, cellSize)
    }

    /// One candidate site per grid cell, decided by hash. Sites whose centre is water are dropped.
    public func sites() -> [SettlementSite] {
        let n = Int((extent / cellSize).rounded(.up))
        var out: [SettlementSite] = []
        for j in -n..<n {
            for i in -n..<n {
                let h = Hash.int(i, j, seed: seed)
                guard Hash.unit(Hash.combine(h, 1)) < 0.62 else { continue }
                let jx = 0.2 + 0.6 * Hash.unit(Hash.combine(h, 2))
                let jy = 0.2 + 0.6 * Hash.unit(Hash.combine(h, 3))
                let centre = SIMD2<Double>((Double(i) + jx) * cellSize, (Double(j) + jy) * cellSize)
                guard abs(centre.x) <= extent, abs(centre.y) <= extent else { continue }
                guard !terrain.isWater(centre.x, centre.y) else { continue }
                let t = Hash.unit(Hash.combine(h, 4))
                let tier: SettlementTier
                if t < 0.03 {
                    tier = .metropolis
                } else if t < 0.10 {
                    tier = .city
                } else if t < 0.28 {
                    tier = .town
                } else if t < 0.60 {
                    tier = .village
                } else {
                    tier = .hamlet
                }
                out.append(SettlementSite(centre: centre, tier: tier, seed: Hash.combine(h, 5)))
            }
        }
        return out
    }

    /// Fixed city from the world data. Its centre and name never move.
    public struct AnchorCity: Sendable, Equatable {
        public var name: String
        public var centre: SIMD2<Double>   // metres
        public var tier: SettlementTier
        public var population: Int
        public init(name: String, centre: SIMD2<Double>, tier: SettlementTier, population: Int) {
            self.name = name; self.centre = centre; self.tier = tier; self.population = population
        }
    }

    /// Full plan. Anchored cities and airports are placed exactly. Procedural sites are dropped within
    /// `anchorClearance` metres of an anchored city, so towns and villages fill the gaps around them.
    public func makePlan(cities: [AnchorCity] = [], airports anchors: [AnchorAirport] = [],
                         anchorClearance: Double = 2_500) -> OpenWorldPlan {
        var settlements: [SettlementPlan] = []
        var layouts: [AirportLayout] = []
        for city in cities {
            let site = SettlementSite(centre: city.centre, tier: city.tier, seed: Hash.combine(seed, nameHash(city.name)))
            var s = plan(site)
            s.name = city.name
            settlements.append(s)
        }
        for site in sites() {
            let near = cities.contains { owLength($0.centre - site.centre) < anchorClearance }
            guard !near else { continue }
            settlements.append(plan(site))
        }
        for a in anchors {
            layouts.append(layout(for: a))
        }
        // Procedural airports only for procedural settlements; anchored airports are already placed.
        for s in settlements where !cities.contains(where: { $0.name == s.name }) {
            layouts.append(contentsOf: airports(for: s))
        }
        return OpenWorldPlan(settlements: settlements, airports: layouts)
    }

    func nameHash(_ name: String) -> UInt64 {
        var h: UInt64 = 0x434954
        for b in name.utf8 { h = Hash.mix(h ^ UInt64(b)) }
        return h
    }

    /// Streets, lots and landmarks for one settlement. A pure function of the site.
    public func plan(_ site: SettlementSite) -> SettlementPlan {
        var rng = Xoshiro256(seed: site.seed)
        let pattern: StreetPattern
        switch site.tier {
        case .hamlet, .village: pattern = .organic
        case .town: pattern = rng.unit() < 0.5 ? .grid : .radial
        case .city, .metropolis: pattern = rng.unit() < 0.8 ? .grid : .radial
        }
        let orientation = rng.range(0, Double.pi)
        let roads = streetNetwork(site, pattern, orientation, &rng)
        let lots = placeLots(site, pattern, orientation, roads, &rng)
        let landmarks = placeLandmarks(site, &rng)

        var fnv = FNV1a()
        fnv.add(site.seed)
        for r in roads {
            for p in r.points { fnv.add(p.x); fnv.add(p.y) }
        }
        for l in lots {
            fnv.add(l.centre.x); fnv.add(l.centre.y); fnv.add(l.wallHeight)
        }
        return SettlementPlan(site: site, name: OpenWorldNames.name(seed: site.seed), pattern: pattern,
                              roads: roads, lots: lots, landmarks: landmarks, contentHash: fnv.value)
    }

    // MARK: Streets

    func streetNetwork(_ site: SettlementSite, _ pattern: StreetPattern, _ orientation: Double,
                       _ rng: inout Xoshiro256) -> [Road] {
        let r = site.tier.radius
        let c = site.centre
        var raw: [Road] = []
        switch pattern {
        case .grid:
            let spacing: Double = site.tier >= .city ? 160 : 210
            let m = Int(r / spacing)
            let u = SIMD2<Double>(cos(orientation), sin(orientation))
            let v = SIMD2<Double>(-sin(orientation), cos(orientation))
            for k in -m...m {
                let cls: RoadClass = (k % 4 == 0) ? .arterial : .local
                let off = Double(k) * spacing
                raw.append(Road(points: [c + v * off - u * r, c + v * off + u * r], roadClass: cls))
                raw.append(Road(points: [c + u * off - v * r, c + u * off + v * r], roadClass: cls))
            }
            if site.tier == .metropolis {
                raw.append(Road(points: [c - u * r * 1.3, c + u * r * 1.3], roadClass: .highway))
            }
        case .radial:
            let spokes = site.tier >= .town ? 5 + Int(rng.unit() * 3) : 4
            for s in 0..<spokes {
                let a = orientation + Double(s) * 2 * Double.pi / Double(spokes) + rng.range(-0.15, 0.15)
                let d = SIMD2<Double>(cos(a), sin(a))
                raw.append(Road(points: [c, c + d * r], roadClass: site.tier >= .town ? .arterial : .local))
            }
            for frac in [0.45, 0.85] {
                var ring: [SIMD2<Double>] = []
                for k in 0...24 {
                    let a = Double(k) * 2 * Double.pi / 24
                    ring.append(c + SIMD2<Double>(cos(a), sin(a)) * (r * frac))
                }
                raw.append(Road(points: ring, roadClass: .local))
            }
        case .organic:
            let count = site.tier == .hamlet ? 2 : 4
            for _ in 0..<count {
                var p = c
                var heading = rng.range(0, 2 * Double.pi)
                var pts: [SIMD2<Double>] = [p]
                let steps = max(2, Int(r / 40))
                for _ in 0..<steps {
                    heading += rng.range(-0.18, 0.18)
                    p = p + SIMD2<Double>(cos(heading), sin(heading)) * 40
                    pts.append(p)
                }
                raw.append(Road(points: pts, roadClass: .rural))
            }
        }
        // Clip roads to land. Runs shorter than two points are dropped.
        var out: [Road] = []
        for road in raw {
            for run in landRuns(road.points) {
                out.append(Road(points: run, roadClass: road.roadClass))
            }
        }
        return out
    }

    /// Densifies a polyline at 20 m and returns the runs that stay on land (two or more points each).
    func landRuns(_ pts: [SIMD2<Double>]) -> [[SIMD2<Double>]] {
        guard pts.count >= 2 else { return [] }
        var runs: [[SIMD2<Double>]] = []
        var current: [SIMD2<Double>] = []
        for k in 0..<(pts.count - 1) {
            let a = pts[k], b = pts[k + 1]
            let steps = max(1, Int((owLength(b - a) / 20).rounded(.up)))
            let first = k == 0 ? 0 : 1
            for s in first...steps {
                let p = a + (b - a) * (Double(s) / Double(steps))
                if terrain.isWater(p.x, p.y) {
                    if current.count >= 2 { runs.append(current) }
                    current = []
                } else {
                    current.append(p)
                }
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    // MARK: Lots

    func placeLots(_ site: SettlementSite, _ pattern: StreetPattern, _ orientation: Double,
                   _ roads: [Road], _ rng: inout Xoshiro256) -> [LotPlan] {
        let r = site.tier.radius
        let c = site.centre
        var segments: [OwSegment] = []
        for road in roads {
            let half = road.roadClass.width / 2
            for k in 0..<(road.points.count - 1) {
                segments.append(OwSegment(a: road.points[k], b: road.points[k + 1], half: half))
            }
        }
        var index = OwSpatialIndex(cell: 130)
        var lots: [LotPlan] = []
        for _ in 0..<site.tier.lotAttempts {
            let rr = r * Double(rng.unit()).squareRoot()
            let a = rng.range(0, 2 * Double.pi)
            let centre = c + SIMD2<Double>(cos(a), sin(a)) * rr
            let frac = rr / r
            let kind = chooseKind(site.tier, frac, &rng)
            let (halfSize, wall) = lotSize(kind, &rng)
            let heading: Double
            switch pattern {
            case .organic: heading = rng.range(0, 2 * Double.pi)
            case .grid, .radial: heading = orientation + (rng.unit() < 0.5 ? 0 : Double.pi / 2)
            }
            let ext = owLength(halfSize)

            // Terrain: no water under the footprint and a gentle spread of ground height.
            let corners = owFootprint(centre, halfSize, heading)
            var lo = Double.infinity, hi = -Double.infinity, wet = false
            for p in corners + [centre] {
                if terrain.isWater(p.x, p.y) { wet = true; break }
                let z = terrain.height(p.x, p.y)
                lo = min(lo, z); hi = max(hi, z)
            }
            guard !wet, hi - lo <= 0.5 + 0.05 * 2 * max(halfSize.x, halfSize.y) else { continue }

            // Roads: clear of every centreline by the road half-width, a setback of 3 m and the lot's extent.
            guard owClearance(centre, segments) >= ext + 3 else { continue }
            // Other lots: no overlap.
            guard index.isClear(centre, radius: ext) else { continue }

            let ground = terrain.height(centre.x, centre.y)
            index.insert(centre, radius: ext)
            lots.append(LotPlan(centre: centre, halfSize: halfSize, heading: heading, ground: ground,
                                wallHeight: wall, kind: kind))
            if lots.count >= site.tier.lotAttempts { break }
        }
        return lots
    }

    func chooseKind(_ tier: SettlementTier, _ frac: Double, _ rng: inout Xoshiro256) -> BuildingKind {
        let u = rng.unit()
        switch tier {
        case .metropolis, .city:
            if frac < 0.35 { return u < 0.6 ? .office : .apartment }
            if frac < 0.7 { return u < 0.5 ? .apartment : .rowHouse }
            return u < 0.7 ? .house : .warehouse
        case .town:
            if frac < 0.3 { return u < 0.5 ? .stripMall : .office }
            if frac < 0.7 { return u < 0.5 ? .rowHouse : .apartment }
            return u < 0.9 ? .house : .warehouse
        case .village, .hamlet:
            if frac > 0.6 && u < 0.2 { return .barn }
            if frac < 0.3 && u < 0.15 { return .church }
            return .house
        }
    }

    /// Half-size (along, across) and wall height for a building kind.
    func lotSize(_ kind: BuildingKind, _ rng: inout Xoshiro256) -> (SIMD2<Double>, Double) {
        switch kind {
        case .office:
            let hs = SIMD2<Double>(rng.range(14, 26), rng.range(12, 20))
            return (hs, rng.range(18, 80))
        case .apartment:
            let hs = SIMD2<Double>(rng.range(10, 18), rng.range(8, 12))
            return (hs, rng.range(12, 36))
        case .rowHouse:
            let hs = SIMD2<Double>(rng.range(6, 9), rng.range(5, 7))
            return (hs, rng.range(6, 9))
        case .house:
            let hs = SIMD2<Double>(rng.range(5, 8), rng.range(4, 7))
            return (hs, rng.range(4.5, 7))
        case .stripMall:
            let hs = SIMD2<Double>(rng.range(14, 22), rng.range(6, 9))
            return (hs, rng.range(4.5, 6))
        case .warehouse:
            let hs = SIMD2<Double>(rng.range(18, 30), rng.range(10, 18))
            return (hs, rng.range(7, 11))
        case .church:
            let hs = SIMD2<Double>(rng.range(7, 10), rng.range(6, 9))
            return (hs, rng.range(10, 18))
        case .barn:
            let hs = SIMD2<Double>(rng.range(7, 11), rng.range(5, 7))
            return (hs, rng.range(5, 8))
        }
    }

    // MARK: Landmarks

    func placeLandmarks(_ site: SettlementSite, _ rng: inout Xoshiro256) -> [Landmark] {
        var out: [Landmark] = []
        let c = site.centre
        let g = terrain.height(c.x, c.y)
        switch site.tier {
        case .metropolis:
            out.append(Landmark(kind: .cathedral, position: c, ground: g, height: 84))
        case .city:
            out.append(Landmark(kind: .cathedral, position: c, ground: g, height: 52))
        case .town:
            out.append(Landmark(kind: .clockTower, position: c, ground: g, height: 24))
        case .village:
            let p = c + SIMD2<Double>(30, 30)
            if rng.unit() < 0.5, !terrain.isWater(p.x, p.y) {
                out.append(Landmark(kind: .waterTower, position: p, ground: terrain.height(p.x, p.y), height: 22))
            }
        case .hamlet:
            break
        }
        if let shore = shorePoint(c, maxRange: site.tier.radius * 1.4) {
            out.append(Landmark(kind: .lighthouse, position: shore, ground: terrain.height(shore.x, shore.y), height: 28))
        }
        return out
    }

    /// First land point before water on a ray search of 16 directions. Nil when no water is in range.
    func shorePoint(_ centre: SIMD2<Double>, maxRange: Double) -> SIMD2<Double>? {
        for k in 0..<16 {
            let a = Double(k) * 2 * Double.pi / 16
            let d = SIMD2<Double>(cos(a), sin(a))
            var prev = centre
            var t = 50.0
            while t <= maxRange {
                let p = centre + d * t
                if terrain.isWater(p.x, p.y) {
                    return terrain.isWater(prev.x, prev.y) ? nil : prev
                }
                prev = p
                t += 50
            }
        }
        return nil
    }
}

/// Name generator for settlements and airports, from the seed alone.
public enum OpenWorldNames {
    static let starts = ["Al", "Bren", "Cor", "Dun", "El", "Fen", "Gar", "Hal", "Ivy", "Kel", "Lo", "Mar",
                         "Nor", "Oak", "Pen", "Ros", "Sul", "Tor", "Val", "Wes"]
    static let middles = ["ber", "den", "ford", "mont", "stan", "vale", "wick", "holm", "ross", ""]
    static let ends = ["ton", "by", "ville", "port", "field", "haven", "gate", "ridge", "bury", ""]

    public static func name(seed: UInt64) -> String {
        let h = Hash.combine(seed, 0x4E41_4D45)
        let a = starts[Int(Hash.mix(h) % UInt64(starts.count))]
        let b = middles[Int(Hash.mix(h &+ 1) % UInt64(middles.count))]
        let c = ends[Int(Hash.mix(h &+ 2) % UInt64(ends.count))]
        return a + b + c
    }
}

// MARK: - Geometry helpers (file-private)

fileprivate struct OwSegment {
    var a: SIMD2<Double>
    var b: SIMD2<Double>
    var half: Double
}

/// Smallest distance from `p` to any road segment minus that road's half-width.
fileprivate func owClearance(_ p: SIMD2<Double>, _ segments: [OwSegment]) -> Double {
    var best = Double.infinity
    for s in segments {
        best = min(best, owSegmentDistance(p, s.a, s.b) - s.half)
    }
    return best
}

fileprivate func owSegmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let ab = b - a
    let len2 = ab.x * ab.x + ab.y * ab.y
    var t = 0.0
    if len2 > 0 {
        let ap = p - a
        t = min(1, max(0, (ap.x * ab.x + ap.y * ab.y) / len2))
    }
    return owLength(p - (a + ab * t))
}

fileprivate func owLength(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

/// Corners of a rectangle with half-size `hs` (x along heading), counter-clockwise.
fileprivate func owFootprint(_ c: SIMD2<Double>, _ hs: SIMD2<Double>, _ heading: Double) -> [SIMD2<Double>] {
    let u = SIMD2<Double>(cos(heading), sin(heading))
    let v = SIMD2<Double>(-sin(heading), cos(heading))
    let ux = u * hs.x, vy = v * hs.y
    return [c - ux - vy, c + ux - vy, c + ux + vy, c - ux + vy]
}

/// Uniform grid of lot centres for overlap tests. Assumes radii of at most half the cell size.
fileprivate struct OwSpatialIndex {
    let cell: Double
    var buckets: [Int: [Int]] = [:]
    var centres: [SIMD2<Double>] = []
    var radii: [Double] = []

    init(cell: Double) { self.cell = cell }

    private func key(_ ix: Int, _ iy: Int) -> Int { ix &* 73_856_093 ^ iy &* 19_349_663 }

    func isClear(_ p: SIMD2<Double>, radius: Double) -> Bool {
        let ix = Int((p.x / cell).rounded(.down)), iy = Int((p.y / cell).rounded(.down))
        for dx in -1...1 {
            for dy in -1...1 {
                for idx in buckets[key(ix + dx, iy + dy)] ?? [] {
                    if owLength(centres[idx] - p) < radii[idx] + radius + 2 { return false }
                }
            }
        }
        return true
    }

    mutating func insert(_ p: SIMD2<Double>, radius: Double) {
        let ix = Int((p.x / cell).rounded(.down)), iy = Int((p.y / cell).rounded(.down))
        centres.append(p)
        radii.append(radius)
        buckets[key(ix, iy), default: []].append(centres.count - 1)
    }
}
