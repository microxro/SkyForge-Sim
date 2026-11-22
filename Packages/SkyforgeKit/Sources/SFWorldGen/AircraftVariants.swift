// SKYFORGE — Apache-2.0
// Procedural airframes for the rest of the fleet (SF-C Cruiser, SF-A Aerobat, SF-T1 Jet Trainer, SF-F1
// Interceptor), built from the same lofting helpers as the SF-1 (`AircraftMesh`). Body axes: x forward, y right,
// z down, origin at the centre of gravity. Wheels touch at the flight model's gear height (`gearZ`), and the main
// and nose wheels sit at the gear legs' x and y positions in `AircraftCatalog`, so what you see rolls where the
// physics does. The SF-1 keeps its own mesh and per-pixel livery; these types use plain paint colours per part.
import Foundation
import SFMath

/// Paint colours and extras for a variant (linear albedo).
public struct AircraftVariantStyle: Sendable {
    public var skin: SIMD3<Float>
    public var surface: SIMD3<Float>
    public var canopy: SIMD3<Float>
    public var hasPropeller: Bool
}

public enum AircraftVariants {
    /// Aircraft ids this file can build (the SF-1 is built by `AircraftMesh`).
    public static let ids = ["org.skyforge.sfc", "org.skyforge.sfa", "org.skyforge.sft1", "org.skyforge.sff1"]

    /// Wheel contact height below the CG (m) and wing half span, for tests and callers.
    public static func gearZ(for id: String) -> Double? { spec(for: id)?.gearZ }
    public static func halfSpan(for id: String) -> Double? { spec(for: id)?.wing.halfSpan }

    /// Triangles and paint style for a variant id; nil for the SF-1 and unknown ids.
    public static func build(id: String) -> (triangles: [AircraftTriangle], style: AircraftVariantStyle)? {
        guard let s = spec(for: id) else { return nil }
        var t: [AircraftTriangle] = []
        let seg = 36

        fuselage(s.keys, capLen: s.capLen, step: s.step, seg: seg, into: &t)

        let wingFoil = AircraftMesh.airfoil(m: s.wingCamber, p: 0.4, t: s.wingThickness, n: 14)
        lifting(s.wing, foil: wingFoil, part: .surface, inner: 22, into: &t)
        let tailFoil = AircraftMesh.airfoil(m: 0, p: 0.4, t: 0.08, n: 10)
        lifting(s.htail, foil: tailFoil, part: .surface, inner: 10, into: &t)
        let finFoil = AircraftMesh.airfoil(m: 0, p: 0.4, t: 0.08, n: 10)
        fin(s.fin, foil: finFoil, into: &t)

        canopy(s.canopy, keys: s.keys, into: &t)

        switch s.power {
        case let .prop(x, z, radius, spinner):
            propeller(x: x, z: z, radius: radius, spinner: spinner, into: &t)
        case let .jet(nozzleX, z, radius, intake):
            nozzle(x: nozzleX, z: z, radius: radius, into: &t)
            for side in [-1.0, 1.0] {
                intakeTube(intake, side: side, into: &t)
            }
        }

        gear(s, into: &t)
        return (t, s.style)
    }

    // MARK: Specifications

    typealias Key = (x: Double, w: Double, top: Double, bot: Double, n: Double)

    struct Planform {
        var halfSpan: Double, rootLE: Double, z: Double, rootChord: Double, tipChord: Double
        /// Leading-edge sweep (rad, aft), dihedral (rad, negative = anhedral).
        var sweep: Double, dihedral: Double
        var twistRoot = 0.0, twistTip = 0.0
    }
    struct Fin { var rootLE: Double, baseZ: Double, height: Double, rootChord: Double, tipChord: Double, sweep: Double }
    struct Canopy { var x0: Double, x1: Double, width: Double, height: Double }
    struct Intake { var x0: Double, x1: Double, y: Double, z: Double, hw: Double, hh: Double }
    struct GearSpec {
        var noseX: Double, mainX: Double, mainY: Double
        var noseRadius: Double, mainRadius: Double, noseWidth: Double, mainWidth: Double
        var attachY: Double, attachZ: Double
    }
    enum Power {
        case prop(x: Double, z: Double, radius: Double, spinner: Double)
        case jet(nozzleX: Double, z: Double, radius: Double, intake: Intake)
    }
    struct Spec {
        var keys: [Key]
        var capLen: Double, step: Double
        var wing: Planform, wingThickness: Double, wingCamber: Double
        var htail: Planform
        var fin: Fin
        var canopy: Canopy
        var power: Power
        var gearZ: Double
        var gear: GearSpec
        var style: AircraftVariantStyle
    }

