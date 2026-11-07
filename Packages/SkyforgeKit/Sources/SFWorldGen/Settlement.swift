// SKYFORGE — Apache-2.0
// Roads, parcels, buildings and vegetation for a region (first SkyWorld layers, P1.4).
// Deterministic: a pure function of (recipe seed, chunk coordinates).
import Foundation
import SFMath

public enum RoadClass: Int, Sendable, Codable {
    case highway, arterial, local, rural
    public var width: Double {
        switch self {
        case .highway: return 22
        case .arterial: return 14
        case .local: return 8
        case .rural: return 6.5
        }
    }
}

public struct Road: Sendable, Equatable {
    public var points: [SIMD2<Double>]
    public var roadClass: RoadClass
}

public enum RoofType: Int, Sendable, Codable, CaseIterable {
    case gabled, hipped, flat, sawtooth
}

public enum BuildingKind: Int, Sendable, Codable {
    case house, rowHouse, apartment, office, warehouse, stripMall, church, barn
}

public struct Building: Sendable, Equatable {
    public var center: SIMD2<Double>
    public var halfSize: SIMD2<Double>      // along heading, across heading
    public var heading: Double              // rad, rotation of the local x axis from east
    public var baseHeight: Double           // ground elevation (m)
    public var wallHeight: Double           // m
    public var roof: RoofType
    public var roofPitch: Double            // ridge rise / half-width
    public var kind: BuildingKind
    public var wallColour: LinearRGB
    public var roofColour: LinearRGB
    public var variant: UInt32
}

public struct Tree: Sendable, Equatable {
    public var position: SIMD3<Double>
    public var height: Double
    public var crownRadius: Double
    public var conifer: Bool
    public var colour: LinearRGB
}

public struct ParkingLot: Sendable, Equatable {
    public var center: SIMD2<Double>
    public var halfSize: SIMD2<Double>
    public var heading: Double
    public var baseHeight: Double
    public var cars: [SIMD3<Double>]       // x, y, heading
}

/// Regional palette (§8.0 colour harmony): a few coordinated wall/roof materials per region.
public struct RegionPalette: Sendable {
    public var walls: [LinearRGB]
    public var roofs: [LinearRGB]
    public var cars: [LinearRGB]

    public init(seed: UInt64) {
        let schemes: [(walls: [LinearRGB], roofs: [LinearRGB])] = [
            // Warm brick and cream, slate and terracotta roofs
            ([srgb(150, 82, 62), srgb(176, 104, 78), srgb(222, 208, 182), srgb(196, 178, 150), srgb(132, 72, 56)],
             [srgb(72, 74, 80), srgb(150, 76, 52), srgb(96, 84, 78), srgb(60, 62, 66)]),
            // White stucco and sand, terracotta roofs
            ([srgb(236, 230, 214), srgb(222, 206, 176), srgb(214, 196, 170), srgb(240, 236, 226), srgb(200, 170, 140)],
             [srgb(168, 86, 56), srgb(150, 72, 48), srgb(182, 104, 70), srgb(120, 64, 46)]),
            // Timber and grey siding, dark roofs
            ([srgb(176, 168, 152), srgb(150, 146, 140), srgb(206, 200, 186), srgb(124, 112, 96), srgb(168, 150, 124)],
             [srgb(58, 60, 64), srgb(78, 76, 72), srgb(92, 70, 58), srgb(46, 48, 52)]),
        ]
        let s = schemes[Int(Hash.mix(seed) % UInt64(schemes.count))]
        walls = s.walls
        roofs = s.roofs
        cars = [srgb(200, 200, 204), srgb(40, 42, 46), srgb(120, 24, 28), srgb(30, 52, 92), srgb(150, 150, 148), srgb(226, 226, 222)]
    }
}

/// Everything generated for one 1 km chunk.
public struct WorldChunk: Sendable {
    public var cx: Int, cy: Int
    public var roads: [Road] = []
    public var buildings: [Building] = []
    public var trees: [Tree] = []
    public var parkingLots: [ParkingLot] = []

    /// Determinism hash over the chunk contents.
    public var contentHash: UInt64 {
        var h = FNV1a()
        for r in roads { h.add(UInt64(r.roadClass.rawValue)); for p in r.points { h.add(p.x); h.add(p.y) } }
        for b in buildings { h.add(b.center.x); h.add(b.center.y); h.add(b.wallHeight); h.add(UInt64(b.roof.rawValue)) }
        for t in trees { h.add(t.position.x); h.add(t.position.y); h.add(t.height) }
        return h.value
    }
}

