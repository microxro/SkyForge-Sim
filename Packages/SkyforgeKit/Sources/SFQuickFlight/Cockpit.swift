// SKYFORGE — Apache-2.0
// SF-1 Trainer cockpit for the in-cockpit view: a simple 3D panel (glare shield, panel face, side
// sills, windscreen pillars, headliner, yoke) in body axes and the SF-1000 PFD screen rectangle.
// The exterior airframe is drawn too (back faces discarded) so the cowling, wings and struts show.
import Foundation
import SFPreview

public enum Cockpit {
    /// Pilot eye point, left seat (body axes: x forward, y right, z down; origin at the CG).
    public static let eye = SIMD3<Double>(0.22, -0.26, -0.80)
    /// 7° (was 5°): the yoke tops and the lower panel come into the frame, as a trainer's left-seat view is
    /// usually framed (art round 32: everything below the gauges sat outside the 55° view).
    public static let lookDown = 7.0 * Double.pi / 180

    static let panelX = 1.12, panelTop = -0.40, panelBottom = 0.06, halfWidth = 0.54
    static let screenTilt = 12.0 * Double.pi / 180

    /// PFD corners as the pilot sees them: top-left, top-right, bottom-right, bottom-left (body axes).
    public static var pfdCorners: [SIMD3<Double>] {
        let c = SIMD3(panelX - 0.006, eye.y, -0.235)
        let w = 0.29, h = w * 10 / 16
        let up = SIMD3(sin(screenTilt), 0, -cos(screenTilt)), right = SIMD3<Double>(0, 1, 0)
        return [c - right * (w / 2) + up * (h / 2), c + right * (w / 2) + up * (h / 2),
                c + right * (w / 2) - up * (h / 2), c - right * (w / 2) - up * (h / 2)]
    }

    /// Panel point at height z (top of the panel leans 12° forward like the screen).
    static func panel(_ y: Double, _ z: Double, inset: Double = 0) -> SIMD3<Double> {
        let mid = -0.235
        return SIMD3(panelX - inset - (z - mid) * tan(screenTilt), y, z)
    }