    static func deg(_ d: Double) -> Double { d * .pi / 180 }

    static func spec(for id: String) -> Spec? {
        switch id {
        case "org.skyforge.sfc":
            // Four-seat low-wing tourer: the SF-1's fuselage stretched, a lower cabin roof under a bubble greenhouse.
            let keys: [Key] = AircraftMesh.fuselageKeys.map { k in (k.x * 1.06 + 0.06, k.w * 1.05, max(k.top, -0.80), k.bot, k.n) }
            return Spec(keys: keys, capLen: 0.05, step: 0.07,
                        wing: Planform(halfSpan: 5.1, rootLE: 0.55, z: 0.30, rootChord: 1.75, tipChord: 1.30, sweep: 0, dihedral: deg(4),
                                       twistRoot: deg(1.5), twistTip: deg(-1.0)),
                        wingThickness: 0.12, wingCamber: 0.02,
                        htail: Planform(halfSpan: 1.75, rootLE: -4.35, z: -0.36, rootChord: 1.15, tipChord: 0.75, sweep: deg(12), dihedral: 0),
                        fin: Fin(rootLE: -4.0, baseZ: -0.50, height: 1.75, rootChord: 1.5, tipChord: 0.75, sweep: deg(32)),
                        canopy: Canopy(x0: 1.55, x1: -1.95, width: 0.50, height: 0.30),
                        power: .prop(x: keys[0].x + 0.03, z: -0.05, radius: 1.0, spinner: 0.17),
                        gearZ: 1.30,
                        gear: GearSpec(noseX: 1.55, mainX: -0.35, mainY: 1.35, noseRadius: 0.19, mainRadius: 0.22, noseWidth: 0.13,
                                       mainWidth: 0.16, attachY: 0.45, attachZ: 0.32),
                        style: AircraftVariantStyle(skin: SIMD3(0.74, 0.74, 0.72), surface: SIMD3(0.72, 0.72, 0.70),
                                                    canopy: SIMD3(0.015, 0.022, 0.030), hasPropeller: true))
        case "org.skyforge.sfa":
            // Short, light, low-wing single with a bubble canopy.
            let keys: [Key] = [
                (2.00, 0.34, -0.30, 0.24, 2.6), (1.80, 0.42, -0.37, 0.29, 2.8), (1.40, 0.47, -0.43, 0.31, 3.0),
                (1.00, 0.48, -0.60, 0.31, 3.2), (0.50, 0.48, -0.72, 0.30, 3.2), (0.00, 0.47, -0.74, 0.28, 3.2),
                (-0.60, 0.44, -0.70, 0.24, 3.0), (-1.30, 0.38, -0.62, 0.18, 2.8), (-2.20, 0.28, -0.52, 0.05, 2.5),
                (-3.20, 0.17, -0.45, -0.08, 2.3), (-4.00, 0.08, -0.42, -0.20, 2.1), (-4.45, 0.025, -0.40, -0.28, 2.0)]
            return Spec(keys: keys, capLen: 0.05, step: 0.07,
                        wing: Planform(halfSpan: 4.5, rootLE: 0.45, z: 0.12, rootChord: 1.60, tipChord: 1.15, sweep: 0, dihedral: deg(1)),
                        wingThickness: 0.12, wingCamber: 0,
                        htail: Planform(halfSpan: 1.5, rootLE: -3.2, z: -0.17, rootChord: 1.1, tipChord: 0.65, sweep: deg(15), dihedral: 0),
                        fin: Fin(rootLE: -3.0, baseZ: -0.38, height: 1.55, rootChord: 1.5, tipChord: 0.7, sweep: deg(30)),
                        canopy: Canopy(x0: 1.0, x1: -1.6, width: 0.40, height: 0.32),
                        power: .prop(x: 2.03, z: -0.05, radius: 0.95, spinner: 0.15),
                        gearZ: 1.15,
                        gear: GearSpec(noseX: 1.15, mainX: -0.25, mainY: 1.0, noseRadius: 0.17, mainRadius: 0.20, noseWidth: 0.12,
                                       mainWidth: 0.14, attachY: 0.35, attachZ: 0.30),
                        style: AircraftVariantStyle(skin: SIMD3(0.42, 0.06, 0.03), surface: SIMD3(0.40, 0.055, 0.03),
                                                    canopy: SIMD3(0.015, 0.022, 0.030), hasPropeller: true))
        case "org.skyforge.sft1":
            // Two-seat jet trainer: tandem canopy, side intakes, low swept wing. 9.4 m span.
            let keys: [Key] = [
                (5.20, 0.10, -0.12, 0.10, 2.2), (4.90, 0.26, -0.26, 0.22, 2.4), (4.30, 0.42, -0.42, 0.34, 2.6),
                (3.50, 0.56, -0.56, 0.42, 2.8), (2.60, 0.66, -0.78, 0.46, 3.0), (1.60, 0.70, -0.92, 0.48, 3.2),
                (0.40, 0.70, -0.95, 0.48, 3.2), (-0.80, 0.68, -0.92, 0.46, 3.2), (-2.20, 0.62, -0.82, 0.42, 3.0),
                (-3.60, 0.54, -0.70, 0.34, 2.8), (-4.80, 0.46, -0.62, 0.25, 2.6), (-5.80, 0.36, -0.55, 0.15, 2.4),
                (-6.40, 0.32, -0.50, 0.08, 2.3)]
            return Spec(keys: keys, capLen: 0.30, step: 0.16,
                        wing: Planform(halfSpan: 4.7, rootLE: 0.90, z: 0.28, rootChord: 2.2, tipChord: 1.05, sweep: deg(14), dihedral: deg(2),
                                       twistRoot: deg(1.0), twistTip: deg(-1.0)),
                        wingThickness: 0.10, wingCamber: 0.01,
                        htail: Planform(halfSpan: 2.0, rootLE: -4.6, z: -0.15, rootChord: 1.5, tipChord: 0.75, sweep: deg(30), dihedral: 0),
                        fin: Fin(rootLE: -3.9, baseZ: -0.58, height: 2.1, rootChord: 2.5, tipChord: 1.0, sweep: deg(38)),
                        canopy: Canopy(x0: 3.4, x1: -1.6, width: 0.52, height: 0.50),
                        power: .jet(nozzleX: -6.40, z: -0.21, radius: 0.32,
                                    intake: Intake(x0: 2.5, x1: 1.4, y: 0.70, z: 0.05, hw: 0.17, hh: 0.27)),
                        gearZ: 1.35,
                        gear: GearSpec(noseX: 3.0, mainX: -0.6, mainY: 1.6, noseRadius: 0.24, mainRadius: 0.32, noseWidth: 0.16,
                                       mainWidth: 0.2, attachY: 1.15, attachZ: 0.36),
                        style: AircraftVariantStyle(skin: SIMD3(0.70, 0.70, 0.68), surface: SIMD3(0.68, 0.68, 0.66),
                                                    canopy: SIMD3(0.015, 0.022, 0.030), hasPropeller: false))
        case "org.skyforge.sff1":
            // Single-seat interceptor: 9.4 m span, about 15 m long, cheek intakes, thin swept wing, big fin.
            let keys: [Key] = [
                (7.40, 0.04, -0.08, 0.08, 2.2), (7.05, 0.20, -0.22, 0.16, 2.4), (6.60, 0.38, -0.40, 0.28, 2.6),
                (5.40, 0.54, -0.60, 0.38, 2.8), (4.20, 0.64, -0.80, 0.44, 3.0), (2.80, 0.72, -0.92, 0.46, 3.2),
                (1.00, 0.80, -0.92, 0.48, 3.4), (-1.00, 0.82, -0.86, 0.50, 3.4), (-3.00, 0.76, -0.80, 0.50, 3.4),
                (-4.80, 0.68, -0.76, 0.48, 3.2), (-6.20, 0.62, -0.72, 0.44, 3.0), (-7.00, 0.60, -0.70, 0.42, 2.8)]
            return Spec(keys: keys, capLen: 0.30, step: 0.20,
                        wing: Planform(halfSpan: 4.7, rootLE: 1.40, z: 0.10, rootChord: 5.2, tipChord: 1.4, sweep: deg(38), dihedral: deg(-2)),
                        wingThickness: 0.05, wingCamber: 0.01,
                        htail: Planform(halfSpan: 2.6, rootLE: -4.9, z: 0.10, rootChord: 2.6, tipChord: 1.0, sweep: deg(42), dihedral: deg(-5)),
                        fin: Fin(rootLE: -3.2, baseZ: -0.68, height: 2.5, rootChord: 4.2, tipChord: 1.4, sweep: deg(48)),
                        canopy: Canopy(x0: 5.7, x1: 2.2, width: 0.48, height: 0.46),
                        power: .jet(nozzleX: -7.0, z: -0.14, radius: 0.50,
                                    intake: Intake(x0: 5.2, x1: 3.5, y: 0.70, z: -0.20, hw: 0.22, hh: 0.32)),
                        gearZ: 1.70,
                        gear: GearSpec(noseX: 3.2, mainX: -0.6, mainY: 1.2, noseRadius: 0.30, mainRadius: 0.40, noseWidth: 0.2,
                                       mainWidth: 0.26, attachY: 1.3, attachZ: 0.22),
                        style: AircraftVariantStyle(skin: SIMD3(0.16, 0.18, 0.21), surface: SIMD3(0.14, 0.16, 0.19),
                                                    canopy: SIMD3(0.015, 0.022, 0.030), hasPropeller: false))
        default:
            return nil
        }
    }

