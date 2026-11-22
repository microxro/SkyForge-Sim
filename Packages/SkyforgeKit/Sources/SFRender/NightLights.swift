// SKYFORGE — Apache-2.0
// Night lighting: procedural city/street lights from building density, airport lighting with correct
// colours, PAPI logic, flicker-free sprite sizing, and aircraft light cones. Pure Swift (Linux-testable).
import Foundation
import SFMath

/// Light classes with their real-world colours (linear RGB) and relative intensity (arbitrary units, 1 = street lamp).
public enum LightKind: UInt32, Sendable, CaseIterable {
    case runwayEdge = 0, runwayEdgeCaution, threshold, runwayEnd, approach, approachStrobe, centreline, touchdownZone
    case taxiEdge, taxiCentre, papiWhite, papiRed, reil, beacon, streetSodium, streetLED, building, windowWarm, carHead, carTail
    case navRed, navGreen, navWhite, strobe

    /// ICAO Annex 14 / FAA AC 150/5345 colours: edge white (last 600 m yellow), threshold green, end red,
    /// taxi edge blue, taxi centre green, approach white, PAPI white/red.
    public var color: SIMD3<Float> {
        switch self {
        case .runwayEdge, .approach, .centreline, .touchdownZone, .papiWhite, .navWhite, .strobe, .reil, .approachStrobe: SIMD3(1.00, 0.96, 0.90)
        case .runwayEdgeCaution: SIMD3(1.00, 0.72, 0.10)
        case .threshold, .taxiCentre, .navGreen: SIMD3(0.10, 1.00, 0.25)
        case .runwayEnd, .papiRed, .navRed, .carTail: SIMD3(1.00, 0.06, 0.04)
        case .taxiEdge: SIMD3(0.12, 0.25, 1.00)
        case .beacon: SIMD3(0.85, 1.00, 0.85)
        case .streetSodium: SIMD3(1.00, 0.62, 0.20)
        case .streetLED: SIMD3(0.85, 0.93, 1.00)
        case .building: SIMD3(1.00, 0.85, 0.60)
        case .windowWarm: SIMD3(1.00, 0.78, 0.45)
        case .carHead: SIMD3(1.00, 0.95, 0.80)
        }
    }
    public var intensity: Float {
        switch self {
        case .runwayEdge, .runwayEdgeCaution, .threshold, .runwayEnd, .taxiEdge, .taxiCentre: 6
        case .approach, .centreline, .touchdownZone: 9
        case .approachStrobe, .reil, .strobe: 60
        case .papiWhite, .papiRed: 40
        case .beacon: 30
        case .streetSodium, .streetLED: 2.5
        case .building: 1.2
        case .windowWarm: 0.6
        case .carHead, .carTail: 0.8
        case .navRed, .navGreen, .navWhite: 8
        }
    }
    /// Visual radius in metres at which the glow core is drawn.
    public var radius: Float {
        switch self {
        case .papiWhite, .papiRed, .approachStrobe, .reil, .strobe, .beacon: 0.9
        case .runwayEdge, .runwayEdgeCaution, .threshold, .runwayEnd, .approach, .centreline, .touchdownZone: 0.45
        default: 0.3
        }
    }
    /// Half beam angle (degrees) for directional lights; 180 = omnidirectional.
    public var beamHalfAngleDeg: Float {
        switch self {
        case .runwayEdge, .runwayEdgeCaution, .centreline, .touchdownZone: 45   // bidirectional in practice
        case .approach, .threshold, .runwayEnd: 60
        case .papiWhite, .papiRed: 7.5
        case .reil, .approachStrobe: 25
        case .carHead, .carTail: 50
        case .navRed, .navGreen: 55
        default: 180
        }
    }
}

public struct SpriteMetrics: Sendable, Equatable {
    public var pixelSize: Float
    public var energyScale: Float
}

/// Flicker-free sprite sizing: a light smaller than `minPixels` keeps `minPixels` of size and loses energy in
/// proportion to area, so a sub-pixel point never pops between zero and one pixel as the camera moves.
/// A far fade keeps total energy continuous with distance (no popping at the draw-distance edge).
public enum LightSprite {
    /// Maximum sprite size in pixels; the vertex shader applies the same cap.
    public static let maxPixelSize: Float = 128

