// SKYFORGE — Apache-2.0
// Procedural geometry for the SF-1 Trainer (a four-seat, high-wing, single-engine trainer) from
// parametric dimensions. Body axes: x forward, y right, z down, origin at the centre of gravity.
// Every surface is a lofted grid with analytic-quality smooth normals: a superellipse fuselage with a
// raked windscreen and tapering tail cone, a cambered wing with washout and rounded tips, tail surfaces,
// streamlined struts, spring-leaf gear with tyres and wheel fairings, and a spinner. Paint, glazing and
// markings are drawn per pixel from body coordinates (`AircraftLivery`, mirrored in the world shader).
import Foundation
import SFMath

public enum AircraftPart: Int, Sendable {
    /// Fuselage skin: paint with per-pixel glazing, livery and seams.
    case fuselage
    /// Wings, tail, fairings and struts: paint with livery (no glazing).
    case surface
    case glass
    /// Polished or bare metal (spinner, hubs, exhaust).
    case metal
    /// Matt black rubber and trim.
    case tyre
    /// The translucent spinning propeller disc.
    case prop
}

public struct AircraftTriangle: Sendable {
    public var a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>
    public var na: SIMD3<Double>, nb: SIMD3<Double>, nc: SIMD3<Double>
    public var part: AircraftPart
}

public struct AircraftMeshSpec: Sendable {
    public var span = 11.0, rootChord = 1.63, tipChord = 1.13, wingZ = -1.05, wingX = 0.25, dihedral = 1.6 * Double.pi / 180
    public var fuselageLength = 8.2, noseX = 2.55
    public var tailSpan = 3.4, tailChord = 1.05, finHeight = 1.70
    /// Wheel contact height below the CG (the flight model's gear contact points).
    public var gearZ = 1.25
    public init() {}
}

public enum AircraftMesh {
    // MARK: Fuselage profile (shared with the livery so glazing follows the roof line)

    /// Fuselage key sections: x, half width, top z, bottom z, superellipse exponent.
    static let fuselageKeys: [(x: Double, w: Double, top: Double, bot: Double, n: Double)] = [
        (2.50, 0.400, -0.400, 0.300, 2.8), (2.30, 0.480, -0.455, 0.335, 3.0), (1.95, 0.525, -0.500, 0.350, 3.2),
        (1.60, 0.545, -0.525, 0.355, 3.4), (1.36, 0.555, -0.540, 0.355, 3.4), (1.10, 0.560, -0.690, 0.350, 3.4),
        (0.80, 0.560, -0.870, 0.345, 3.5), (0.52, 0.560, -1.015, 0.340, 3.6), (0.00, 0.560, -1.030, 0.335, 3.6),
        (-0.70, 0.555, -1.030, 0.320, 3.6), (-1.40, 0.520, -1.000, 0.285, 3.4), (-1.75, 0.470, -0.880, 0.250, 3.0),
        (-2.05, 0.420, -0.790, 0.215, 2.8), (-3.00, 0.300, -0.700, 0.070, 2.5), (-4.00, 0.195, -0.640, -0.090, 2.3),
        (-5.00, 0.095, -0.590, -0.290, 2.1), (-5.62, 0.030, -0.540, -0.420, 2.0),
    ]

    /// Interpolated fuselage section at `x` (monotone cubic between the keys; clamped at the ends).
    public static func fuselageSection(_ x: Double) -> (w: Double, top: Double, bot: Double, n: Double) {
        let k = fuselageKeys
        if x >= k[0].x { return (k[0].w, k[0].top, k[0].bot, k[0].n) }
        if x <= k[k.count - 1].x { let e = k[k.count - 1]; return (e.w, e.top, e.bot, e.n) }
        var i = 0
        while i < k.count - 2 && x < k[i + 1].x { i += 1 }
        let a = k[i], b = k[i + 1]
        let t = (a.x - x) / (a.x - b.x)
        // Catmull–Rom with clamped neighbours; tangents limited so the section never overshoots a key.
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
        return (cr(p.w, a.w, b.w, q.w), cr(p.top, a.top, b.top, q.top), cr(p.bot, a.bot, b.bot, q.bot), a.n + (b.n - a.n) * t)
    }