    // MARK: Parts

    /// Interpolated fuselage section at `x` (same monotone cubic as the SF-1's, over arbitrary keys).
    static func section(_ k: [Key], _ x: Double) -> Key {
        if x >= k[0].x { return k[0] }
        if x <= k[k.count - 1].x { return k[k.count - 1] }
        var i = 0
        while i < k.count - 2 && x < k[i + 1].x { i += 1 }
        let a = k[i], b = k[i + 1]
        let t = (a.x - x) / (a.x - b.x)
        func cr(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
            var m1 = (p2 - p0) / 2, m2 = (p3 - p1) / 2
            let d = p2 - p1
            if d == 0 { m1 = 0; m2 = 0 } else {
                if m1 / d < 0 { m1 = 0 }; if m2 / d < 0 { m2 = 0 }
                m1 = abs(m1) > 3 * abs(d) ? 3 * d : m1; m2 = abs(m2) > 3 * abs(d) ? 3 * d : m2
            }
            let t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * p1 + (t3 - 2 * t2 + t) * m1 + (-2 * t3 + 3 * t2) * p2 + (t3 - t2) * m2
        }
        let p = k[max(i - 1, 0)], q = k[min(i + 2, k.count - 1)]
        return (x, cr(p.w, a.w, b.w, q.w), cr(p.top, a.top, b.top, q.top), cr(p.bot, a.bot, b.bot, q.bot), a.n + (b.n - a.n) * t)
    }

