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

    /// Interior mesh in body axes.
    public static func mesh() -> TriangleSoup {
        var s = TriangleSoup(origin: .zero)
        func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, _ col: SIMD3<Float>) {
            s.addFlat(a, b, c, colour: col, material: .opaque); s.addFlat(a, c, d, colour: col, material: .opaque)
        }
        func box(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>, _ col: SIMD3<Float>) {
            let p = (0..<8).map { i in SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z) }
            for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]] {
                quad(p[f[0]], p[f[1]], p[f[2]], p[f[3]], col)
            }
        }
        func beam(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ r: Double, _ col: SIMD3<Float>) {
            let d = b - a, len = (d * d).sum().squareRoot()
            let ax = d / len
            var u = abs(ax.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
            u = u - ax * (u * ax).sum(); u /= (u * u).sum().squareRoot()
            let v = SIMD3(ax.y * u.z - ax.z * u.y, ax.z * u.x - ax.x * u.z, ax.x * u.y - ax.y * u.x)
            let o = [u + v, u - v, -u - v, -u + v].map { $0 * r }
            for i in 0..<4 { let j = (i + 1) % 4; quad(a + o[i], a + o[j], b + o[j], b + o[i], col) }
        }
        let charcoal = SIMD3<Float>(0.032, 0.033, 0.035), black = SIMD3<Float>(0.012, 0.012, 0.013)
        let trim = SIMD3<Float>(0.07, 0.068, 0.064), headliner = SIMD3<Float>(0.16, 0.155, 0.145)
        let w = halfWidth
        // Panel face with an opening-free surface; the PFD bezel sits just in front of it.
        quad(panel(-w, panelTop), panel(w, panelTop), panel(w, panelBottom), panel(-w, panelBottom), charcoal)
        let pc = pfdCorners.map { $0 - SIMD3(-0.002, 0, 0) }
        let bez = 0.018
        quad(pc[0] + SIMD3(0.001, -bez, -bez), pc[1] + SIMD3(0.001, bez, -bez), pc[2] + SIMD3(0.001, bez, bez), pc[3] + SIMD3(0.001, -bez, bez), black)
        // Standby gauges (dark discs approximated by squares) and a radio stack on the right.
        box(SIMD3(panelX - 0.02, 0.06, -0.33), SIMD3(panelX - 0.004, 0.16, -0.23), black)
        box(SIMD3(panelX - 0.02, 0.20, -0.36), SIMD3(panelX - 0.004, 0.42, -0.06), black)
        // Glare shield: from the panel top forward to the windscreen base, slightly raised at the front.
        let gsBackL = panel(-w, panelTop), gsBackR = panel(w, panelTop)
        let gsFrontL = SIMD3(1.48, -w, panelTop - 0.03), gsFrontR = SIMD3(1.48, w, panelTop - 0.03)
        quad(gsBackL - SIMD3(0.03, 0, 0.012), gsBackR - SIMD3(0.03, 0, 0.012), gsFrontR, gsFrontL, black)
        quad(gsBackL - SIMD3(0.03, 0, 0.012), gsBackR - SIMD3(0.03, 0, 0.012), gsBackR, gsBackL, black)
        // Side sills and door panels below the windows.
        for side in [-1.0, 1.0] {
            let y = side * (w + 0.02)
            quad(SIMD3(panelX, y, panelTop), SIMD3(-0.6, y, panelTop), SIMD3(-0.6, y, 0.2), SIMD3(panelX, y, 0.2), trim)
            box(SIMD3(-0.6, side > 0 ? y - 0.07 : y, panelTop - 0.012), SIMD3(panelX, side > 0 ? y : y + 0.07, panelTop + 0.02), charcoal)
            // Windscreen pillar from the glare shield corner to the roof, and the door post behind the pilot.
            beam(SIMD3(1.46, side * (w - 0.01), panelTop - 0.03), SIMD3(0.78, side * (w - 0.02), -1.02), 0.025, charcoal)
            beam(SIMD3(-0.35, side * (w + 0.01), panelTop), SIMD3(-0.35, side * (w - 0.02), -1.02), 0.035, trim)
        }
        // Headliner (the wing centre section is above it).
        quad(SIMD3(0.80, -w, -1.03), SIMD3(0.80, w, -1.03), SIMD3(-0.9, w, -1.03), SIMD3(-0.9, -w, -1.03), headliner)
        beam(SIMD3(0.80, -w, -1.02), SIMD3(0.80, w, -1.02), 0.03, trim)
        // Yokes (pilot and co-pilot).
        for y in [eye.y, -eye.y] {
            beam(SIMD3(panelX - 0.01, y, -0.06), SIMD3(0.86, y, -0.10), 0.016, black)
            beam(SIMD3(0.86, y - 0.13, -0.14), SIMD3(0.86, y + 0.13, -0.14), 0.017, black)
            beam(SIMD3(0.86, y - 0.13, -0.14), SIMD3(0.86, y - 0.13, -0.04), 0.017, black)
            beam(SIMD3(0.86, y + 0.13, -0.14), SIMD3(0.86, y + 0.13, -0.04), 0.017, black)
            beam(SIMD3(0.86, y, -0.10), SIMD3(0.86, y, -0.14), 0.018, black)
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