public struct WorldGenerator: Sendable {
    public static let chunkSize = 1_000.0
    public let terrain: TerrainRecipe
    public let palette: RegionPalette
    public let latitude: Double
    public let season: Season
    let gridAngle: Double
    let blockU = 120.0, blockV = 210.0
    let warpNoise: GradientNoise2D
    let densityNoise: GradientNoise2D

    public init(terrain: TerrainRecipe, latitude: Double = 47, season: Season = .autumn) {
        self.terrain = terrain
        self.latitude = latitude
        self.season = season
        palette = RegionPalette(seed: terrain.seed)
        var rng = Xoshiro256(seed: Hash.combine(terrain.seed, 0x6A1D))
        gridAngle = rng.range(-0.5, 0.5)
        warpNoise = GradientNoise2D(seed: Hash.combine(terrain.seed, 0xA7A7))
        densityNoise = GradientNoise2D(seed: Hash.combine(terrain.seed, 0xD5D5))
    }

    // MARK: Settlement field

    /// Urban/suburban density 0…1.
    public func settlementDensity(_ x: Double, _ y: Double) -> Double {
        if terrain.isAirport(x, y, margin: 250) { return 0 }
        let n = densityNoise.fbm(x / 1_400, y / 1_400, octaves: 3) * 0.25
        switch terrain.kind {
        case .suburbanPlain:
            return clamp(1.15 - (x * x + y * y).squareRoot() / 3_200 + n, 0, 1)
        case .forestRiver:
            let d = ((x - 700) * (x - 700) + (y - 900) * (y - 900)).squareRoot()
            return clamp(0.9 - d / 450 + n, 0, 1)
        case .coastline:
            let d = ((x + 500) * (x + 500) + (y - 300) * (y - 300)).squareRoot()
            return terrain.height(x, y) > 3 ? clamp(1.0 - d / 900 + n, 0, 1) : 0
        case .mountainValley:
            let d = ((x + 120) * (x + 120) + (y + 600) * (y + 600)).squareRoot()
            return clamp(0.85 - d / 420 + n, 0, 1)
        }
    }

    // MARK: Street grid (rotated, gently warped)

    func warp(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(warpNoise.fbm(p.x / 900, p.y / 900, octaves: 2), warpNoise.fbm(p.x / 900 + 31, p.y / 900 - 17, octaves: 2)) * 18
    }

    /// World -> grid coordinates.
    func gridCoord(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let q = p + warp(p)
        let c = cos(gridAngle), s = sin(gridAngle)
        return SIMD2(c * q.x + s * q.y, -s * q.x + c * q.y)
    }

    /// Grid -> world coordinates (fixed-point inversion of the warp).
    func worldCoord(_ g: SIMD2<Double>) -> SIMD2<Double> {
        let c = cos(gridAngle), s = sin(gridAngle)
        let q = SIMD2(c * g.x - s * g.y, s * g.x + c * g.y)
        var p = q
        for _ in 0..<4 { p = q - warp(p) }
        return p
    }

    func localHeading(_ p: SIMD2<Double>) -> Double {
        let a = worldCoord(gridCoord(p)), b = worldCoord(gridCoord(p) + SIMD2(10, 0))
        return atan2(b.y - a.y, b.x - a.x)
    }

    /// Distance (m) to the nearest grid street centre-line and that street's class.
    public func streetDistance(_ x: Double, _ y: Double) -> (distance: Double, roadClass: RoadClass) {
        let g = gridCoord(SIMD2(x, y))
        let du = abs(g.x - (g.x / blockU).rounded() * blockU)
        let dv = abs(g.y - (g.y / blockV).rounded() * blockV)
        let iu = Int((g.x / blockU).rounded()), iv = Int((g.y / blockV).rounded())
        let classU: RoadClass = iu % 5 == 0 ? .arterial : .local
        let classV: RoadClass = iv % 4 == 0 ? .arterial : .local
        return du < dv ? (du, classU) : (dv, classV)
    }

    func gridActive(_ p: SIMD2<Double>) -> Bool { settlementDensity(p.x, p.y) > 0.32 && !terrain.isWater(p.x, p.y) }