    // MARK: Lofting

    /// Emits a grid of points (rows × columns) as triangles with smooth normals from central differences.
    /// `closed`: the columns wrap (tubes). Normals are oriented away from each row's centroid.
    static func loft(_ g: [[SIMD3<Double>]], closed: Bool, part: AircraftPart, into t: inout [AircraftTriangle]) {
        let rows = g.count, cols = g.first?.count ?? 0
        guard rows >= 2, cols >= 3 else { return }
        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        func len(_ a: SIMD3<Double>) -> Double { (a * a).sum().squareRoot() }
        let centroid = g.map { r in r.reduce(SIMD3<Double>.zero, +) / Double(cols) }
        var nrm = [[SIMD3<Double>]](repeating: [SIMD3<Double>](repeating: .zero, count: cols), count: rows)
        for i in 0..<rows {
            for j in 0..<cols {
                let jp = closed ? (j + 1) % cols : min(j + 1, cols - 1), jm = closed ? (j + cols - 1) % cols : max(j - 1, 0)
                let du = g[min(i + 1, rows - 1)][j] - g[max(i - 1, 0)][j]
                let dv = g[i][jp] - g[i][jm]
                var n = cross(du, dv)
                let l = len(n)
                if l > 1e-12 {
                    n /= l
                    let out = g[i][j] - centroid[i]
                    if (n * out).sum() < 0 { n = -n }
                    nrm[i][j] = n
                }
            }
        }
        // Collapsed rows (noses, tips, apexes) take the axis direction away from the neighbouring row.
        for i in 0..<rows {
            for j in 0..<cols where nrm[i][j] == .zero {
                let other = i == 0 ? centroid[min(1, rows - 1)] : centroid[i - 1]
                let d = centroid[i] - other
                let l = len(d)
                nrm[i][j] = l > 1e-9 ? d / l : SIMD3(1, 0, 0)
            }
        }
        let last = closed ? cols : cols - 1
        for i in 0..<(rows - 1) {
            for j in 0..<last {
                let j1 = (j + 1) % cols
                let p00 = g[i][j], p01 = g[i][j1], p10 = g[i + 1][j], p11 = g[i + 1][j1]
                let n00 = nrm[i][j], n01 = nrm[i][j1], n10 = nrm[i + 1][j], n11 = nrm[i + 1][j1]
                func emit(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ na: SIMD3<Double>, _ nb: SIMD3<Double>, _ nc: SIMD3<Double>) {
                    let fn = cross(b - a, c - a)
                    if len(fn) < 1e-12 { return }
                    if (fn * (na + nb + nc)).sum() >= 0 {
                        t.append(AircraftTriangle(a: a, b: b, c: c, na: na, nb: nb, nc: nc, part: part))
                    } else {
                        t.append(AircraftTriangle(a: a, b: c, c: b, na: na, nb: nc, nc: nb, part: part))
                    }
                }
                emit(p00, p01, p11, n00, n01, n11)
                emit(p00, p11, p10, n00, n11, n10)
            }
        }
    }

    /// Superellipse ring in the y–z plane at `x`: half width `w`, top/bottom z, exponent `n`, `seg` points.
    static func ring(x: Double, w: Double, top: Double, bot: Double, n: Double, seg: Int, waterline: Double? = nil) -> [SIMD3<Double>] {
        // The widest point sits 45 % of the way down (cabin sides are fullest below the window line).
        let zc = waterline ?? (top + (bot - top) * 0.55)
        return (0..<seg).map { i in
            let a = Double(i) / Double(seg) * 2 * .pi
            let c = cos(a), s = sin(a)
            let e = 2 / n
            let y = w * (c >= 0 ? 1 : -1) * pow(abs(c), e)
            let h = s >= 0 ? (bot - zc) : (zc - top)
            let z = zc + h * (s >= 0 ? 1 : -1) * pow(abs(s), e)
            return SIMD3(x, y, z)
        }
    }