    /// Reversed infinite-Z depth the light vertex shader outputs: `near / viewZ` (1 at the near plane, 0 at infinity).
    public static func reversedDepth(near: Float, viewZ: Float) -> Float { near / max(viewZ, near) }
    public static func metrics(radiusMetres: Float, distance: Float, focalPixels: Float, minPixels: Float, maxDistance: Float) -> SpriteMetrics {
        let d = max(distance, 0.5)
        let px = 2 * radiusMetres * focalPixels / d
        let size = max(px, minPixels)
        let comp = px >= minPixels ? 1 : (px / minPixels) * (px / minPixels)
        let t = max(0, min(1, (maxDistance - d) / (0.25 * maxDistance)))
        return SpriteMetrics(pixelSize: min(size, maxPixelSize), energyScale: comp * t * t * (3 - 2 * t))
    }

    /// Smooth directional gain: 1 inside 60% of the half-beam, 0 outside, smoothstep between (no hard cone edge).
    public static func beamGain(cosAngle: Float, halfAngleDeg: Float) -> Float {
        if halfAngleDeg >= 180 { return 1 }
        let outer = cos(halfAngleDeg * .pi / 180), inner = cos(halfAngleDeg * 0.6 * .pi / 180)
        let t = max(0, min(1, (cosAngle - outer) / max(1e-4, inner - outer)))
        return t * t * (3 - 2 * t)
    }

    /// Strobe: two short flashes per 1.2 s, phase-offset per light. Deterministic in time (not a flicker source).
    public static func strobe(time: Float, phase: Float) -> Float {
        let t = (time + phase).truncatingRemainder(dividingBy: 1.2)
        let u = t < 0 ? t + 1.2 : t
        return (u < 0.06 || (u >= 0.20 && u < 0.26)) ? 1 : 0
    }
}

/// PAPI: four lamps, white above their setting angle, red below. Returns the number of white lamps (0...4)
/// seen at `angleDeg` above the horizon for a nominal glidepath (default 3.0, bands 2.5/2.83/3.17/3.5).
public enum PAPI {
    public static func settings(glideDeg g: Float = 3.0) -> [Float] { [g - 0.5, g - 0.17, g + 0.17, g + 0.5] }
    public static func whiteCount(angleDeg: Float, glideDeg: Float = 3.0) -> Int {
        settings(glideDeg: glideDeg).reduce(0) { $0 + (angleDeg > $1 ? 1 : 0) }
    }
    /// Smooth per-lamp white fraction over a 0.04 deg transition (the real lamps blend pink between).
    public static func whiteFraction(lamp: Int, angleDeg: Float, glideDeg: Float = 3.0) -> Float {
        let s = settings(glideDeg: glideDeg)[lamp]
        let t = max(0, min(1, (angleDeg - (s - 0.02)) / 0.04)); return t * t * (3 - 2 * t)
    }
    /// Viewing angle (deg) of a lamp from an aircraft position relative to the PAPI unit (metres, +x along the
    /// approach direction away from the unit toward the aircraft, +z up).
    public static func viewAngleDeg(aircraftRelative p: SIMD3<Float>) -> Float {
        atan2(p.z, max(1, (p.x * p.x + p.y * p.y).squareRoot())) * 180 / .pi
    }
}

/// One emitted light for the sprite pass (matches `NTLight` in NightShaders).
public struct NightLight: Sendable, Equatable {
    public var position: SIMD3<Float>    // metres, local ENU origin
    public var kind: LightKind
    public var direction: SIMD3<Float>   // beam axis (unit), ignored when omnidirectional
    public var phase: Float
    public init(position: SIMD3<Float>, kind: LightKind, direction: SIMD3<Float> = SIMD3(0, 0, 1), phase: Float = 0) {
        self.position = position; self.kind = kind; self.direction = direction; self.phase = phase
    }
    /// GPU layout: 4 x float4.
    public func packed() -> [SIMD4<Float>] {
        [SIMD4(position, kind.radius),
         SIMD4(kind.color, kind.intensity),
         SIMD4(direction, cos(kind.beamHalfAngleDeg * .pi / 180)),
         SIMD4(kind.beamHalfAngleDeg >= 180 ? 0 : cos(kind.beamHalfAngleDeg * 0.6 * .pi / 180),
               (kind == .strobe || kind == .approachStrobe || kind == .reil) ? 1 : 0, phase, Float(kind.rawValue))]
    }
}

