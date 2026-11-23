// SKYFORGE — Apache-2.0
// Original-world airports: runway, taxiways, apron and buildings laid out around a centre, with a pad
// elevation for the terrain recipe to flatten. Anchored airports keep their given position and elevation.
// Deterministic and free of Apple frameworks, so it runs in Linux tests.
import Foundation
import SFMath

public enum AirportKind: Int, Sendable, Codable, CaseIterable {
    case hub, regional, generalAviation, bushStrip, mountainStrip, seaplaneBase

    /// Runway length range used when a procedural airport is placed (metres). Seaplane: water lane length.
    public var lengthRange: ClosedRange<Double> {
        switch self {
        case .hub: return 3_000...3_600
        case .regional: return 1_500...2_000
        case .generalAviation: return 800...1_100
        case .bushStrip: return 380...560
        case .mountainStrip: return 500...800
        case .seaplaneBase: return 700...1_000
        }
    }

    /// Runway (or lane) width, metres.
    public var width: Double {
        switch self {
        case .hub: return 45
        case .regional: return 30
        case .generalAviation: return 23
        case .bushStrip, .mountainStrip: return 18
        case .seaplaneBase: return 60
        }
    }

    /// Distance band from a settlement centre where a procedural airport is searched for, metres.
    public var searchRange: ClosedRange<Double> {
        switch self {
        case .hub: return 4_000...11_000
        case .regional: return 3_000...7_000
        case .generalAviation: return 2_000...6_000
        case .bushStrip: return 1_500...6_000
        case .mountainStrip: return 2_000...7_000
        case .seaplaneBase: return 300...6_000
        }
    }

    /// Largest height spread allowed under a procedural pad, metres.
    public var flatness: Double {
        switch self {
        case .hub: return 6
        case .regional, .generalAviation: return 8
        case .bushStrip: return 10
        case .mountainStrip: return 12
        case .seaplaneBase: return 0
        }
    }

    /// Taxiway offset from the runway centreline, metres. Nil when there is no parallel taxiway.
    var taxiwayOffset: Double? {
        switch self {
        case .hub: return 190
        case .regional: return 130
        case .generalAviation: return 110
        case .bushStrip, .mountainStrip, .seaplaneBase: return nil
        }
    }
}

public enum AirportSurfaceKind: Int, Sendable, Codable { case taxiway, apron, waterLane }

public enum AirportBuildingKind: Int, Sendable, Codable { case terminal, hangar, tower, fuelFarm }

public struct AirportSurface: Sendable, Equatable {
    public var corners: [SIMD2<Double>]   // counter-clockwise, local ENU metres
    public var kind: AirportSurfaceKind
}

public struct AirportBuilding: Sendable, Equatable {
    public var centre: SIMD2<Double>
    /// x along the runway heading, y across it (metres).
    public var halfSize: SIMD2<Double>
    /// Radians from east, aligned with the runway.
    public var heading: Double
    public var ground: Double
    public var wallHeight: Double
    public var kind: AirportBuildingKind
}

public struct WaterLane: Sendable, Equatable {
    public var start: SIMD2<Double>
    public var end: SIMD2<Double>
}

/// A fixed airport from the world data (for example `world.json`). Its position and elevation never move.
public struct AnchorAirport: Sendable, Equatable {
    public var id: String
    public var name: String
    public var centre: SIMD2<Double>   // metres
    public var elevation: Double       // pad elevation, metres
    public var runwayLength: Double    // metres; water lane length for seaplane bases
    public var kind: AirportKind
    public var paved: Bool
    public init(id: String, name: String, centre: SIMD2<Double>, elevation: Double, runwayLength: Double,
                kind: AirportKind, paved: Bool) {
        self.id = id; self.name = name; self.centre = centre; self.elevation = elevation
        self.runwayLength = runwayLength; self.kind = kind; self.paved = paved
    }
}