    static func fuselage(_ keys: [Key], capLen: Double, step: Double, seg: Int, into t: inout [AircraftTriangle]) {
        var rows: [[SIMD3<Double>]] = []
        let k0 = keys[0]
        let zc0 = k0.top + (k0.bot - k0.top) * 0.55
        // Nose cap: a point, then two shrunken rings that round the cowl or the radome.
        rows.append([SIMD3<Double>](repeating: SIMD3(k0.x + capLen, 0, zc0), count: seg))
        for (dx, f) in [(capLen * 0.6, 0.45), (capLen * 0.25, 0.80)] {
            rows.append(AircraftMesh.ring(x: k0.x + dx, w: k0.w * f, top: zc0 + (k0.top - zc0) * f, bot: zc0 + (k0.bot - zc0) * f,
                                          n: 2 + (k0.n - 2) * f, seg: seg))
        }
        let tailX = keys[keys.count - 1].x
        var x = k0.x
        while x > tailX {
            let f = section(keys, x)
            rows.append(AircraftMesh.ring(x: x, w: f.w, top: f.top, bot: f.bot, n: f.n, seg: seg))
            x -= step
        }
        let e = section(keys, tailX)
        rows.append(AircraftMesh.ring(x: tailX, w: e.w, top: e.top, bot: e.bot, n: e.n, seg: seg))
        rows.append([SIMD3<Double>](repeating: SIMD3(tailX - 0.04, 0, (e.top + e.bot) / 2), count: seg))
        AircraftMesh.loft(rows, closed: true, part: .fuselage, into: &t)
    }