    /// NACA 4-digit section (camber `m`, camber position `p`, thickness `t`), `n` points per surface,
    /// returned from the trailing edge over the top to the leading edge and back underneath, as (u, v)
    /// with u from the leading edge (0) aft to 1 and v up.
    static func airfoil(m: Double, p: Double, t: Double, n: Int) -> [SIMD2<Double>] {
        func thick(_ u: Double) -> Double {
            5 * t * (0.2969 * u.squareRoot() - 0.126 * u - 0.3516 * u * u + 0.2843 * u * u * u - 0.1036 * u * u * u * u)
        }
        func camber(_ u: Double) -> Double {
            guard m > 0 else { return 0 }
            return u < p ? m / (p * p) * (2 * p * u - u * u) : m / ((1 - p) * (1 - p)) * ((1 - 2 * p) + 2 * p * u - u * u)
        }
        var out: [SIMD2<Double>] = []
        for k in 0...n {                                   // upper surface, trailing → leading edge
            let u = 0.5 * (1 + cos(Double(k) / Double(n) * .pi))
            out.append(SIMD2(u, camber(u) + thick(u)))
        }
        for k in 1..<n {                                   // lower surface, leading → trailing edge
            let u = 0.5 * (1 - cos(Double(k) / Double(n) * .pi))
            out.append(SIMD2(u, camber(u) - thick(u)))
        }
        out.append(SIMD2(1, camber(1) - thick(1)))
        return out
    }