public struct AirportLayout: Sendable {
    public var id: String
    public var name: String
    public var kind: AirportKind
    public var centre: SIMD2<Double>
    public var paved: Bool
    /// Elevation the terrain recipe should flatten the whole footprint to (metres).
    public var padElevation: Double
    public var runways: [RunwaySpec]
    public var surfaces: [AirportSurface]
    public var buildings: [AirportBuilding]
    public var waterLane: WaterLane?
    public var contentHash: UInt64
}

extension OpenWorldPlanner {

    /// Layout for a fixed airport. Heading comes from the id, so a rebuild gives the same runway.
    public func layout(for anchor: AnchorAirport) -> AirportLayout {
        var h: UInt64 = 0x4149_5250
        for b in anchor.id.utf8 { h = Hash.mix(h ^ UInt64(b)) }
        let heading = snapDegrees(Hash.unit(Hash.combine(h, 7)) * 360) * Double.pi / 180
        return buildLayout(id: anchor.id, name: anchor.name, kind: anchor.kind, centre: anchor.centre,
                           heading: heading, length: anchor.runwayLength, paved: anchor.paved,
                           padElevation: anchor.elevation, seed: h)
    }

    /// Procedural airport of a kind near a centre. Nil when no flat, dry pad is found within 160 tries.
    public func airport(_ kind: AirportKind, near centre: SIMD2<Double>, seed: UInt64, id: String, name: String) -> AirportLayout? {
        if kind == .seaplaneBase { return seaplane(near: centre, seed: seed, id: id, name: name) }
        var rng = Xoshiro256(seed: seed)
        let paved = kind == .hub || kind == .regional || kind == .generalAviation
        for _ in 0..<160 {
            let d = rng.range(kind.searchRange.lowerBound, kind.searchRange.upperBound)
            let a = rng.range(0, 2 * Double.pi)
            let c = centre + SIMD2<Double>(cos(a), sin(a)) * d
            let heading = snapDegrees(rng.range(0, 360)) * Double.pi / 180
            let length = rng.range(kind.lengthRange.lowerBound, kind.lengthRange.upperBound)
            guard isFlatPad(c, heading: heading, length: length, kind: kind) else { continue }
            let pad = padMean(c, heading: heading, length: length)
            return buildLayout(id: id, name: name, kind: kind, centre: c, heading: heading, length: length,
                               paved: paved, padElevation: pad, seed: seed)
        }
        return nil
    }

    /// Airports for one procedural settlement, chosen by tier and hash.
    public func airports(for settlement: SettlementPlan) -> [AirportLayout] {
        var out: [AirportLayout] = []
        let s = settlement.site.seed
        let c = settlement.site.centre
        let tag = settlement.name
        func roll(_ k: UInt64) -> Double { Hash.unit(Hash.combine(s, k)) }
        switch settlement.site.tier {
        case .metropolis, .city:
            if roll(21) < 0.9, let a = airport(.hub, near: c, seed: Hash.combine(s, 22), id: "P-\(tag)-H", name: "\(tag) International") {
                out.append(a)
            }
        case .town:
            if roll(23) < 0.6, let a = airport(.regional, near: c, seed: Hash.combine(s, 24), id: "P-\(tag)-R", name: "\(tag) Regional") {
                out.append(a)
            }
        case .village:
            if roll(25) < 0.5, let a = airport(.bushStrip, near: c, seed: Hash.combine(s, 26), id: "P-\(tag)-B", name: "\(tag) Strip") {
                out.append(a)
            }
        case .hamlet:
            break
        }
        if roll(27) < 0.3, let a = airport(.seaplaneBase, near: c, seed: Hash.combine(s, 28), id: "P-\(tag)-S", name: "\(tag) Water Base") {
            out.append(a)
        }
        return out
    }

    // MARK: Builders