public enum AirportLighting {
    /// Runway edge, threshold, end, centreline and approach lights. `heading` is the runway course (rad, from
    /// north clockwise); origin is the runway centre; positions are ENU metres.
    public static func runway(centre: SIMD3<Float>, headingRad: Float, length: Float, width: Float, approachSystem: Bool = true) -> [NightLight] {
        let fwd = SIMD3<Float>(sin(headingRad), cos(headingRad), 0), right = SIMD3<Float>(cos(headingRad), -sin(headingRad), 0)
        var out: [NightLight] = []
        let spacing: Float = 60
        let n = max(2, Int(length / spacing))
        let caution: Float = 600
        for i in 0...n {
            let s = -length / 2 + Float(i) * length / Float(n)
            let nearEnd = min(s + length / 2, length / 2 - s) < caution
            for side: Float in [-1, 1] {
                out.append(NightLight(position: centre + fwd * s + right * (side * (width / 2 + 1.5)),
                                      kind: nearEnd ? .runwayEdgeCaution : .runwayEdge, direction: fwd))
            }
            if i % 2 == 0 { out.append(NightLight(position: centre + fwd * s, kind: .centreline, direction: fwd)) }
        }
        for (end, sgn) in [(-length / 2, Float(1)), (length / 2, Float(-1))] {
            for k in 0..<Int(width / 3) {
                let off = (-width / 2 + 1.5) + Float(k) * 3
                let p = centre + fwd * end + right * off
                out.append(NightLight(position: p, kind: .threshold, direction: fwd * sgn))
                out.append(NightLight(position: p - fwd * sgn * 2, kind: .runwayEnd, direction: -fwd * sgn))
            }
        }
        if approachSystem {
            // ALSF-style: centreline bars every 30 m for 900 m, crossbar at 300 m, sequenced strobes.
            for (end, sgn) in [(-length / 2, Float(-1)), (length / 2, Float(1))] {
                for k in 1...30 {
                    let p = centre + fwd * (end + sgn * Float(k) * 30)
                    out.append(NightLight(position: p, kind: .approach, direction: -fwd * sgn))
                    if k % 3 == 0 {
                        out.append(NightLight(position: p + SIMD3(0, 0, 0.3), kind: .approachStrobe, direction: -fwd * sgn, phase: -Float(31 - k) * 0.04))
                    }
                    if k == 10 {
                        for j in -5...5 where j != 0 { out.append(NightLight(position: p + right * Float(j) * 2.5, kind: .approach, direction: -fwd * sgn)) }
                    }
                }
            }
        }
        return out
    }

    /// PAPI bar: four lamps 9 m apart left of the runway, aimed along the approach.
    public static func papi(thresholdPoint: SIMD3<Float>, headingRad: Float, runwayHalfWidth: Float, glideDeg: Float = 3.0) -> [NightLight] {
        let fwd = SIMD3<Float>(sin(headingRad), cos(headingRad), 0), right = SIMD3<Float>(cos(headingRad), -sin(headingRad), 0)
        return (0..<4).map { i in
            NightLight(position: thresholdPoint + fwd * 300 - right * (runwayHalfWidth + 15 + Float(i) * 9) + SIMD3(0, 0, 0.8),
                       kind: .papiWhite, direction: -fwd)
        }
    }
}

/// Procedural urban lighting from a density field in 0...1 (e.g. building footprint coverage or land-use class).
public enum CityLights {
    public struct Cell: Sendable, Equatable { public var x: Int; public var y: Int }

    /// Maps OSM-style land-use names to a light density 0...1. Unknown classes are dark.
    public static func density(landUse: String, buildingCoverage: Float) -> Float {
        let base: Float
        switch landUse {
        case "commercial", "retail": base = 1.0
        case "industrial": base = 0.7
        case "residential": base = 0.55
        case "railway", "construction": base = 0.35
        case "farmland", "forest", "meadow", "grass", "water": base = 0.02
        default: base = 0.15
        }
        return min(1, max(base * 0.6, buildingCoverage) * (0.4 + 0.6 * base))
    }

    /// Lamps for one cell of `size` metres: a street grid whose pitch and lamp spacing follow density, plus
    /// scattered lit windows/signs. Deterministic per (cell, seed); a cell never depends on its neighbours.
    public static func lights(cell: Cell, size: Float = 400, density: Float, seed: UInt64 = 0xC17E, budget: Int = 400) -> [NightLight] {
        guard density > 0.03 else { return [] }
        let h = Hash.int(cell.x, cell.y, seed: seed)
        let pitch: Float = 60 + 80 * (1 - density)
        let spacing: Float = 30 + 25 * (1 - density)
        let origin = SIMD3<Float>(Float(cell.x) * size, Float(cell.y) * size, 0)
        let led = Hash.unit(Hash.mix(h)) > 0.45   // some districts are still sodium
        var out: [NightLight] = []
        var rows = Int(size / pitch)
        rows = max(1, rows)
        outer: for r in 0..<rows {
            let line = (Float(r) + 0.5) * size / Float(rows)
            var s: Float = 0
            while s < size {
                for horizontal in [true, false] {
                    let j = Float(Hash.unit(Hash.combine(h, UInt64(r), UInt64(s), horizontal ? 1 : 2))) * 4
                    if Float(Hash.unit(Hash.combine(h, UInt64(r), UInt64(s), 9))) > density + 0.25 { continue }
                    let p = horizontal ? SIMD3<Float>(s + j, line, 7.5) : SIMD3<Float>(line, s + j, 7.5)
                    out.append(NightLight(position: origin + p, kind: led ? .streetLED : .streetSodium))
                    if out.count >= budget { break outer }
                }
                s += spacing
            }
        }
        let windows = Int(density * 60)
        for i in 0..<windows where out.count < budget {
            let u = Hash.unit(Hash.combine(h, UInt64(i), 77)), v = Hash.unit(Hash.combine(h, UInt64(i), 78)), hgt = Hash.unit(Hash.combine(h, UInt64(i), 79))
            out.append(NightLight(position: origin + SIMD3(Float(u) * size, Float(v) * size, 3 + Float(hgt) * 60 * density),
                                  kind: hgt > 0.7 ? .building : .windowWarm))
        }
        return out
    }