    /// Builds the triangle list (outward-facing, counter-clockwise seen from outside, smooth normals).
    public static func build(_ s: AircraftMeshSpec = AircraftMeshSpec()) -> [AircraftTriangle] {
        var t: [AircraftTriangle] = []
        let seg = 40
        let thrustZ = -0.05

        // Fuselage: 4 cm stations through the cabin, coarser along the tail cone.
        var rows: [[SIMD3<Double>]] = []
        // Cowl face: from the spinner backplate out to the cowl lip.
        for (x, f) in [(2.575, 0.0), (2.572, 0.42), (2.560, 0.72), (2.535, 0.90)] {
            let k = fuselageKeys[0]
            let w = 0.165 + (k.w - 0.165) * f, top = (thrustZ - 0.165) + (k.top - (thrustZ - 0.165)) * f
            let bot = (thrustZ + 0.165) + (k.bot - (thrustZ + 0.165)) * f
            rows.append(ring(x: x, w: w, top: top, bot: bot, n: 2 + (k.n - 2) * f, seg: seg, waterline: thrustZ + (k.top + (k.bot - k.top) * 0.55 - thrustZ) * f))
        }
        var x = fuselageKeys[0].x
        let tailX = fuselageKeys[fuselageKeys.count - 1].x
        while x > tailX {
            let f = fuselageSection(x)
            rows.append(ring(x: x, w: f.w, top: f.top, bot: f.bot, n: f.n, seg: seg))
            x -= x > -2.1 ? 0.045 : 0.14
        }
        let e = fuselageSection(tailX)
        rows.append(ring(x: tailX, w: e.w, top: e.top, bot: e.bot, n: e.n, seg: seg))
        rows.append([SIMD3<Double>](repeating: SIMD3(tailX - 0.035, 0, (e.top + e.bot) / 2), count: seg))
        loft(rows, closed: true, part: .fuselage, into: &t)

        // Spinner: an ogive from the backplate to the tip.
        var spin: [[SIMD3<Double>]] = []
        for k in 0...10 {
            let u = Double(k) / 10
            let r = 0.165 * (1 - u * u).squareRoot() * (1 - 0.25 * u)
            spin.append((0..<24).map { i in
                let a = Double(i) / 24 * 2 * .pi
                return SIMD3(2.575 + 0.30 * u, r * cos(a), thrustZ + r * sin(a))
            })
        }
        loft(spin.reversed(), closed: true, part: .metal, into: &t)

        // Lifting surfaces: rows along the span, columns around the section.
        /// `stations`: (span position −1…1, chord scale, thickness scale). `frame(sp)` gives the leading
        /// edge point, the chord, the incidence (rad, nose up) and the section's unit "down" vector.
        func surface(sections: [SIMD2<Double>], stations: [(sp: Double, chord: Double, thick: Double)],
                     frame: (Double) -> (le: SIMD3<Double>, chord: Double, incidence: Double, down: SIMD3<Double>), part: AircraftPart) {
            var g: [[SIMD3<Double>]] = []
            for st in stations {
                let f = frame(st.sp)
                let c = f.chord * st.chord
                // Shrinking stations keep the same 40 %-chord line (rounded tips).
                let le = f.le - SIMD3(0.40 * (f.chord - c), 0, 0)
                let ci = cos(f.incidence), si = sin(f.incidence)
                g.append(sections.map { p in
                    let u = p.x * c, v = p.y * c * st.thick
                    // Nose-up incidence: the chord line tips down toward the trailing edge.
                    return le + SIMD3(-(u * ci + v * si), 0, 0) + f.down * (u * si - v * ci)
                })
            }
            loft(g, closed: true, part: part, into: &t)
        }

        // Wing: one loft tip to tip. NACA 2412, 1.5° root incidence washing out to −1.5°, constant chord
        // inboard of 2.5 m then tapering, rounded tips.
        let half = s.span / 2
        let wingFoil = airfoil(m: 0.02, p: 0.4, t: 0.12, n: 14)
        var wingStations: [(sp: Double, chord: Double, thick: Double)] = []
        let tipShape: [(Double, Double, Double)] = [(1.0, 0.0, 0.0), (0.9975, 0.42, 0.45), (0.991, 0.70, 0.75), (0.980, 0.90, 0.95), (0.965, 1.0, 1.0)]
        for (sp, c, th) in tipShape { wingStations.append((-sp, max(c, 0.02), max(th, 0.02))) }
        let inner = 22
        for k in 1..<inner { wingStations.append((-0.965 + 1.93 * Double(k) / Double(inner), 1, 1)) }
        for (sp, c, th) in tipShape.reversed() { wingStations.append((sp, max(c, 0.02), max(th, 0.02))) }
        surface(sections: wingFoil, stations: wingStations, frame: { sp in
            let y = sp * half, ay = abs(y)
            let chord = ay < 2.5 ? s.rootChord : s.rootChord + (s.tipChord - s.rootChord) * (ay - 2.5) / (half - 2.5)
            let le = SIMD3(s.wingX - (s.rootChord - chord) * 0.30, y, s.wingZ - ay * tan(s.dihedral))
            let inc = (1.5 - 3.0 * ay / half) * .pi / 180
            let down = SIMD3(0, sin(s.dihedral) * (y >= 0 ? 1.0 : -1.0), cos(s.dihedral))
            return (le, chord, inc, down)
        }, part: .surface)

        // Horizontal tail (symmetric section, tapered, slightly swept).
        let tailFoil = airfoil(m: 0, p: 0.4, t: 0.09, n: 10)
        let tx = s.noseX - s.fuselageLength + 1.12
        var tailStations: [(sp: Double, chord: Double, thick: Double)] = []
        for (sp, c, th) in tipShape { tailStations.append((-sp, max(c, 0.02), max(th, 0.02))) }
        for k in 1..<10 { tailStations.append((-0.965 + 1.93 * Double(k) / 10, 1, 1)) }
        for (sp, c, th) in tipShape.reversed() { tailStations.append((sp, max(c, 0.02), max(th, 0.02))) }
        surface(sections: tailFoil, stations: tailStations, frame: { sp in
            let y = sp * s.tailSpan / 2, f = abs(sp)
            let chord = s.tailChord * (1 - 0.32 * f)
            return (SIMD3(tx - 0.22 * f, y, -0.60), chord, 0, SIMD3(0, 0, 1))
        }, part: .surface)

        // Fin and rudder: swept, with a dorsal fillet running forward along the tail cone.
        let finFoil = airfoil(m: 0, p: 0.4, t: 0.085, n: 10)
        var finRows: [[SIMD3<Double>]] = []
        let finStations: [(Double, Double, Double)] = [(0, 1, 1), (0.12, 1, 1), (0.3, 1, 1), (0.5, 1, 1), (0.7, 1, 1), (0.86, 1, 1), (0.94, 0.97, 1),
                                                       (0.975, 0.88, 0.9), (0.992, 0.68, 0.7), (1.0, 0.36, 0.3)]
        for (sp, cs, th) in finStations {
            let z = -0.50 - s.finHeight * sp
            let chordFull = 1.42 - 0.72 * sp
            let chord = chordFull * cs
            let le = SIMD3(s.noseX - s.fuselageLength + 1.36 - 0.86 * sp - (chordFull - chord) * 0.5, 0, z)
            finRows.append(finFoil.map { p in le + SIMD3(-p.x * chord, p.y * chord * th, 0) })
        }
        loft(finRows, closed: true, part: .surface, into: &t)
        // Dorsal fillet: a thin wedge from the roof of the tail cone up to the fin's leading edge.
        var dorsal: [[SIMD3<Double>]] = []
        for k in 0...8 {
            let u = Double(k) / 8
            let xr = -2.95 - 1.35 * u
            let base = fuselageSection(xr).top + 0.03
            let peak = base - 0.02 - 0.34 * u * u
            let hw = 0.012 + 0.020 * u
            dorsal.append([SIMD3(xr, -hw, base), SIMD3(xr, -hw * 0.4, peak), SIMD3(xr, hw * 0.4, peak), SIMD3(xr, hw, base)])
        }
        loft(dorsal, closed: true, part: .surface, into: &t)

        // Tube with a streamlined (elliptical) section between two points: struts, legs, pipes.
        func tube(_ a: SIMD3<Double>, _ b: SIMD3<Double>, chord: Double, thickness: Double, part: AircraftPart, chordAxis: SIMD3<Double> = SIMD3(1, 0, 0),
                  taper: Double = 1, sides: Int = 12, bow: SIMD3<Double> = .zero) {
            let d = b - a
            let l = (d * d).sum().squareRoot()
            let ax = d / l
            var u = chordAxis - ax * (chordAxis * ax).sum()
            u /= (u * u).sum().squareRoot()
            let v = SIMD3(ax.y * u.z - ax.z * u.y, ax.z * u.x - ax.x * u.z, ax.x * u.y - ax.y * u.x)
            var g: [[SIMD3<Double>]] = []
            let n = bow == .zero ? 2 : 8
            for k in 0...n {
                let f = Double(k) / Double(n)
                let c = a + d * f + bow * (4 * f * (1 - f))
                let sc = 1 + (taper - 1) * f
                g.append((0..<sides).map { i in
                    let ang = Double(i) / Double(sides) * 2 * .pi
                    return c + u * (cos(ang) * chord / 2 * sc) + v * (sin(ang) * thickness / 2 * sc)
                })
            }
            loft(g, closed: true, part: part, into: &t)
        }

        /// Tyre (rounded profile revolved about the axle, along y) with a dished metal hub.
        func wheel(_ c: SIMD3<Double>, radius r: Double, width w: Double) {
            let n = 28
            let profile: [(Double, Double)] = [(-0.50, 0.55), (-0.50, 0.80), (-0.42, 0.93), (-0.25, 0.99), (0, 1.0), (0.25, 0.99), (0.42, 0.93), (0.50, 0.80), (0.50, 0.55)]
            var g: [[SIMD3<Double>]] = []
            for (py, pr) in profile {
                g.append((0..<n).map { i in
                    let a = Double(i) / Double(n) * 2 * .pi
                    return SIMD3(c.x + cos(a) * r * pr, c.y + py * w, c.z + sin(a) * r * pr)
                })
            }
            loft(g, closed: true, part: .tyre, into: &t)
            for side in [-1.0, 1.0] {
                var h: [[SIMD3<Double>]] = []
                for (py, pr) in [(0.50, 0.56), (0.40, 0.50), (0.34, 0.22), (0.44, 0.0)] {
                    h.append((0..<n).map { i in
                        let a = Double(i) / Double(n) * 2 * .pi
                        return SIMD3(c.x + cos(a) * r * max(pr, 0.001), c.y + side * py * w, c.z + sin(a) * r * max(pr, 0.001))
                    })
                }
                loft(h, closed: true, part: .metal, into: &t)
            }
        }

        /// Wheel fairing: a teardrop shell over the wheel, open underneath where the tyre shows.
        func fairing(_ c: SIMD3<Double>, radius r: Double) {
            var g: [[SIMD3<Double>]] = []
            let n = 20
            let fwd = r * 1.75, aft = r * 2.55
            for k in 0...16 {
                let u = Double(k) / 16
                let xr = c.x + fwd - (fwd + aft) * u
                // Teardrop: blunt nose, long tapering tail.
                let sh = pow(sin(.pi * pow(u, 0.62)), 0.75)
                let hw = max(0.004, r * 0.56 * sh), top = c.z - r * 0.1 - r * 1.10 * sh
                let bot = min(c.z + r * 0.52, c.z - r * 0.1 + r * 0.75 * sh)
                g.append(ring(x: xr, w: hw, top: top, bot: max(bot, top + 0.004), n: 2.3, seg: n).map { $0 + SIMD3(0, c.y, 0) })
            }
            loft(g, closed: true, part: .surface, into: &t)
        }

        for side in [-1.0, 1.0] {
            // Wing strut: lower fuselage to the wing's lower skin.
            let wy = 2.45
            tube(SIMD3(0.10, side * 0.535, 0.20), SIMD3(-0.18, side * wy, s.wingZ - wy * tan(s.dihedral) + 0.085),
                 chord: 0.115, thickness: 0.038, part: .surface)
            // Main gear: tapered spring leaf, wheel and fairing.
            let wc = SIMD3(-0.27, side * 1.27, s.gearZ - 0.22)
            tube(SIMD3(-0.27, side * 0.42, 0.30), SIMD3(-0.27, side * 1.17, wc.z - 0.02), chord: 0.15, thickness: 0.036, part: .surface,
                 taper: 0.62, bow: SIMD3(0, side * 0.03, 0.10))
            wheel(wc, radius: 0.22, width: 0.16)
            fairing(wc, radius: 0.22)
        }
        // Nose gear: oleo leg, torque link stub, wheel and fairing.
        let nc = SIMD3(1.52, 0.0, s.gearZ - 0.19)
        tube(SIMD3(1.50, 0, 0.28), SIMD3(1.52, 0, nc.z - 0.16), chord: 0.055, thickness: 0.055, part: .metal)
        tube(SIMD3(1.50, 0, 0.30), SIMD3(1.51, 0, 0.62), chord: 0.085, thickness: 0.085, part: .surface)
        wheel(nc, radius: 0.19, width: 0.13)
        fairing(nc, radius: 0.19)
        // Exhaust stack under the right of the cowl, pitot under the left wing, two blade antennas, beacon.
        tube(SIMD3(1.95, 0.22, 0.30), SIMD3(1.80, 0.24, 0.47), chord: 0.07, thickness: 0.07, part: .metal)
        tube(SIMD3(0.10, -2.75, s.wingZ + 0.02), SIMD3(0.12, -2.75, s.wingZ + 0.17), chord: 0.05, thickness: 0.014, part: .metal)
        tube(SIMD3(0.36, -2.75, s.wingZ + 0.17), SIMD3(0.08, -2.75, s.wingZ + 0.17), chord: 0.02, thickness: 0.02, part: .metal, chordAxis: SIMD3(0, 0, 1))
        for ax in [-0.55, -1.20] {
            tube(SIMD3(ax, 0, -1.07), SIMD3(ax - 0.10, 0, -1.33), chord: 0.11, thickness: 0.012, part: .surface, taper: 0.45)
        }
        tube(SIMD3(-5.13, 0, -0.50 - s.finHeight + 0.01), SIMD3(-5.13, 0, -0.50 - s.finHeight - 0.07), chord: 0.07, thickness: 0.07, part: .glass, taper: 0.6)

        // Propeller disc (spinning blur), drawn translucent.
        let px = s.noseX + 0.15
        let n = 32
        let c = SIMD3(px, 0, thrustZ)
        for i in 0..<n {
            let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
            let p0 = c + SIMD3(0, cos(a0), sin(a0)) * 0.95, p1 = c + SIMD3(0, cos(a1), sin(a1)) * 0.95
            let nf = SIMD3<Double>(1, 0, 0)
            t.append(AircraftTriangle(a: c, b: p0, c: p1, na: nf, nb: nf, nc: nf, part: .prop))
            t.append(AircraftTriangle(a: c, b: p1, c: p0, na: -nf, nb: -nf, nc: -nf, part: .prop))
        }
        return t
    }
}