    /// Places runway, taxiways, apron and buildings for a paved or unpaved strip. Headings are north-based (rad).
    func buildLayout(id: String, name: String, kind: AirportKind, centre c: SIMD2<Double>, heading h: Double,
                     length: Double, paved: Bool, padElevation: Double, seed: UInt64) -> AirportLayout {
        let deg = normaliseDegrees(h * 180 / Double.pi)
        let hE = Double.pi / 2 - h                              // east-based heading of the runway axis
        let dir = SIMD2<Double>(cos(hE), sin(hE))
        let perp = SIMD2<Double>(cos(hE + Double.pi / 2), sin(hE + Double.pi / 2))
        let side: Double = Hash.unit(Hash.combine(seed, 9)) < 0.5 ? 1 : -1
        let halfL = length / 2
        let spec = RunwaySpec(threshold: c - dir * halfL, heading: h, length: length, width: kind.width,
                              lowDesignator: RunwaySpec.designator(headingDegrees: deg),
                              highDesignator: RunwaySpec.designator(headingDegrees: normaliseDegrees(deg + 180)))
        var surfaces: [AirportSurface] = []
        var buildings: [AirportBuilding] = []
        let pad = padElevation

        func building(_ at: SIMD2<Double>, _ hs: SIMD2<Double>, _ wall: Double, _ k: AirportBuildingKind) {
            buildings.append(AirportBuilding(centre: at, halfSize: hs, heading: hE, ground: pad,
                                             wallHeight: wall, kind: k))
        }

        if let off = kind.taxiwayOffset, paved {
            let offT = off * side
            surfaces.append(AirportSurface(corners: owRectCorners(c + perp * offT, hE, SIMD2(halfL - 40, 12)),
                                           kind: .taxiway))
            for e in [-1.0, 1.0] {
                let at = c + dir * (e * (halfL - 80)) + perp * (offT / 2)
                surfaces.append(AirportSurface(corners: owRectCorners(at, hE + Double.pi / 2, SIMD2(abs(offT) / 2, 12)),
                                               kind: .taxiway))
            }
            let apronHalf: SIMD2<Double> = kind == .hub ? SIMD2(260, 70) : (kind == .regional ? SIMD2(120, 45) : SIMD2(60, 30))
            let apronAt = c - dir * (halfL * 0.3) + perp * (offT + side * (kind == .hub ? 110 : 70))
            surfaces.append(AirportSurface(corners: owRectCorners(apronAt, hE, apronHalf), kind: .apron))
            if kind == .hub || kind == .regional {
                let termHalf: SIMD2<Double> = kind == .hub ? SIMD2(200, 22) : SIMD2(90, 14)
                let termAt = apronAt + perp * (side * (apronHalf.y + termHalf.y + 4))
                building(termAt, termHalf, kind == .hub ? 16 : 10, .terminal)
            }
            building(c - dir * (halfL * 0.55) - perp * (side * 60), SIMD2(30, 18), 12, .hangar)
            if kind == .hub {
                building(c + dir * (halfL * 0.3) - perp * (side * 90), SIMD2(8, 8), 36, .tower)
                building(c - dir * (halfL * 0.55) - perp * (side * 120), SIMD2(12, 10), 6, .fuelFarm)
            }
            if kind == .generalAviation {
                building(c + dir * (halfL * 0.6) - perp * (side * 60), SIMD2(12, 10), 6, .fuelFarm)
            }
        } else if kind != .seaplaneBase {
            building(c - perp * (side * 60), SIMD2(14, 8), 6, .hangar)
        }

        var lane: WaterLane? = nil
        var runways: [RunwaySpec] = [spec]
        if kind == .seaplaneBase {
            runways = []
            lane = WaterLane(start: c - dir * halfL, end: c + dir * halfL)
        }
        var fnv = FNV1a()
        fnv.add(c.x); fnv.add(c.y); fnv.add(h); fnv.add(length); fnv.add(pad)
        for s in surfaces { for p in s.corners { fnv.add(p.x); fnv.add(p.y) } }
        for b in buildings { fnv.add(b.centre.x); fnv.add(b.centre.y); fnv.add(b.wallHeight) }
        return AirportLayout(id: id, name: name, kind: kind, centre: c, paved: paved, padElevation: pad,
                             runways: runways, surfaces: surfaces, buildings: buildings, waterLane: lane,
                             contentHash: fnv.value)
    }