    /// A wing or tailplane: one loft tip to tip with rounded tips, sweep, dihedral and twist.
    static func lifting(_ p: Planform, foil: [SIMD2<Double>], part: AircraftPart, inner: Int, into t: inout [AircraftTriangle]) {
        let tip: [(Double, Double, Double)] = [(1.0, 0.0, 0.0), (0.9975, 0.42, 0.45), (0.991, 0.70, 0.75), (0.980, 0.90, 0.95), (0.965, 1.0, 1.0)]
        var st: [(sp: Double, chord: Double, thick: Double)] = []
        for (sp, c, th) in tip { st.append((-sp, max(c, 0.02), max(th, 0.02))) }
        for k in 1..<inner { st.append((-0.965 + 1.93 * Double(k) / Double(inner), 1, 1)) }
        for (sp, c, th) in tip.reversed() { st.append((sp, max(c, 0.02), max(th, 0.02))) }
        var g: [[SIMD3<Double>]] = []
        for s in st {
            let y = s.sp * p.halfSpan, ay = abs(y), f = min(1, ay / p.halfSpan)
            let fullChord = p.rootChord + (p.tipChord - p.rootChord) * f
            let c = fullChord * s.chord
            let sgn = y >= 0 ? 1.0 : -1.0
            // Shrinking stations keep the same 40 %-chord line (rounded tips).
            let leX = p.rootLE - tan(p.sweep) * ay - 0.40 * (fullChord - c)
            let leZ = p.z - ay * tan(p.dihedral)
            let inc = p.twistRoot + (p.twistTip - p.twistRoot) * f
            let ci = cos(inc), si = sin(inc)
            let down = SIMD3(0, sin(p.dihedral) * sgn, cos(p.dihedral))
            g.append(foil.map { q in
                let u = q.x * c, v = q.y * c * s.thick
                return SIMD3(leX - (u * ci + v * si), y, leZ) + down * (u * si - v * ci)
            })
        }
        AircraftMesh.loft(g, closed: true, part: part, into: &t)
    }

    /// Vertical fin: swept, tapered, rounded tip; its root starts inside the fuselage.
    static func fin(_ f: Fin, foil: [SIMD2<Double>], into t: inout [AircraftTriangle]) {
        let stations: [(Double, Double, Double)] = [(0, 1, 1), (0.12, 1, 1), (0.3, 1, 1), (0.5, 1, 1), (0.7, 1, 1), (0.86, 1, 1), (0.94, 0.97, 1),
                                                    (0.975, 0.88, 0.9), (0.992, 0.68, 0.7), (1.0, 0.36, 0.3)]
        var rows: [[SIMD3<Double>]] = []
        for (sp, cs, th) in stations {
            let z = f.baseZ - f.height * sp
            let chordFull = f.rootChord + (f.tipChord - f.rootChord) * sp
            let chord = chordFull * cs
            let leX = f.rootLE - tan(f.sweep) * f.height * sp - (chordFull - chord) * 0.5
            rows.append(foil.map { p in SIMD3(leX - p.x * chord, p.y * chord * th, z) })
        }
        AircraftMesh.loft(rows, closed: true, part: .surface, into: &t)
    }