    /// Interior mesh in body axes: panel with round gauges, switches and an avionics stack; seats, door
    /// panels, floor, centre pedestal with levers, pedals and yokes. Faces are drawn two-sided.
    public static func mesh() -> TriangleSoup {
        typealias V = SIMD3<Double>
        var s = TriangleSoup(origin: .zero)
        func tri(_ a: V, _ b: V, _ c: V, _ col: SIMD3<Float>, _ m: Material) { s.addFlat(a, b, c, colour: col, material: m) }
        func quad(_ a: V, _ b: V, _ c: V, _ d: V, _ col: SIMD3<Float>, _ m: Material = .opaque) {
            tri(a, b, c, col, m); tri(a, c, d, col, m)
        }
        func box(_ lo: V, _ hi: V, _ col: SIMD3<Float>, _ m: Material = .opaque) {
            let p = (0..<8).map { i in V(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z) }
            for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]] {
                quad(p[f[0]], p[f[1]], p[f[2]], p[f[3]], col, m)
            }
        }
        func unit(_ v: V) -> V { v / (v * v).sum().squareRoot() }
        func cross(_ a: V, _ b: V) -> V { V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) }
        func dot(_ a: V, _ b: V) -> Double { (a * b).sum() }
        /// Two perpendicular unit vectors to `ax`.
        func perp(_ ax: V) -> (V, V) {
            var u = abs(ax.y) < 0.9 ? V(0, 1, 0) : V(1, 0, 0)
            u = unit(u - ax * dot(u, ax))
            return (u, cross(ax, u))
        }
        /// A large trim surface as a grid with per-vertex colour: darker toward its edges (where it meets the
        /// surfaces around it) and a faint moulded grain, so it does not read as one flat plastic sheet
        /// (art round 24: flat glare shield, panel and liner). `ao` darkens the edges by that fraction.
        func shaded(_ a: V, _ b: V, _ c: V, _ d: V, _ col: SIMD3<Float>, nu: Int = 8, nv: Int = 6, ao: Float = 0.35,
                    grain: Float = 0.06, seed: UInt32 = 1) {
            func at(_ u: Double, _ v: Double) -> V { (a * (1 - u) + b * u) * (1 - v) + (d * (1 - u) + c * u) * v }
            func shade(_ i: Int, _ j: Int) -> SIMD3<Float> {
                let u = Float(i) / Float(nu), v = Float(j) / Float(nv)
                let e = min(min(u, 1 - u), min(v, 1 - v))                 // 0 at an edge, 0.5 in the middle
                let occ = 1 - ao * (1 - min(1, e / 0.18)) * (1 - min(1, e / 0.18))
                var h = UInt32(truncatingIfNeeded: i &* 73856093) ^ UInt32(truncatingIfNeeded: j &* 19349663) ^ (seed &* 83492791)
                h = (h ^ (h >> 13)) &* 0x5bd1e995; h ^= h >> 15
                let n = Float(h & 0xffff) / 65535 * 2 - 1
                return col * occ * (1 + grain * n)
            }
            let nrm = unit(cross(b - a, d - a)) * -1
            let nf = SIMD3<Float>(Float(nrm.x), Float(nrm.y), Float(nrm.z))
            for j in 0..<nv {
                for i in 0..<nu {
                    let u0 = Double(i) / Double(nu), u1 = Double(i + 1) / Double(nu)
                    let v0 = Double(j) / Double(nv), v1 = Double(j + 1) / Double(nv)
                    let p00 = at(u0, v0), p10 = at(u1, v0), p11 = at(u1, v1), p01 = at(u0, v1)
                    let c00 = shade(i, j), c10 = shade(i + 1, j), c11 = shade(i + 1, j + 1), c01 = shade(i, j + 1)
                    s.add(p00, p10, p11, na: nf, nb: nf, nc: nf, ca: c00, cb: c10, cc: c11, material: .opaque)
                    s.add(p00, p11, p01, na: nf, nb: nf, nc: nf, ca: c00, cb: c11, cc: c01, material: .opaque)
                }
            }
        }
        /// Round tube (smooth normals) from a to b.
        func tube(_ a: V, _ b: V, _ r0: Double, _ r1: Double, sides: Int = 8, _ col: SIMD3<Float>, _ m: Material = .opaque) {
            let (u, v) = perp(unit(b - a))
            for i in 0..<sides {
                let t0 = Double(i) / Double(sides) * 2 * .pi, t1 = Double(i + 1) / Double(sides) * 2 * .pi
                let d0 = u * cos(t0) + v * sin(t0), d1 = u * cos(t1) + v * sin(t1)
                let n0 = SIMD3<Float>(Float(d0.x), Float(d0.y), Float(d0.z)), n1 = SIMD3<Float>(Float(d1.x), Float(d1.y), Float(d1.z))
                s.add(a + d0 * r0, a + d1 * r0, b + d1 * r1, na: n0, nb: n1, nc: n1, colour: col, material: m)
                s.add(a + d0 * r0, b + d1 * r1, b + d0 * r1, na: n0, nb: n1, nc: n0, colour: col, material: m)
            }
        }
        /// Flat disc facing along `axis`.
        func disc(_ c: V, _ axis: V, _ r: Double, sides: Int = 20, _ col: SIMD3<Float>, _ m: Material = .opaque) {
            let (u, v) = perp(unit(axis))
            for i in 0..<sides {
                let t0 = Double(i) / Double(sides) * 2 * .pi, t1 = Double(i + 1) / Double(sides) * 2 * .pi
                tri(c, c + (u * cos(t0) + v * sin(t0)) * r, c + (u * cos(t1) + v * sin(t1)) * r, col, m)
            }
        }
        /// Flat annulus facing along `axis`.
        func ring(_ c: V, _ axis: V, _ r0: Double, _ r1: Double, sides: Int = 24, _ col: SIMD3<Float>, _ m: Material = .opaque) {
            let (u, v) = perp(unit(axis))
            for i in 0..<sides {
                let t0 = Double(i) / Double(sides) * 2 * .pi, t1 = Double(i + 1) / Double(sides) * 2 * .pi
                let d0 = u * cos(t0) + v * sin(t0), d1 = u * cos(t1) + v * sin(t1)
                quad(c + d0 * r0, c + d1 * r0, c + d1 * r1, c + d0 * r1, col, m)
            }
        }
        /// Slab (rectangular section: `hw` across y, `ht` the other way) from a to b.
        func slab(_ a: V, _ b: V, hw: Double, ht: Double, _ col: SIMD3<Float>, _ m: Material = .opaque) {
            let ax = unit(b - a), w = V(0, 1, 0), t = unit(cross(ax, w))
            let o = [w * hw + t * ht, w * hw - t * ht, -w * hw - t * ht, -w * hw + t * ht]
            for i in 0..<4 { let j = (i + 1) % 4; quad(a + o[i], a + o[j], b + o[j], b + o[i], col, m) }
            quad(a + o[0], a + o[1], a + o[2], a + o[3], col, m); quad(b + o[0], b + o[1], b + o[2], b + o[3], col, m)
        }

        // Surface colours: dark grey plastics (not black), warm grey fabric, light headliner.
        let panelCol = SIMD3<Float>(0.050, 0.052, 0.055), shield = SIMD3<Float>(0.028, 0.028, 0.030), black = SIMD3<Float>(0.014, 0.014, 0.015)
        let trim = SIMD3<Float>(0.11, 0.105, 0.098), door = SIMD3<Float>(0.16, 0.15, 0.14), headliner = SIMD3<Float>(0.38, 0.37, 0.34)
        let seatCol = SIMD3<Float>(0.19, 0.17, 0.15), carpet = SIMD3<Float>(0.055, 0.05, 0.047)
        let chrome = SIMD3<Float>(0.62, 0.62, 0.64), white = SIMD3<Float>(0.75, 0.75, 0.72)
        let w = halfWidth, floorZ = 0.56

        // Panel plane: right (+y), up and the normal toward the pilot.
        let t = screenTilt
        let pr = V(0, 1, 0), pu = V(sin(t), 0, -cos(t)), pn = V(-cos(t), 0, -sin(t))
        func P(_ y: Double, _ z: Double, _ off: Double = 0) -> V { panel(y, z) + pn * off }

        // Panel face and the lower panel down to the firewall.
        shaded(panel(-w, panelTop), panel(w, panelTop), panel(w, panelBottom), panel(-w, panelBottom), panelCol * 1.3, nu: 16, nv: 8, ao: 0.30, grain: 0.14, seed: 2)   // crinkle finish (round 30)
        // Lower panel in a dark textured (crinkle) finish rather than flat black (round 30).
        shaded(panel(-w, panelBottom), panel(w, panelBottom), V(1.02, w, floorZ), V(1.02, -w, floorZ), shield * 2.0, nu: 16, nv: 8, ao: 0.4, grain: 0.18, seed: 3)
        // PFD bezel (the screen itself is a separate textured quad).
        let pc = pfdCorners.map { $0 - V(-0.002, 0, 0) }
        let bez = 0.018
        quad(pc[0] + V(0.001, -bez, -bez), pc[1] + V(0.001, bez, -bez), pc[2] + V(0.001, bez, bez), pc[3] + V(0.001, -bez, bez), black)
        for (a, b) in [(0, 1), (1, 2), (2, 3), (3, 0)] { tube(pc[a] + V(0.003, 0, 0), pc[b] + V(0.003, 0, 0), 0.006, 0.006, sides: 4, chrome, .metal) }

        // A round gauge on the panel: bezel, black face, tick marks and a needle at `value` (0…1 over 270°).
        func gauge(_ y: Double, _ z: Double, r: Double, value: Double, ticks: Int = 9, needle: SIMD3<Float> = white) {
            let c = P(y, z, 0.004)
            ring(c, pn, r, r * 1.16, sides: 28, chrome, .metal)
            ring(c + pn * 0.003, pn, r * 1.16, r * 1.24, sides: 28, black)
            disc(c + pn * 0.001, pn, r, sides: 28, SIMD3<Float>(0.018, 0.018, 0.020))
            func dirAt(_ f: Double) -> V { let a = (-135 + 270 * f) * .pi / 180; return pr * sin(a) + pu * cos(a) }
            for k in 0..<ticks {
                let f = Double(k) / Double(ticks - 1), d = dirAt(f)
                quad(c + pn * 0.002 + d * (r * 0.74) - cross(pn, d) * 0.0018, c + pn * 0.002 + d * (r * 0.74) + cross(pn, d) * 0.0018,
                     c + pn * 0.002 + d * (r * 0.92) + cross(pn, d) * 0.0018, c + pn * 0.002 + d * (r * 0.92) - cross(pn, d) * 0.0018, white)
            }
            let nd = dirAt(value), side = cross(pn, nd)
            let base = c + pn * 0.005
            tri(base - side * 0.0035, base + side * 0.0035, base + nd * (r * 0.80), needle, .opaque)
            disc(base + pn * 0.001, pn, r * 0.10, sides: 12, chrome, .metal)
        }
        // Engine and flight instruments right of the PFD, two small ones to its left.
        let rows = [-0.305, -0.175]
        let vals: [[Double]] = [[0.62, 0.35, 0.50], [0.72, 0.45, 0.30]]
        for (ri, z) in rows.enumerated() {
            for (ci, y) in [-0.035, 0.075, 0.185].enumerated() { gauge(y, z, r: 0.043, value: vals[ri][ci]) }
        }
        gauge(-0.475, -0.295, r: 0.033, value: 0.40, ticks: 7)
        gauge(-0.475, -0.195, r: 0.033, value: 0.58, ticks: 7)
        // Avionics stack: four units with a lit display, a row of keys and two knobs.
        for k in 0..<4 {
            let z0 = -0.385 + Double(k) * 0.055
            let lo = P(0.275, z0, 0.001), hi = P(0.52, z0 + 0.048, 0.016)
            let fx = min(lo.x, hi.x), zl = min(lo.z, hi.z), zh = max(lo.z, hi.z)
            box(V(fx, lo.y, zl), V(max(lo.x, hi.x), hi.y, zh), black)
            // The box is axis-aligned, so its face toward the pilot is the plane x = fx: the display, its
            // digits, keys and knobs sit just in front of it (round 24: they were inside it, so the stack read
            // as plain dark stripes). A lighter bezel frames each unit.
            let f = fx - 0.0015, zc = (zl + zh) / 2
            quad(V(f, lo.y + 0.004, zl + 0.003), V(f, hi.y - 0.004, zl + 0.003), V(f, hi.y - 0.004, zh - 0.003), V(f, lo.y + 0.004, zh - 0.003),
                 SIMD3<Float>(0.075, 0.075, 0.08))
            let lit = k % 2 == 0 ? SIMD3<Float>(0.05, 0.55, 0.20) : SIMD3<Float>(0.8, 0.45, 0.05)
            quad(V(f - 0.001, 0.300, zc - 0.012), V(f - 0.001, 0.400, zc - 0.012), V(f - 0.001, 0.400, zc + 0.012), V(f - 0.001, 0.300, zc + 0.012),
                 SIMD3<Float>(0.010, 0.012, 0.012))
            for dgt in 0..<5 {                                                // seven-segment-like digits
                let y0 = 0.308 + Double(dgt) * 0.018
                quad(V(f - 0.002, y0, zc - 0.008), V(f - 0.002, y0 + 0.011, zc - 0.008), V(f - 0.002, y0 + 0.011, zc + 0.008), V(f - 0.002, y0, zc + 0.008),
                     dgt == 2 ? lit * 0.25 : lit)
            }
            for (i, ky) in [0.43, 0.46, 0.49].enumerated() where i < 3 {
                tube(V(f, ky, zc), V(f - 0.012, ky, zc), 0.0085, 0.0075, sides: 10, i == 2 ? chrome : SIMD3<Float>(0.03, 0.03, 0.033), .metal)
                disc(V(f - 0.0125, ky, zc), V(-1, 0, 0), 0.0075, sides: 10, SIMD3<Float>(0.05, 0.05, 0.055))
            }
            for ky in [0.412, 0.506] {                                        // small keys beside the knobs
                box(V(f - 0.004, ky - 0.006, zc - 0.004), V(f, ky + 0.006, zc + 0.004), SIMD3<Float>(0.12, 0.12, 0.13))
            }
        }
        // Switch row (toggle tips) and circuit-breaker row.
        for i in 0..<12 {
            let y = -0.47 + Double(i) * 0.085
            tube(P(y, -0.085, 0.002), P(y, -0.085, 0.026) + pu * (i % 3 == 0 ? 0.004 : -0.004), 0.0045, 0.0035, sides: 6, i % 4 == 0 ? SIMD3<Float>(0.5, 0.05, 0.04) : chrome, .metal)
            disc(P(y, -0.085, 0.003), pn, 0.011, sides: 10, black)
        }
        for i in 0..<20 {
            let y = -0.50 + Double(i) * 0.053
            disc(P(y, -0.020, 0.006), pn, 0.0105, sides: 10, i % 5 == 0 ? white : SIMD3<Float>(0.03, 0.03, 0.032))
        }
        // Lower panel: placards, a row of rocker switches and a fuel selector, so the strip under the gauges
        // is not empty black (round 31).
        for i in 0..<6 {
            let y = -0.44 + Double(i) * 0.05
            quad(P(y, 0.030, 0.002), P(y + 0.03, 0.030, 0.002), P(y + 0.03, 0.045, 0.002), P(y, 0.045, 0.002), SIMD3<Float>(0.55, 0.55, 0.52))
        }
        for i in 0..<8 {
            let y = 0.12 + Double(i) * 0.045
            box(P(y, 0.020, 0.0) - V(0.012, 0.012, 0.012), P(y, 0.020, 0.0) + V(0.0, 0.012, 0.012), i % 3 == 0 ? SIMD3<Float>(0.45, 0.06, 0.04) : SIMD3<Float>(0.10, 0.10, 0.11))
        }
        disc(P(0.0, 0.035, 0.004), pn, 0.028, sides: 18, SIMD3<Float>(0.30, 0.04, 0.03))                 // fuel selector
        quad(P(-0.022, 0.031, 0.008), P(0.022, 0.031, 0.008), P(0.022, 0.039, 0.008), P(-0.022, 0.039, 0.008), SIMD3<Float>(0.75, 0.75, 0.72))   // selector pointer
        // Glare shield (anti-glare cap) with a raised lip and the rear edge.
        let gsBackL = panel(-w, panelTop), gsBackR = panel(w, panelTop)
        let gsFrontL = V(1.48, -w, panelTop - 0.03), gsFrontR = V(1.48, w, panelTop - 0.03)
        shaded(gsBackL - V(0.03, 0, 0.012), gsBackR - V(0.03, 0, 0.012), gsFrontR, gsFrontL, shield * 2.4, nu: 14, nv: 6, ao: 0.45, grain: 0.10, seed: 4)
        // Stitched seam along the glare shield's rear edge (a fine lighter line), as on a padded cover.
        for i in 0..<36 {
            let y0 = -w + 0.03 + Double(i) * (2 * w - 0.06) / 36
            let a0 = gsBackL - V(0.045, 0, 0.0135), y1 = y0 + (2 * w - 0.06) / 72
            quad(V(a0.x, y0, a0.z - 0.0005), V(a0.x, y1, a0.z - 0.0005), V(a0.x - 0.004, y1, a0.z - 0.0012), V(a0.x - 0.004, y0, a0.z - 0.0012),
                 SIMD3<Float>(0.09, 0.09, 0.095))
        }
        quad(gsBackL - V(0.03, 0, 0.012), gsBackR - V(0.03, 0, 0.012), gsBackR, gsBackL, shield)
        tube(gsBackL - V(0.03, 0, 0.012), gsBackR - V(0.03, 0, 0.012), 0.010, 0.010, sides: 10, SIMD3<Float>(0.10, 0.10, 0.105))   // padded lip catches the light
        // Wet compass on the windscreen's centre post, just below the headliner: a small black housing
        // (about 4 cm across) with its card window and lubber line facing the pilot. Round 25: a stick and a
        // downward disc; round 26: a housing three times too large hanging in the windscreen.
        slab(V(0.80, 0, -1.02), V(0.85, 0, -0.97), hw: 0.012, ht: 0.008, trim * 1.4)                // short mount stub (round 27: a 30 cm post read as a third pillar)
        tube(V(0.835, 0, -0.985), V(0.865, 0, -0.985), 0.018, 0.018, sides: 12, SIMD3<Float>(0.025, 0.025, 0.027))
        disc(V(0.835, 0, -0.985), V(-1, 0, 0), 0.018, sides: 12, SIMD3<Float>(0.03, 0.03, 0.032))
        disc(V(0.834, 0, -0.986), V(-1, 0, 0), 0.012, sides: 12, SIMD3<Float>(0.02, 0.02, 0.022))
        for k in 0..<4 {                                                      // card numerals
            let y = -0.0075 + Double(k) * 0.005
            quad(V(0.8332, y - 0.001, -0.989), V(0.8332, y + 0.001, -0.989), V(0.8332, y + 0.001, -0.983), V(0.8332, y - 0.001, -0.983),
                 SIMD3<Float>(0.70, 0.70, 0.66))
        }
        quad(V(0.8325, -0.0006, -0.996), V(0.8325, 0.0006, -0.996), V(0.8325, 0.0006, -0.974), V(0.8325, -0.0006, -0.974),
             SIMD3<Float>(0.75, 0.30, 0.05))                                   // lubber line
        // Door panels, armrests, window sills and pillars.
        for side in [-1.0, 1.0] {
            let y = side * (w + 0.02)
            shaded(V(panelX, y, panelTop), V(-1.1, y, panelTop), V(-1.1, y, floorZ), V(panelX, y, floorZ), door, nu: 10, nv: 6, ao: 0.35, grain: 0.05, seed: side > 0 ? 5 : 6)
            box(V(-0.5, side > 0 ? y - 0.075 : y, -0.17), V(0.55, side > 0 ? y : y + 0.075, -0.10), trim)
            box(V(-1.1, side > 0 ? y - 0.07 : y, panelTop - 0.012), V(panelX, side > 0 ? y : y + 0.07, panelTop + 0.02), shield)
            // Door pocket and handle.
            box(V(-0.35, side > 0 ? y - 0.04 : y, 0.18), V(0.35, side > 0 ? y : y + 0.04, 0.34), SIMD3<Float>(0.07, 0.065, 0.06))
            tube(V(-0.30, y - side * 0.03, -0.30), V(-0.12, y - side * 0.03, -0.30), 0.011, 0.011, sides: 6, chrome, .metal)
            // Windscreen pillar and door post.
            // Moulded plastic pillar covers in a mid grey with smooth normals (round 26: flat black bars).
            tube(V(1.46, side * (w - 0.01), panelTop - 0.03), V(0.78, side * (w - 0.02), -1.02), 0.024, 0.022, sides: 10, trim * 1.5)
            // A lighter moulded edge along the pillar's inner face catches the cabin light.
            tube(V(1.44, side * (w - 0.035), panelTop - 0.035), V(0.77, side * (w - 0.045), -1.015), 0.006, 0.006, sides: 6, trim * 2.6)
            tube(V(-0.35, side * (w + 0.01), panelTop), V(-0.35, side * (w - 0.02), -1.02), 0.036, 0.036, sides: 6, trim)
        }
        // Headliner (the wing centre section is above it) and its front edge.
        // Headliner: a shallow arch (5 cm higher at the centre) in quilted panels: each strip shaded on its
        // own, with a darker seam between strips (round 26: one flat grey slab across the top of the view).
        let strips = 6
        func archZ(_ y: Double) -> Double { -1.03 - 0.05 * (1 - (y / w) * (y / w)) }
        for k in 0..<strips {
            let y0 = -w + 2 * w * Double(k) / Double(strips), y1 = -w + 2 * w * Double(k + 1) / Double(strips)
            // Strips alternate ±8 % and seams sit at 45 % so the quilting reads at a glance (round 29: too faint).
            shaded(V(0.80, y0, archZ(y0)), V(0.80, y1, archZ(y1)), V(-1.1, y1, archZ(y1)), V(-1.1, y0, archZ(y0)),
                   headliner * (k % 2 == 0 ? 1.08 : 0.92), nu: 2, nv: 10, ao: 0.32, grain: 0.09, seed: UInt32(7 + k))
            if k > 0 { tube(V(0.80, y0, archZ(y0) + 0.003), V(-1.1, y0, archZ(y0) + 0.003), 0.006, 0.006, sides: 4, headliner * 0.45) }
        }
        // Front edge: a slim padded roll in the headliner's colour (round 24: a fat black bar across the view).
        tube(V(0.80, -w, -1.02), V(0.80, w, -1.02), 0.016, 0.016, sides: 8, headliner * 0.7)
        // Sun visors folded up against the headliner, one per seat, on a chrome pivot rod.
        for y in [eye.y, -eye.y] {
            slab(V(0.78, y, -1.012), V(0.60, y, -1.012), hw: 0.16, ht: 0.008, headliner * 0.82)
            tube(V(0.60, y - 0.16, -1.010), V(0.60, y + 0.16, -1.010), 0.011, 0.011, sides: 8, headliner * 0.86)   // rounded front edge
            // A darker stitched rim so the visor reads as a padded board, not a flat grey patch.
            for (a, b) in [(V(0.60, y - 0.16, -1.003), V(0.60, y + 0.16, -1.003)), (V(0.60, y - 0.16, -1.003), V(0.78, y - 0.16, -1.003)),
                           (V(0.60, y + 0.16, -1.003), V(0.78, y + 0.16, -1.003))] {
                tube(a, b, 0.005, 0.005, sides: 4, headliner * 0.5)
            }
            tube(V(0.785, y - 0.17, -1.018), V(0.785, y + 0.17, -1.018), 0.004, 0.004, sides: 6, chrome, .metal)
        }
        // Floor carpet, a seat-rail step, and rudder pedals with toe plates.
        shaded(V(1.02, -w, floorZ), V(1.02, w, floorZ), V(-1.1, w, floorZ), V(-1.1, -w, floorZ), carpet * 1.4, nu: 8, nv: 8, ao: 0.4, grain: 0.15, seed: 11)
        for y in [eye.y, -eye.y] {
            for dy in [-0.09, 0.09] {
                box(V(0.90, y + dy - 0.045, 0.34), V(0.96, y + dy + 0.045, 0.50), SIMD3<Float>(0.06, 0.06, 0.065))
                tube(V(0.96, y + dy, 0.50), V(1.02, y + dy, 0.56), 0.012, 0.012, sides: 6, chrome, .metal)
            }
        }
        // Centre pedestal: throttle (black), mixture (red) and trim wheel.
        box(V(0.30, -0.075, 0.22), V(1.02, 0.075, floorZ), SIMD3<Float>(0.07, 0.068, 0.07))
        quad(V(0.30, -0.075, 0.22), V(1.02, -0.075, 0.22), V(1.02, 0.075, 0.22), V(0.30, 0.075, 0.22), SIMD3<Float>(0.09, 0.088, 0.09))
        tube(V(0.80, -0.025, 0.22), V(0.84, -0.025, 0.00), 0.006, 0.006, sides: 6, chrome, .metal)
        tube(V(0.84, -0.025, 0.00), V(0.84, -0.025, -0.045), 0.020, 0.020, sides: 10, black)
        tube(V(0.76, 0.030, 0.22), V(0.78, 0.030, 0.02), 0.006, 0.006, sides: 6, chrome, .metal)
        tube(V(0.78, 0.030, 0.02), V(0.78, 0.030, -0.025), 0.018, 0.018, sides: 10, SIMD3<Float>(0.40, 0.02, 0.02))
        disc(V(0.52, 0.076, 0.30), V(0, 1, 0), 0.055, sides: 18, SIMD3<Float>(0.04, 0.04, 0.045))
        ring(V(0.52, 0.077, 0.30), V(0, 1, 0), 0.050, 0.058, sides: 18, chrome, .metal)
        // Seats: cushion, backrest and headrest (pilot, passenger) and a rear bench.
        for y in [eye.y, -eye.y] {
            slab(V(-0.22, y, 0.20), V(0.30, y, 0.20), hw: 0.21, ht: 0.05, seatCol)
            slab(V(-0.26, y, 0.14), V(-0.43, y, -0.62), hw: 0.20, ht: 0.055, seatCol)
            slab(V(-0.44, y, -0.66), V(-0.46, y, -0.82), hw: 0.11, ht: 0.04, seatCol)
            tube(V(-0.20, y - 0.21, 0.24), V(0.28, y - 0.21, 0.24), 0.012, 0.012, sides: 6, chrome, .metal)
            tube(V(-0.20, y + 0.21, 0.24), V(0.28, y + 0.21, 0.24), 0.012, 0.012, sides: 6, chrome, .metal)
        }
        slab(V(-0.74, 0, 0.22), V(-1.08, 0, 0.22), hw: 0.50, ht: 0.05, seatCol)
        slab(V(-1.04, 0, 0.18), V(-1.10, 0, -0.55), hw: 0.50, ht: 0.05, seatCol)
        // Yokes (pilot and co-pilot): shaft, rim as a ring of tubes, grips and a push-to-talk button.
        for y in [eye.y, -eye.y] {
            // Hub ~0.5 m below the eye (was 0.69 m, below the 55° view): the yoke's upswept horns just show
            // above the bottom edge, as from a trainer's left seat (art round 29: no yoke in view).
            // The shaft leaves the panel below the PFD (round 30: at the PFD's height it covered the screen).
            tube(V(panelX - 0.01, y, -0.12), V(0.88, y, -0.26), 0.016, 0.016, sides: 10, chrome, .metal)
            let hub = V(0.86, y, -0.27)
            let n = 14
            for i in 0..<n {
                let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
                let p0 = hub + V(0, 0.145 * cos(a0), -0.085 * sin(a0) * (sin(a0) > 0 ? 0.65 : 1.0))
                let p1 = hub + V(0, 0.145 * cos(a1), -0.085 * sin(a1) * (sin(a1) > 0 ? 0.65 : 1.0))
                tube(p0, p1, 0.0165, 0.0165, sides: 6, black)
            }
            disc(hub + V(0.012, 0, 0), V(1, 0, 0), 0.034, sides: 14, SIMD3<Float>(0.03, 0.03, 0.032))
            for sgn in [-1.0, 1.0] {
                tube(hub + V(0, sgn * 0.14, 0.04), hub + V(0, sgn * 0.14, -0.06), 0.022, 0.022, sides: 8, black)
                tube(hub + V(0, sgn * 0.14, -0.06), hub + V(-0.01, sgn * 0.12, -0.19), 0.022, 0.018, sides: 8, black)   // upswept horn tip (just in view)
            }
            disc(hub + V(-0.014, -0.14, -0.03), V(-1, 0, 0), 0.006, sides: 8, SIMD3<Float>(0.5, 0.03, 0.03))
        }
        return s
    }
}

extension QuickFlightSession {
    /// In-cockpit camera: eye position, a look-at target and the up vector (banks with the aircraft).
    public func cockpitCamera() -> (position: SIMD3<Double>, target: SIMD3<Double>, up: SIMD3<Double>) {
        let c = bodyToENUColumns
        func toENU(_ b: SIMD3<Double>) -> SIMD3<Double> { c.0 * b.x + c.1 * b.y + c.2 * b.z }
        let eye = positionENU + toENU(Cockpit.eye)
        let fwd = toENU(SIMD3(cos(Cockpit.lookDown), 0, sin(Cockpit.lookDown)))
        return (eye, eye + fwd * 50, toENU(SIMD3(-sin(Cockpit.lookDown), 0, cos(Cockpit.lookDown)) * -1))
    }
}