/// Paint scheme, glazing and markings as a function of body position (x forward, y right, z down).
/// The world shader evaluates the same zones per pixel (`airframeZones` in WorldShaders); this CPU
/// version classifies triangles for the preview renderer and for tests.
public enum AircraftLivery {
    public enum Zone: Sendable, Equatable { case white, navy, orange, black, glass }

    /// Linear albedo of the three paints.
    public static let white = SIMD3<Float>(0.80, 0.80, 0.78), navy = SIMD3<Float>(0.012, 0.032, 0.105), orange = SIMD3<Float>(0.78, 0.20, 0.022)

    /// Centre line (z) of the fuselage stripe at `x`: from the cowl cheek along the cabin to the tail cone.
    public static func stripeZ(_ x: Double) -> Double {
        let t = max(0, min(1, (2.45 - x) / 7.9))
        return -0.03 - 0.24 * t * t * (3 - 2 * t) - 0.03 * t
    }

    /// Zone on the fuselage skin at `p`.
    public static func fuselage(_ p: SIMD3<Double>) -> Zone {
        let roof = AircraftMesh.fuselageSection(p.x).top
        // Windscreen (wraps to the door posts), door and rear side windows, rear window.
        if p.x > 0.56 && p.x < 1.335 && p.z < -0.575 && p.z > roof - 0.02 { return .glass }
        if abs(p.y) > 0.30 && p.z < -0.50 && p.z > -0.945 {
            if p.x > -0.36 && p.x < 0.46 { return .glass }
            if p.x > -1.30 && p.x < -0.50 { return .glass }
        }
        if p.x < -1.47 && p.x > -1.98 && abs(p.y) < 0.33 && p.z < roof + 0.10 { return .glass }
        // Anti-glare panel ahead of the windscreen.
        if p.x > 1.37 && p.x < 2.42 && abs(p.y) < 0.27 && p.z < -0.38 { return .black }
        let d = p.z - stripeZ(p.x)
        let w = 0.075 + 0.05 * max(0, min(1, (2.45 - p.x) / 7.9))
        if abs(p.y) > 0.02 && p.x < 2.45 {
            if abs(d) < w { return .navy }
            if d < -w - 0.03 && d > -w - 0.06 { return .orange }
        }
        return .white
    }

    /// Zone on wings, tail and fairings at `p`.
    public static func surface(_ p: SIMD3<Double>) -> Zone {
        if abs(p.y) > 5.18 && p.z < -0.9 { return .navy }                        // wing tips
        if abs(p.y) > 5.08 && abs(p.y) < 5.14 && p.z < -0.9 { return .orange }
        if abs(p.y) < 0.2 && p.z < -0.95 && p.x < -4.0 {                         // fin sweep
            let d = p.z + 1.55 + 0.75 * (p.x + 4.9)
            if d < 0 { return .navy }
            if d < 0.10 && d > 0.045 { return .orange }
        }
        if abs(p.y) > 1.52 && p.x < -4.3 && p.z > -0.75 && p.z < -0.45 { return .navy }   // tailplane tips
        return .white
    }
}