    /// Glazed canopy: a blunt-nosed dome sitting on the fuselage roof, widest at its base.
    static func canopy(_ c: Canopy, keys: [Key], into t: inout [AircraftTriangle]) {
        var rows: [[SIMD3<Double>]] = []
        let n = 18
        for k in 0...n {
            let s = Double(k) / Double(n)
            let x = c.x0 + (c.x1 - c.x0) * s
            let f = pow(max(0, sin(.pi * pow(s, 0.75))), 0.7)
            let sec = section(keys, x)
            let w = min(c.width, sec.w * 0.85) * f
            let roof = sec.top
            rows.append(AircraftMesh.ring(x: x, w: w, top: roof - c.height * f, bot: roof + 0.10, n: 2.4, seg: 24, waterline: roof + 0.10))
        }
        AircraftMesh.loft(rows, closed: true, part: .glass, into: &t)
    }

    /// Flat disc facing along ±x (dark intake and nozzle interiors).
    static func disc(x: Double, y: Double, z: Double, radius: Double, facing: Double, part: AircraftPart, into t: inout [AircraftTriangle]) {
        let n = 20
        let c = SIMD3(x, y, z), nf = SIMD3<Double>(facing, 0, 0)
        for i in 0..<n {
            let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
            let p0 = c + SIMD3(0, cos(a0), sin(a0)) * radius, p1 = c + SIMD3(0, cos(a1), sin(a1)) * radius
            if facing >= 0 {
                t.append(AircraftTriangle(a: c, b: p0, c: p1, na: nf, nb: nf, nc: nf, part: part))
            } else {
                t.append(AircraftTriangle(a: c, b: p1, c: p0, na: nf, nb: nf, nc: nf, part: part))
            }
        }
    }

    /// Spinner, and the translucent propeller disc.
    static func propeller(x: Double, z: Double, radius: Double, spinner: Double, into t: inout [AircraftTriangle]) {
        var spin: [[SIMD3<Double>]] = []
        for k in 0...10 {
            let u = Double(k) / 10
            let r = spinner * (1 - u * u).squareRoot() * (1 - 0.25 * u)
            spin.append((0..<24).map { i in
                let a = Double(i) / 24 * 2 * .pi
                return SIMD3(x + 0.30 * u, r * cos(a), z + r * sin(a))
            })
        }
        AircraftMesh.loft(spin.reversed(), closed: true, part: .metal, into: &t)
        let c = SIMD3(x + 0.12, 0, z)
        let n = 32
        for i in 0..<n {
            let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
            let p0 = c + SIMD3(0, cos(a0), sin(a0)) * radius, p1 = c + SIMD3(0, cos(a1), sin(a1)) * radius
            let nf = SIMD3<Double>(1, 0, 0)
            t.append(AircraftTriangle(a: c, b: p0, c: p1, na: nf, nb: nf, nc: nf, part: .prop))
            t.append(AircraftTriangle(a: c, b: p1, c: p0, na: -nf, nb: -nf, nc: -nf, part: .prop))
        }
    }

    /// Exhaust nozzle: a short metal tube aft of the fuselage, with a dark interior.
    static func nozzle(x: Double, z: Double, radius r: Double, into t: inout [AircraftTriangle]) {
        var rows: [[SIMD3<Double>]] = []
        for k in 0...4 {
            let u = Double(k) / 4
            let xx = x + 0.06 - 0.80 * u
            let rr = r * (1.0 - 0.10 * u)
            rows.append((0..<24).map { i in
                let a = Double(i) / 24 * 2 * .pi
                return SIMD3(xx, rr * cos(a), z + rr * sin(a))
            })
        }
        AircraftMesh.loft(rows, closed: true, part: .metal, into: &t)
        disc(x: x - 0.55, y: 0, z: z, radius: r * 0.9, facing: -1, part: .tyre, into: &t)
    }

    /// Side or cheek air intake: a short metal tube on one side with a dark throat.
    static func intakeTube(_ i: Intake, side: Double, into t: inout [AircraftTriangle]) {
        var rows: [[SIMD3<Double>]] = []
        let steps = 6
        for k in 0...steps {
            let u = Double(k) / Double(steps)
            let x = i.x0 + (i.x1 - i.x0) * u
            rows.append(AircraftMesh.ring(x: x, w: i.hw, top: i.z - i.hh, bot: i.z + i.hh, n: 2.4, seg: 20, waterline: i.z)
                .map { $0 + SIMD3(0, side * i.y, 0) })
        }
        AircraftMesh.loft(rows, closed: true, part: .metal, into: &t)
        disc(x: i.x0 + (i.x1 - i.x0) * 0.45, y: side * i.y, z: i.z, radius: i.hw * 0.95, facing: 1, part: .tyre, into: &t)
    }

