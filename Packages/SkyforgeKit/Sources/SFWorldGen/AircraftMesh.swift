// SKYFORGE — Apache-2.0
// Procedural geometry for the SF-1 Trainer from parametric dimensions (body axes: x forward, y right, z down,
// origin at the centre of gravity). Shared by the CPU preview and (later) the Metal renderer.
import Foundation
import SFMath

public enum AircraftPart: Int, Sendable { case paint, accent, glass, metal, tyre, prop }

public struct AircraftTriangle: Sendable {
    public var a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>
    public var part: AircraftPart
}

public struct AircraftMeshSpec: Sendable {
    public var span = 11.0, rootChord = 1.62, tipChord = 1.22, wingZ = -1.05, wingX = 0.25, dihedral = 1.6 * Double.pi / 180
    public var fuselageLength = 8.2, noseX = 2.55
    public var tailSpan = 3.4, tailChord = 0.95, finHeight = 1.45
    public init() {}
}

public enum AircraftMesh {
    /// Builds the triangle list (outward-facing, counter-clockwise seen from outside).
    public static func build(_ s: AircraftMeshSpec = AircraftMeshSpec()) -> [AircraftTriangle] {
        var t: [AircraftTriangle] = []
        func tri(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ p: AircraftPart) { t.append(AircraftTriangle(a: a, b: b, c: c, part: p)) }
        func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, _ p: AircraftPart) { tri(a, b, c, p); tri(a, c, d, p) }

        // Fuselage: lofted superellipse sections (x, half-width, half-height, centre z).
        let sections: [(x: Double, w: Double, h: Double, z: Double)] = [
            (s.noseX + 0.25, 0.05, 0.05, -0.05), (s.noseX, 0.28, 0.28, -0.05), (s.noseX - 0.6, 0.50, 0.48, -0.15),
            (s.noseX - 1.5, 0.56, 0.64, -0.35), (s.noseX - 2.6, 0.55, 0.66, -0.40), (s.noseX - 3.6, 0.44, 0.52, -0.42),
            (s.noseX - 5.0, 0.26, 0.34, -0.52), (s.noseX - s.fuselageLength + 0.5, 0.12, 0.20, -0.62), (s.noseX - s.fuselageLength, 0.04, 0.10, -0.66),
        ]
        let seg = 16
        func ring(_ k: Int) -> [SIMD3<Double>] {
            let sec = sections[k]
            return (0..<seg).map { i in
                let a = Double(i) / Double(seg) * 2 * .pi
                let c = cos(a), sn = sin(a)
                let e = 0.6 // superellipse exponent (boxier cabin)
                let y = sec.w * (c >= 0 ? 1 : -1) * pow(abs(c), e)
                let z = sec.z + sec.h * (sn >= 0 ? 1 : -1) * pow(abs(sn), e)
                return SIMD3(sec.x, y, z)
            }
        }
        for k in 0..<(sections.count - 1) {
            let r0 = ring(k), r1 = ring(k + 1)
            for i in 0..<seg {
                let j = (i + 1) % seg
                // Window band on the cabin sides/top between sections 2–4.
                let angle = Double(i) / Double(seg) * 2 * .pi
                let upperSide = sin(angle) < -0.15 && abs(cos(angle)) > 0.2
                let part: AircraftPart = (k >= 2 && k <= 3 && upperSide) ? .glass : (k == 1 && false ? .metal : .paint)
                quad(r0[i], r0[j], r1[j], r1[i], part)
            }
        }
        // Accent cheatline: thin band along the lower fuselage sides.
        for k in 1..<(sections.count - 2) {
            let a0 = sections[k], a1 = sections[k + 1]
            for side in [-1.0, 1.0] {
                let p0 = SIMD3(a0.x, side * (a0.w + 0.012), a0.z + 0.10), p1 = SIMD3(a1.x, side * (a1.w + 0.012), a1.z + 0.10)
                let q0 = SIMD3(a0.x, side * (a0.w + 0.012), a0.z + 0.22), q1 = SIMD3(a1.x, side * (a1.w + 0.012), a1.z + 0.22)
                if side > 0 { quad(p1, p0, q0, q1, .accent) } else { quad(p0, p1, q1, q0, .accent) }   // outward normals
            }
        }