    /// Cells to emit around the camera, nearest first, limited to the tier's budget.
    public static func visibleCells(camera: SIMD2<Float>, size: Float = 400, tier: NightTier) -> [Cell] {
        let side = Int(Double(tier.cityCellBudget).squareRoot())
        let cx = Int((camera.x / size).rounded(.down)), cy = Int((camera.y / size).rounded(.down))
        var cells: [Cell] = []
        for dy in -(side / 2)...(side / 2) { for dx in -(side / 2)...(side / 2) { cells.append(Cell(x: cx + dx, y: cy + dy)) } }
        return cells.sorted { (abs($0.x - cx) + abs($0.y - cy)) < (abs($1.x - cx) + abs($1.y - cy)) }
    }
}

/// Cone light cast by an aircraft landing/taxi light onto the world.
public struct ConeLight: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var innerHalfAngleDeg: Float
    public var outerHalfAngleDeg: Float
    public var range: Float
    public var intensity: Float
    public var color: SIMD3<Float>

    public static func landing(position: SIMD3<Float>, forward: SIMD3<Float>, pitchDownDeg: Float = 4) -> ConeLight {
        let p = pitchDownDeg * .pi / 180
        let up = SIMD3<Float>(0, 0, 1)
        let d = forward * cos(p) - up * sin(p)
        return ConeLight(position: position, direction: d / sqrt(max(1e-6, (d * d).sum())), innerHalfAngleDeg: 6, outerHalfAngleDeg: 14,
                         range: 450, intensity: 90, color: SIMD3(1.0, 0.96, 0.88))
    }
    public static func taxi(position: SIMD3<Float>, forward: SIMD3<Float>) -> ConeLight {
        var c = landing(position: position, forward: forward, pitchDownDeg: 14)
        c.innerHalfAngleDeg = 12; c.outerHalfAngleDeg = 30; c.range = 90; c.intensity = 35
        return c
    }

    /// Irradiance weight (0...intensity) at a world point with surface normal; matches `nt_cone_light` in MSL.
    public func irradiance(at p: SIMD3<Float>, normal n: SIMD3<Float> = SIMD3(0, 0, 1)) -> Float {
        let v = p - position
        let dist = max(1, (v * v).sum().squareRoot())
        let l = v / dist
        let c = (l * direction).sum()
        let outer = cos(outerHalfAngleDeg * .pi / 180), inner = cos(innerHalfAngleDeg * .pi / 180)
        let t = max(0, min(1, (c - outer) / max(1e-4, inner - outer)))
        let cone = t * t * (3 - 2 * t)
        let r = dist / range
        let fall = 1 / (1 + 4 * r * r) * max(0, 1 - r * r)   // smooth cutoff at range
        let ndl = max(0, -(n * l).sum())
        return intensity * cone * fall * ndl / (dist * 0.02 + 1)
    }
}

/// Aircraft position lights at wing tips / tail.
public enum AircraftLights {
    public static func navigation(leftTip: SIMD3<Float>, rightTip: SIMD3<Float>, tail: SIMD3<Float>, strobePhase: Float = 0) -> [NightLight] {
        [NightLight(position: leftTip, kind: .navRed, direction: SIMD3(-1, 0.3, 0)),
         NightLight(position: rightTip, kind: .navGreen, direction: SIMD3(1, 0.3, 0)),
         NightLight(position: tail, kind: .navWhite, direction: SIMD3(0, -1, 0)),
         NightLight(position: leftTip, kind: .strobe, phase: strobePhase),
         NightLight(position: rightTip, kind: .strobe, phase: strobePhase + 0.17)]
    }
}