    /// Water base: nearest water reached by ray search from the centre, with a lane of water along it.
    func seaplane(near centre: SIMD2<Double>, seed: UInt64, id: String, name: String) -> AirportLayout? {
        var rng = Xoshiro256(seed: seed)
        let kind = AirportKind.seaplaneBase
        for _ in 0..<40 {
            let a = rng.range(0, 2 * Double.pi)
            let d = SIMD2<Double>(cos(a), sin(a))
            var t = kind.searchRange.lowerBound
            while t <= kind.searchRange.upperBound {
                let p = centre + d * t
                if terrain.isWater(p.x, p.y) {
                    let heading = snapDegrees(rng.range(0, 360)) * Double.pi / 180
                    let length = rng.range(kind.lengthRange.lowerBound, kind.lengthRange.upperBound)
                    let hE = Double.pi / 2 - heading
                    let dir = SIMD2<Double>(cos(hE), sin(hE))
                    var clear = true
                    for k in 0...20 {
                        let s = -length / 2 + Double(k) * length / 20
                        let q = p + dir * s
                        if !terrain.isWater(q.x, q.y) { clear = false; break }
                    }
                    if clear {
                        return buildLayout(id: id, name: name, kind: kind, centre: p, heading: heading, length: length,
                                           paved: false, padElevation: terrain.height(p.x, p.y), seed: seed)
                    }
                    break
                }
                t += 100
            }
        }
        return nil
    }

    /// True when the footprint is dry and the ground spread stays within the kind's flatness limit.
    func isFlatPad(_ c: SIMD2<Double>, heading h: Double, length: Double, kind: AirportKind) -> Bool {
        let dir = SIMD2<Double>(sin(h), cos(h))
        let perp = SIMD2<Double>(cos(h), -sin(h))
        let halfL = length / 2 + 150
        let halfW = (kind == .bushStrip || kind == .mountainStrip) ? 60 : 340
        var lo = Double.infinity, hi = -Double.infinity
        var s = -halfL
        while s <= halfL {
            var t = -halfW
            while t <= halfW {
                let p = c + dir * s + perp * t
                if terrain.isWater(p.x, p.y) { return false }
                let z = terrain.height(p.x, p.y)
                lo = min(lo, z); hi = max(hi, z)
                t += 50
            }
            s += 50
        }
        return hi - lo <= kind.flatness
    }

    /// Mean ground height along the runway centreline.
    func padMean(_ c: SIMD2<Double>, heading h: Double, length: Double) -> Double {
        let dir = SIMD2<Double>(sin(h), cos(h))
        var sum = 0.0
        for k in 0...8 {
            let s = -length / 2 + Double(k) * length / 8
            let p = c + dir * s
            sum += terrain.height(p.x, p.y)
        }
        return sum / 9
    }
}

// MARK: - Helpers (file-private)

fileprivate func snapDegrees(_ d: Double) -> Double {
    normaliseDegrees((d / 5).rounded() * 5)
}

fileprivate func normaliseDegrees(_ d: Double) -> Double {
    var x = d.truncatingRemainder(dividingBy: 360)
    if x < 0 { x += 360 }
    return x
}

/// Corners of a rectangle with half-size `hs` (x along the east-based heading), counter-clockwise.
fileprivate func owRectCorners(_ c: SIMD2<Double>, _ heading: Double, _ hs: SIMD2<Double>) -> [SIMD2<Double>] {
    let u = SIMD2<Double>(cos(heading), sin(heading)) * hs.x
    let v = SIMD2<Double>(-sin(heading), cos(heading)) * hs.y
    return [c - u - v, c + u - v, c + u + v, c - u + v]
}