    /// Distance to any road (grid streets where active, plus rural roads).
    public func roadDistance(_ x: Double, _ y: Double) -> Double {
        var d = Double.infinity
        if gridActive(SIMD2(x, y)) { d = streetDistance(x, y).distance }
        for r in ruralRoads() { d = min(d, Self.polylineDistance(r.points, SIMD2(x, y))) }
        return d
    }

    static func polylineDistance(_ pts: [SIMD2<Double>], _ p: SIMD2<Double>) -> Double {
        var best = Double.infinity
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1], ab = b - a, ap = p - a
            let t = clamp((ap * ab).sum() / max((ab * ab).sum(), 1e-9), 0, 1)
            let d = ap - ab * t
            best = min(best, (d * d).sum())
        }
        return best.squareRoot()
    }

    /// Hand-placed-by-rule rural roads per recipe (connect the settlement to the outside world).
    public func ruralRoads() -> [Road] {
        switch terrain.kind {
        case .suburbanPlain:
            // A highway skirting the suburbs on a gentle curve.
            let pts = stride(from: -7_000.0, through: 7_000, by: 100).map { t in SIMD2(t, 2_600 + 600 * sin(t / 3_000)) }
            return [Road(points: pts, roadClass: .highway)]
        case .forestRiver, .mountainValley:
            guard let r = terrain.river else { return [] }
            let off = terrain.kind == .forestRiver ? 140.0 : 75.0
            let pts = r.points.enumerated().map { i, p -> SIMD2<Double> in
                let a = r.points[max(0, i - 1)], b = r.points[min(r.points.count - 1, i + 1)]
                let t = b - a
                let n = SIMD2(t.y, -t.x) / max((t * t).sum().squareRoot(), 1e-9)
                return p + n * off
            }
            return [Road(points: pts, roadClass: .rural)]
        case .coastline:
            let pts = stride(from: -7_000.0, through: 7_000, by: 100).map { t in SIMD2(-250 + 120 * sin(t / 1_300), t) }
            return [Road(points: pts, roadClass: .rural)]
        }
    }

    // MARK: Chunk generation

    public func generateChunk(cx: Int, cy: Int) -> WorldChunk {
        var chunk = WorldChunk(cx: cx, cy: cy)
        let x0 = Double(cx) * Self.chunkSize, y0 = Double(cy) * Self.chunkSize
        let x1 = x0 + Self.chunkSize, y1 = y0 + Self.chunkSize
        func inChunk(_ p: SIMD2<Double>) -> Bool { p.x >= x0 && p.x < x1 && p.y >= y0 && p.y < y1 }

        // Grid streets: emit segments of each street line whose sample points fall in this chunk.
        let corners = [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x0, y1), SIMD2(x1, y1)].map(gridCoord)
        let gu0 = corners.map(\.x).min()! - blockU, gu1 = corners.map(\.x).max()! + blockU
        let gv0 = corners.map(\.y).min()! - blockV, gv1 = corners.map(\.y).max()! + blockV
        for iu in Int((gu0 / blockU).rounded(.down))...Int((gu1 / blockU).rounded(.up)) {
            let cls: RoadClass = iu % 5 == 0 ? .arterial : .local
            appendStreet(&chunk, fixedU: Double(iu) * blockU, range: gv0...gv1, cls: cls, inChunk: inChunk)
        }
        for iv in Int((gv0 / blockV).rounded(.down))...Int((gv1 / blockV).rounded(.up)) {
            let cls: RoadClass = iv % 4 == 0 ? .arterial : .local
            appendStreet(&chunk, fixedV: Double(iv) * blockV, range: gu0...gu1, cls: cls, inChunk: inChunk)
        }
        // Rural roads clipped to the chunk (with one point of overlap for continuity).
        for r in ruralRoads() {
            var run: [SIMD2<Double>] = []
            for (i, p) in r.points.enumerated() {
                let keep = inChunk(p) || (i + 1 < r.points.count && inChunk(r.points[i + 1])) || (i > 0 && inChunk(r.points[i - 1]))
                if keep { run.append(p) } else if run.count > 1 { chunk.roads.append(Road(points: run, roadClass: r.roadClass)); run = [] } else { run = [] }
            }
            if run.count > 1 { chunk.roads.append(Road(points: run, roadClass: r.roadClass)) }
        }

        // Blocks -> parcels -> buildings.
        for iu in Int((gu0 / blockU).rounded(.down))...Int((gu1 / blockU).rounded(.up)) {
            for iv in Int((gv0 / blockV).rounded(.down))...Int((gv1 / blockV).rounded(.up)) {
                let centreG = SIMD2((Double(iu) + 0.5) * blockU, (Double(iv) + 0.5) * blockV)
                let centre = worldCoord(centreG)
                guard inChunk(centre), gridActive(centre) else { continue }
                fillBlock(&chunk, iu: iu, iv: iv)
            }
        }
        // Rural farmsteads along rural roads where density is low but nonzero.
        placeFarms(&chunk, inChunk: inChunk)

        // Vegetation: jittered grid (blue-noise-like), 7 m cells.
        placeTrees(&chunk, x0: x0, y0: y0)
        return chunk
    }

    func appendStreet(_ chunk: inout WorldChunk, fixedU: Double? = nil, fixedV: Double? = nil, range: ClosedRange<Double>,
                      cls: RoadClass, inChunk: (SIMD2<Double>) -> Bool) {
        var run: [SIMD2<Double>] = []
        var t = (range.lowerBound / 20).rounded(.down) * 20
        while t <= range.upperBound {
            let g = fixedU != nil ? SIMD2(fixedU!, t) : SIMD2(t, fixedV!)
            let p = worldCoord(g)
            if inChunk(p) && gridActive(p) {
                if run.isEmpty, let prev = Optional(worldCoord(fixedU != nil ? SIMD2(fixedU!, t - 20) : SIMD2(t - 20, fixedV!))), gridActive(prev) {
                    run.append(prev)
                }
                run.append(p)
            } else if !run.isEmpty {
                if gridActive(p) { run.append(p) }
                if run.count > 1 { chunk.roads.append(Road(points: run, roadClass: cls)) }
                run = []
            }
            t += 20
        }
        if run.count > 1 { chunk.roads.append(Road(points: run, roadClass: cls)) }
    }

    func fillBlock(_ chunk: inout WorldChunk, iu: Int, iv: Int) {
        let h = Hash.combine(terrain.seed, UInt64(bitPattern: Int64(iu)), UInt64(bitPattern: Int64(iv)), 0xB10C)
        var rng = Xoshiro256(seed: h)
        let centre = worldCoord(SIMD2((Double(iu) + 0.5) * blockU, (Double(iv) + 0.5) * blockV))
        let density = settlementDensity(centre.x, centre.y)
        let roll = rng.unit()
        let nearArterial = iu % 5 == 0 || iu % 5 == 4 || iv % 4 == 0 || iv % 4 == 3
        if roll < 0.08 { return } // park: trees only
        if nearArterial && roll < 0.22 && density > 0.6 {
            commercialBlock(&chunk, iu: iu, iv: iv, rng: &rng)
            return
        }
        // Residential: houses along both long sides, facing the street.
        let inset = 4.0 + RoadClass.local.width / 2
        let u0 = Double(iu) * blockU + inset, u1 = Double(iu + 1) * blockU - inset
        let v0 = Double(iv) * blockV + inset, v1 = Double(iv + 1) * blockV - inset
        var lastColour = -1
        for side in 0..<2 {
            var v = v0 + 2
            while v < v1 - 14 {
                let frontage = rng.range(17, 25)
                let w = rng.range(9, 13), d = rng.range(8, 11.5)
                let setback = rng.range(6, 10)
                let u = side == 0 ? u0 + setback + d / 2 : u1 - setback - d / 2
                let gC = SIMD2(u, v + frontage / 2)
                let p = worldCoord(gC)
                if !terrain.isWater(p.x, p.y) && rng.unit() < 0.93 {
                    var ci = Int(rng.next() % UInt64(palette.walls.count))
                    if ci == lastColour { ci = (ci + 1) % palette.walls.count }
                    lastColour = ci
                    let roof: RoofType = rng.unit() < 0.62 ? .gabled : (rng.unit() < 0.8 ? .hipped : .flat)
                    let floors = rng.unit() < 0.3 ? 2.0 : 1.0
                    chunk.buildings.append(Building(
                        center: p, halfSize: SIMD2(d / 2, w / 2), heading: localHeading(p),
                        baseHeight: terrain.height(p.x, p.y), wallHeight: floors * 2.9 + rng.range(0.2, 0.6),
                        roof: roof, roofPitch: rng.range(0.45, 0.8), kind: .house,
                        wallColour: palette.walls[ci] * Float(rng.range(0.9, 1.08)),
                        roofColour: palette.roofs[Int(rng.next() % UInt64(palette.roofs.count))] * Float(rng.range(0.85, 1.1)),
                        variant: UInt32(truncatingIfNeeded: rng.next())))
                }
                v += frontage
            }
        }
    }

    func commercialBlock(_ chunk: inout WorldChunk, iu: Int, iv: Int, rng: inout Xoshiro256) {
        let uC = (Double(iu) + 0.5) * blockU, vC = (Double(iv) + 0.5) * blockV
        let p = worldCoord(SIMD2(uC - 22, vC))
        let heading = localHeading(p)
        let warehouse = rng.unit() < 0.5
        let size = warehouse ? SIMD2(rng.range(22, 30), rng.range(40, 70)) : SIMD2(rng.range(14, 20), rng.range(45, 75))
        chunk.buildings.append(Building(
            center: p, halfSize: size, heading: heading, baseHeight: terrain.height(p.x, p.y),
            wallHeight: warehouse ? rng.range(8, 11) : rng.range(5, 7),
            roof: warehouse ? (rng.unit() < 0.5 ? .sawtooth : .flat) : .flat, roofPitch: 0.3,
            kind: warehouse ? .warehouse : .stripMall,
            wallColour: warehouse ? srgb(184, 182, 176) : palette.walls[Int(rng.next() % UInt64(palette.walls.count))],
            roofColour: srgb(150, 150, 146), variant: UInt32(truncatingIfNeeded: rng.next())))
        // Parking lot in front with instanced cars.
        let lotCentre = worldCoord(SIMD2(uC + 30, vC))
        var cars: [SIMD3<Double>] = []
        let c = cos(heading), s = sin(heading)
        for row in 0..<3 {
            for slot in 0..<14 where rng.unit() < 0.55 {
                let lx = Double(row) * 7 - 7, ly = Double(slot) * 3.0 - 19.5
                let px = lotCentre.x + c * lx - s * ly, py = lotCentre.y + s * lx + c * ly
                cars.append(SIMD3(px, py, heading + (row % 2 == 0 ? 0 : .pi)))
            }
        }
        chunk.parkingLots.append(ParkingLot(center: lotCentre, halfSize: SIMD2(13, 24), heading: heading,
                                            baseHeight: terrain.height(lotCentre.x, lotCentre.y), cars: cars))
    }

    func placeFarms(_ chunk: inout WorldChunk, inChunk: (SIMD2<Double>) -> Bool) {
        for r in ruralRoads() {
            for (i, p) in r.points.enumerated() where i % 9 == 4 && inChunk(p) && !terrain.isAirport(p.x, p.y, margin: 300) {
                var rng = Xoshiro256(seed: Hash.combine(terrain.seed, UInt64(i), 0xFA2))
                guard rng.unit() < 0.45, settlementDensity(p.x, p.y) < 0.32 else { continue }
                let a = r.points[max(0, i - 1)], b = r.points[min(r.points.count - 1, i + 1)]
                let heading = atan2(b.y - a.y, b.x - a.x)
                let side: Double = rng.unit() < 0.5 ? 1 : -1
                let n = SIMD2(-sin(heading), cos(heading)) * side
                let house = p + n * rng.range(28, 40)
                let barn = house + SIMD2(cos(heading), sin(heading)) * rng.range(22, 30) + n * 8
                for (pos, kind) in [(house, BuildingKind.house), (barn, BuildingKind.barn)] {
                    guard !terrain.isWater(pos.x, pos.y), roadDistance(pos.x, pos.y) > 12 else { continue }
                    chunk.buildings.append(Building(
                        center: pos, halfSize: kind == .barn ? SIMD2(9, 14) : SIMD2(5.5, 7), heading: heading,
                        baseHeight: terrain.height(pos.x, pos.y), wallHeight: kind == .barn ? 6 : 5.6,
                        roof: .gabled, roofPitch: kind == .barn ? 0.75 : 0.6, kind: kind,
                        wallColour: kind == .barn ? srgb(132, 46, 36) : palette.walls[Int(rng.next() % UInt64(palette.walls.count))],
                        roofColour: kind == .barn ? srgb(82, 80, 78) : palette.roofs[0], variant: UInt32(i)))
                }
            }
        }
    }

    /// Whether a point is inside (or within `margin` of) any building footprint in the chunk.
    static func insideBuilding(_ p: SIMD2<Double>, _ buildings: [Building], margin: Double) -> Bool {
        for b in buildings {
            let d = p - b.center
            if abs(d.x) > 80 || abs(d.y) > 80 { continue }
            let c = cos(b.heading), s = sin(b.heading)
            let lx = c * d.x + s * d.y, ly = -s * d.x + c * d.y
            if abs(lx) < b.halfSize.x + margin && abs(ly) < b.halfSize.y + margin { return true }
        }
        return false
    }

    func placeTrees(_ chunk: inout WorldChunk, x0: Double, y0: Double) {
        let cell = 7.0
        let n = Int(Self.chunkSize / cell)
        let moistureNoise = GradientNoise2D(seed: Hash.combine(terrain.seed, 0x3015))
        for j in 0..<n {
            for i in 0..<n {
                let h = Hash.int(Int(x0 / cell) + i, Int(y0 / cell) + j, seed: Hash.combine(terrain.seed, 0x7EE))
                var rng = SplitMix64(seed: h)
                let jx = Hash.unit(rng.next()), jy = Hash.unit(rng.next())
                let x = x0 + (Double(i) + jx) * cell, y = y0 + (Double(j) + jy) * cell
                let z = terrain.height(x, y)
                if terrain.isWater(x, y) || terrain.isAirport(x, y) { continue }
                let nrm = terrain.normal(x, y)
                let slope = acos(min(1, nrm.z))
                let moisture = clamp(0.55 + moistureNoise.fbm(x / 700, y / 700, octaves: 3) * 0.6
                                     + (terrain.riverDistance(x, y) < 300 ? 0.2 : 0), 0, 1)
                let biome = BiomeClassifier.classify(ClimateInputs(latitude: latitude, elevation: z, slope: slope,
                                                                   moisture: moisture, distanceToWater: terrain.riverDistance(x, y)))
                let settle = settlementDensity(x, y)
                var density: Double
                switch biome {
                case .temperateForest, .rainforest: density = 0.75
                case .boreal: density = 0.6
                case .wetland: density = 0.25
                case .grassland, .savanna: density = 0.06
                case .tundra: density = 0.02
                default: density = 0
                }
                // Forest edges: patchy clearings and meadows from low-frequency noise.
                density *= smoothstep(-0.25, 0.15, moistureNoise.fbm(x / 1_100 + 9, y / 1_100, octaves: 3))
                if settle > 0.32 { density = 0.085 } // yards and street trees
                if terrain.kind == .suburbanPlain && settle <= 0.32 { density = max(density * 0.5, 0.04) }
                let pick = Hash.unit(rng.next())
                guard pick < density else { continue }
                let road = roadDistance(x, y)
                if road < (settle > 0.32 ? 7.5 : 9) { continue }
                if Self.insideBuilding(SIMD2(x, y), chunk.buildings, margin: 2.5) { continue }
                let conifer = biome == .boreal || z > 1_100 || (biome == .temperateForest && Hash.unit(rng.next()) < 0.3)
                    let tH = conifer ? 11 + Hash.unit(rng.next()) * 12 : 7 + Hash.unit(rng.next()) * 8
                let crown = conifer ? tH * 0.19 : tH * (0.27 + Hash.unit(rng.next()) * 0.08)
                chunk.trees.append(Tree(position: SIMD3(x, y, z), height: tH, crownRadius: crown, conifer: conifer,
                                        colour: treeColour(conifer: conifer, pick: Hash.unit(rng.next()))))
            }
        }
    }

    func treeColour(conifer: Bool, pick: Double) -> LinearRGB {
        if conifer { return pick < 0.5 ? srgb(38, 58, 40) : srgb(46, 66, 44) }
        switch season {
        case .autumn:
            // Restrained autumn palette: ochres and rusts mixed with lingering greens (no rainbow).
            let options = [srgb(146, 96, 50), srgb(164, 124, 62), srgb(124, 74, 44), srgb(88, 100, 52), srgb(104, 112, 56), srgb(170, 140, 74), srgb(78, 92, 48)]
            return options[min(options.count - 1, Int(pick * Double(options.count)))]
        case .winter: return srgb(92, 82, 70)
        default:
            let options = [srgb(66, 98, 46), srgb(80, 110, 52), srgb(58, 86, 44), srgb(94, 118, 58)]
            return options[min(options.count - 1, Int(pick * Double(options.count)))]
        }
    }
}
