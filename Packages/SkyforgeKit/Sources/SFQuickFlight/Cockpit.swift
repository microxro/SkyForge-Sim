// SKYFORGE — Apache-2.0
// SF-1 Trainer cockpit for the in-cockpit view: a simple 3D panel (glare shield, panel face, side
// sills, windscreen pillars, headliner, yoke) in body axes and the SF-1000 PFD screen rectangle.
// The exterior airframe is drawn too (back faces discarded) so the cowling, wings and struts show.
import Foundation
import SFPreview

public enum Cockpit {
    /// Pilot eye point, left seat (body axes: x forward, y right, z down; origin at the CG).
    public static let eye = SIMD3<Double>(0.22, -0.26, -0.80)
    /// Eye looks 5° below the body x axis (over the glare shield to the horizon).
    public static let lookDown = 5.0 * Double.pi / 180

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
        quad(panel(-w, panelTop), panel(w, panelTop), panel(w, panelBottom), panel(-w, panelBottom), panelCol)
        quad(panel(-w, panelBottom), panel(w, panelBottom), V(1.02, w, floorZ), V(1.02, -w, floorZ), shield)
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
            box(V(min(lo.x, hi.x), lo.y, min(lo.z, hi.z)), V(max(lo.x, hi.x), hi.y, max(lo.z, hi.z)), black)
            let dc = P(0.35, z0 + 0.024, 0.018)
            quad(dc - pr * 0.05 - pu * 0.015, dc + pr * 0.05 - pu * 0.015, dc + pr * 0.05 + pu * 0.015, dc - pr * 0.05 + pu * 0.015,
                 k % 2 == 0 ? SIMD3<Float>(0.05, 0.55, 0.20) : SIMD3<Float>(0.8, 0.45, 0.05))
            for (i, ky) in [0.43, 0.46, 0.49].enumerated() where i < 3 { disc(P(ky, z0 + 0.024, 0.019), pn, 0.0085, sides: 10, chrome, .metal) }
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
        // Glare shield (anti-glare cap) with a raised lip and the rear edge.
        let gsBackL = panel(-w, panelTop), gsBackR = panel(w, panelTop)
        let gsFrontL = V(1.48, -w, panelTop - 0.03), gsFrontR = V(1.48, w, panelTop - 0.03)
        quad(gsBackL - V(0.03, 0, 0.012), gsBackR - V(0.03, 0, 0.012), gsFrontR, gsFrontL, shield)
        quad(gsBackL - V(0.03, 0, 0.012), gsBackR - V(0.03, 0, 0.012), gsBackR, gsBackL, shield)
        tube(gsBackL - V(0.03, 0, 0.012), gsBackR - V(0.03, 0, 0.012), 0.008, 0.008, sides: 6, SIMD3<Float>(0.04, 0.04, 0.042))
        // Compass at the windscreen's top centre.
        tube(V(0.84, 0, -1.01), V(0.84, 0, -0.96), 0.004, 0.004, sides: 6, chrome, .metal)
        disc(V(0.84, 0, -0.95), V(0, 0, 1), 0.026, sides: 16, SIMD3<Float>(0.03, 0.03, 0.03))
        // Door panels, armrests, window sills and pillars.
        for side in [-1.0, 1.0] {
            let y = side * (w + 0.02)
            quad(V(panelX, y, panelTop), V(-1.1, y, panelTop), V(-1.1, y, floorZ), V(panelX, y, floorZ), door)
            box(V(-0.5, side > 0 ? y - 0.075 : y, -0.17), V(0.55, side > 0 ? y : y + 0.075, -0.10), trim)
            box(V(-1.1, side > 0 ? y - 0.07 : y, panelTop - 0.012), V(panelX, side > 0 ? y : y + 0.07, panelTop + 0.02), shield)
            // Door pocket and handle.
            box(V(-0.35, side > 0 ? y - 0.04 : y, 0.18), V(0.35, side > 0 ? y : y + 0.04, 0.34), SIMD3<Float>(0.07, 0.065, 0.06))
            tube(V(-0.30, y - side * 0.03, -0.30), V(-0.12, y - side * 0.03, -0.30), 0.011, 0.011, sides: 6, chrome, .metal)
            // Windscreen pillar and door post.
            tube(V(1.46, side * (w - 0.01), panelTop - 0.03), V(0.78, side * (w - 0.02), -1.02), 0.020, 0.020, sides: 6, shield)
            tube(V(-0.35, side * (w + 0.01), panelTop), V(-0.35, side * (w - 0.02), -1.02), 0.036, 0.036, sides: 6, trim)
        }
        // Headliner (the wing centre section is above it) and its front edge.
        quad(V(0.80, -w, -1.03), V(0.80, w, -1.03), V(-1.1, w, -1.03), V(-1.1, -w, -1.03), headliner)
        tube(V(0.80, -w, -1.02), V(0.80, w, -1.02), 0.034, 0.034, sides: 6, trim)
        // Floor carpet, a seat-rail step, and rudder pedals with toe plates.
        quad(V(1.02, -w, floorZ), V(1.02, w, floorZ), V(-1.1, w, floorZ), V(-1.1, -w, floorZ), carpet)
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
            tube(V(panelX - 0.01, y, -0.06), V(0.88, y, -0.10), 0.016, 0.016, sides: 10, chrome, .metal)
            let hub = V(0.86, y, -0.115)
            let n = 14
            for i in 0..<n {
                let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
                let p0 = hub + V(0, 0.145 * cos(a0), -0.085 * sin(a0) * (sin(a0) > 0 ? 0.65 : 1.0))
                let p1 = hub + V(0, 0.145 * cos(a1), -0.085 * sin(a1) * (sin(a1) > 0 ? 0.65 : 1.0))
                tube(p0, p1, 0.0165, 0.0165, sides: 6, black)
            }
            disc(hub + V(0.012, 0, 0), V(1, 0, 0), 0.034, sides: 14, SIMD3<Float>(0.03, 0.03, 0.032))
            for sgn in [-1.0, 1.0] { tube(hub + V(0, sgn * 0.14, -0.04), hub + V(0, sgn * 0.14, 0.04), 0.022, 0.022, sides: 8, black) }
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