    /// Tube with an elliptical section between two points: gear legs.
    static func tube(_ a: SIMD3<Double>, _ b: SIMD3<Double>, chord: Double, thickness: Double, part: AircraftPart, into t: inout [AircraftTriangle]) {
        let d = b - a
        let l = (d * d).sum().squareRoot()
        guard l > 1e-6 else { return }
        let ax = d / l
        let chordAxis = SIMD3<Double>(1, 0, 0)
        var u = chordAxis - ax * (chordAxis * ax).sum()
        let ul = (u * u).sum().squareRoot()
        if ul < 1e-6 { u = SIMD3(0, 1, 0) } else { u /= ul }
        let v = SIMD3(ax.y * u.z - ax.z * u.y, ax.z * u.x - ax.x * u.z, ax.x * u.y - ax.y * u.x)
        var g: [[SIMD3<Double>]] = []
        let sides = 12
        for k in 0...2 {
            let f = Double(k) / 2
            let c = a + d * f
            g.append((0..<sides).map { i in
                let ang = Double(i) / Double(sides) * 2 * .pi
                return c + u * (cos(ang) * chord / 2) + v * (sin(ang) * thickness / 2)
            })
        }
        AircraftMesh.loft(g, closed: true, part: part, into: &t)
    }

    /// Tyre (rounded profile revolved about the axle, along y) with dished metal hubs.
    static func wheel(_ c: SIMD3<Double>, radius r: Double, width w: Double, into t: inout [AircraftTriangle]) {
        let n = 28
        let profile: [(Double, Double)] = [(-0.50, 0.55), (-0.50, 0.80), (-0.42, 0.93), (-0.25, 0.99), (0, 1.0), (0.25, 0.99), (0.42, 0.93), (0.50, 0.80), (0.50, 0.55)]
        var g: [[SIMD3<Double>]] = []
        for (py, pr) in profile {
            g.append((0..<n).map { i in
                let a = Double(i) / Double(n) * 2 * .pi
                return SIMD3(c.x + cos(a) * r * pr, c.y + py * w, c.z + sin(a) * r * pr)
            })
        }
        AircraftMesh.loft(g, closed: true, part: .tyre, into: &t)
        for side in [-1.0, 1.0] {
            var h: [[SIMD3<Double>]] = []
            for (py, pr) in [(0.50, 0.56), (0.40, 0.50), (0.34, 0.22), (0.44, 0.0)] {
                h.append((0..<n).map { i in
                    let a = Double(i) / Double(n) * 2 * .pi
                    return SIMD3(c.x + cos(a) * r * max(pr, 0.001), c.y + side * py * w, c.z + sin(a) * r * max(pr, 0.001))
                })
            }
            AircraftMesh.loft(h, closed: true, part: .metal, into: &t)
        }
    }

    /// Tricycle gear at the catalog's contact points: oleo legs to wheels whose lowest point is `gearZ`.
    static func gear(_ s: Spec, into t: inout [AircraftTriangle]) {
        let g = s.gear
        let nc = SIMD3(g.noseX, 0.0, s.gearZ - g.noseRadius)
        tube(SIMD3(g.noseX - 0.02, 0, 0.30), SIMD3(g.noseX, 0, nc.z), chord: 0.07, thickness: 0.07, part: .metal, into: &t)
        wheel(nc, radius: g.noseRadius, width: g.noseWidth, into: &t)
        for side in [-1.0, 1.0] {
            let wc = SIMD3(g.mainX, side * g.mainY, s.gearZ - g.mainRadius)
            tube(SIMD3(g.mainX, side * g.attachY, g.attachZ), SIMD3(g.mainX, side * (g.mainY - 0.04), wc.z),
                 chord: 0.14, thickness: 0.05, part: .surface, into: &t)
            wheel(wc, radius: g.mainRadius, width: g.mainWidth, into: &t)
        }
    }
}