        // Lifting surface with a symmetric 12% airfoil section, swept/tapered between root and tip.
        func surface(root: SIMD3<Double>, tip: SIMD3<Double>, rootChord: Double, tipChord: Double, thickness: Double,
                     vertical: Bool, part: AircraftPart) {
            let stations: [Double] = [0, 0.05, 0.15, 0.3, 0.5, 0.7, 0.85, 1]
            func thick(_ u: Double) -> Double { // NACA 00xx half-thickness
                5 * thickness * (0.2969 * u.squareRoot() - 0.126 * u - 0.3516 * u * u + 0.2843 * u * u * u - 0.1036 * u * u * u * u)
            }
            func point(_ span: Double, _ u: Double, _ side: Double) -> SIMD3<Double> {
                let le = root + (tip - root) * span
                let chord = rootChord + (tipChord - rootChord) * span
                let th = thick(u) * chord * side
                return vertical ? SIMD3(le.x - u * chord, le.y + th, le.z) : SIMD3(le.x - u * chord, le.y, le.z - th)
            }
            for side in [1.0, -1.0] {
                for k in 0..<(stations.count - 1) {
                    let u0 = stations[k], u1 = stations[k + 1]
                    let a = point(0, u0, side), b = point(0, u1, side), c = point(1, u1, side), d = point(1, u0, side)
                    // Winding so normals face outward on both faces.
                    let outwardUp = vertical ? (tip.z < root.z) == (side > 0) : (tip.y > root.y) == (side > 0)
                    if outwardUp { quad(a, d, c, b, part) } else { quad(a, b, c, d, part) }
                }
            }
            // Tip cap
            for k in 0..<(stations.count - 1) {
                tri(point(1, stations[k], 1), point(1, stations[k + 1], 1), point(1, stations[k + 1], -1), part)
                tri(point(1, stations[k], 1), point(1, stations[k + 1], -1), point(1, stations[k], -1), part)
            }
        }
        let tipRise = s.span / 2 * tan(s.dihedral)
        for side in [-1.0, 1.0] {
            surface(root: SIMD3(s.wingX, 0, s.wingZ), tip: SIMD3(s.wingX - 0.1, side * s.span / 2, s.wingZ - tipRise),
                    rootChord: s.rootChord, tipChord: s.tipChord, thickness: 0.12, vertical: false, part: .paint)
            // Accent wing tips
            surface(root: SIMD3(s.wingX - 0.1, side * (s.span / 2 - 0.5), s.wingZ - tipRise * 0.9),
                    tip: SIMD3(s.wingX - 0.1, side * (s.span / 2 + 0.01), s.wingZ - tipRise - 0.002),
                    rootChord: s.tipChord + 0.01, tipChord: s.tipChord + 0.01, thickness: 0.125, vertical: false, part: .accent)
            // Horizontal tail
            let tx = s.noseX - s.fuselageLength + 1.05
            surface(root: SIMD3(tx, 0, -0.60), tip: SIMD3(tx - 0.15, side * s.tailSpan / 2, -0.60),
                    rootChord: s.tailChord, tipChord: s.tailChord * 0.7, thickness: 0.09, vertical: false, part: .paint)
            // Wing strut
            let a = SIMD3(s.wingX - 0.5, side * 0.55, 0.05), b = SIMD3(s.wingX - 0.55, side * 2.5, s.wingZ - 2.5 * tan(s.dihedral) + 0.05)
            let o = SIMD3(0.06, 0, 0.0)
            quad(a, b, b + o, a + o, .metal); quad(a + o, b + o, b, a, .metal)
        }
        // Vertical fin (swept)
        let fx = s.noseX - s.fuselageLength + 1.25
        surface(root: SIMD3(fx, 0, -0.85), tip: SIMD3(fx - 0.75, 0, -0.85 - s.finHeight), rootChord: 1.3, tipChord: 0.65,
                thickness: 0.10, vertical: true, part: .paint)
        // Fixed tricycle gear: legs and wheels (octagonal discs).
        func wheel(_ c: SIMD3<Double>, _ r: Double, _ w: Double) {
            let n = 10
            for i in 0..<n {
                let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
                let p0 = SIMD3(c.x + cos(a0) * r, c.y, c.z + sin(a0) * r), p1 = SIMD3(c.x + cos(a1) * r, c.y, c.z + sin(a1) * r)
                let dy = SIMD3(0, w / 2, 0)
                quad(p0 - dy, p1 - dy, p1 + dy, p0 + dy, .tyre)
                tri(c + dy, p0 + dy, p1 + dy, .tyre); tri(c - dy, p1 - dy, p0 - dy, .tyre)
            }
        }
        for (x, y) in [(1.30, 0.0), (-0.30, -1.10), (-0.30, 1.10)] {
            wheel(SIMD3(x, y, 1.05), 0.2, 0.14)
            let top = SIMD3(x, y * 0.4, 0.15), bot = SIMD3(x, y, 0.95)
            quad(top, bot, bot + SIMD3(0.05, 0, 0), top + SIMD3(0.05, 0, 0), .metal)
            quad(top + SIMD3(0.05, 0, 0), bot + SIMD3(0.05, 0, 0), bot, top, .metal)
        }
        // Propeller disc (spinning blur) and spinner.
        let px = s.noseX + 0.18
        let n = 20
        for i in 0..<n {
            let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
            let c = SIMD3(px, 0, -0.05)
            let p0 = c + SIMD3(0, cos(a0), sin(a0)) * 0.95, p1 = c + SIMD3(0, cos(a1), sin(a1)) * 0.95
            tri(c, p0, p1, .prop); tri(c, p1, p0, .prop)
        }
        return t
    }
}
