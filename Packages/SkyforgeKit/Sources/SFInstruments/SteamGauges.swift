// SKYFORGE — Apache-2.0
// Original "six-pack" steam gauges drawn into a DrawBuilder. Each gauge is laid out in a
// unit circle (radius 1, y up) placed at `center` with `radius` in builder units.
import Foundation

public enum GaugePalette {
    public static let panel = RGBA(hex: 0x2A2E34)
    public static let plate = RGBA(hex: 0x17191C)
    public static let bezel = RGBA(hex: 0x3A3D42)
    public static let bezelHi = RGBA(hex: 0x5C6067)
    public static let face = RGBA(hex: 0x0E0F11)
    public static let marking = RGBA(hex: 0xF2F2EE)
    public static let green = RGBA(hex: 0x2FBF4A)
    public static let yellow = RGBA(hex: 0xF2C230)
    public static let red = RGBA(hex: 0xE23A2E)
    public static let sky = RGBA(hex: 0x2C7FD0)
    public static let skyHigh = RGBA(hex: 0x15508F)
    public static let ground = RGBA(hex: 0x7B4D22)
    public static let groundLow = RGBA(hex: 0x4F3013)
    public static let orange = RGBA(hex: 0xFF9C1F)
}

public enum SteamGauges {
    typealias P = GaugePalette

    // MARK: shared pieces

    static func case_(_ b: inout DrawBuilder) {
        b.rect(-1.18, -1.18, 1.18, 1.18, P.plate)
        for (x, y) in [(-1.04, -1.04), (1.04, -1.04), (-1.04, 1.04), (1.04, 1.04)] {
            b.circle(Point2(x, y), 0.065, P.bezel)
            b.line(Point2(x - 0.04, y - 0.04), Point2(x + 0.04, y + 0.04), width: 0.018, P.plate)
        }
        b.circle(Point2(0, 0), 1.1, P.bezel)
        b.ring(Point2(0, 0), inner: 1.0, outer: 1.1, from: .pi * 0.15, to: .pi * 0.85, P.bezelHi.withAlpha(0.55))
        b.circle(Point2(0, 0), 1.0, P.face)
    }

    static func glass(_ b: inout DrawBuilder) {
        // Soft reflection crescent, upper left.
        let outer = DrawBuilder.arcPoints(center: Point2(0, 0), radius: 0.97, from: .pi * 0.55, to: .pi * 1.05, segments: 24)
        let inner = DrawBuilder.arcPoints(center: Point2(0.08, -0.08), radius: 0.93, from: .pi * 1.05, to: .pi * 0.55, segments: 24)
        b.fill(outer + inner, RGBA(1, 1, 1, 0.07))
    }

    static func tick(_ b: inout DrawBuilder, _ cw: Double, _ r0: Double, _ r1: Double, _ w: Double, _ c: RGBA = P.marking) {
        let a = GaugeMath.dial(cw)
        b.line(Point2(r0 * cos(a), r0 * sin(a)), Point2(r1 * cos(a), r1 * sin(a)), width: w, c)
    }

    static func label(_ b: inout DrawBuilder, _ s: String, cw: Double, r: Double, size: Double) {
        let a = GaugeMath.dial(cw)
        b.text(s, at: Point2(r * cos(a), r * sin(a) - size / 2), size: size, P.marking)
    }

    static func arcBand(_ b: inout DrawBuilder, from cw0: Double, to cw1: Double, inner: Double, outer: Double, _ c: RGBA) {
        b.ring(Point2(0, 0), inner: inner, outer: outer, from: GaugeMath.dial(cw1), to: GaugeMath.dial(cw0), c)
    }

    static func needle(_ b: inout DrawBuilder, cw: Double, length: Double, tail: Double = 0.18, width: Double = 0.06, _ c: RGBA = P.marking) {
        let shape = [Point2(-tail, width * 0.7), Point2(length * 0.82, width * 0.5), Point2(length, 0),
                     Point2(length * 0.82, -width * 0.5), Point2(-tail, -width * 0.7)]
        b.save(); b.translate(0.025, -0.035); b.rotate(GaugeMath.dial(cw)); b.fill(shape, RGBA(0, 0, 0, 0.45)); b.restore()
        b.save(); b.rotate(GaugeMath.dial(cw)); b.fill(shape, c); b.restore()
    }

    static func hub(_ b: inout DrawBuilder) {
        b.circle(Point2(0, 0), 0.085, RGBA(hex: 0x26282C))
        b.circle(Point2(0, 0), 0.04, RGBA(hex: 0x4A4D52))
    }

    static func begin(_ b: inout DrawBuilder, _ center: Point2, _ radius: Double) {
        b.save(); b.translate(center.x, center.y); b.scale(radius)
        case_(&b)
    }
    static func end(_ b: inout DrawBuilder) { glass(&b); b.restore() }

    // MARK: gauges

    public static func airspeed(_ b: inout DrawBuilder, center: Point2, radius: Double, kt: Double, v: VSpeeds) {
        begin(&b, center, radius)
        let A = GaugeMath.airspeedAngle
        arcBand(&b, from: A(v.vso), to: A(v.vfe), inner: 0.78, outer: 0.85, P.marking)
        arcBand(&b, from: A(v.vs1), to: A(v.vno), inner: 0.86, outer: 0.95, P.green)
        arcBand(&b, from: A(v.vno), to: A(v.vne), inner: 0.86, outer: 0.95, P.yellow)
        tick(&b, A(v.vne), 0.74, 0.97, 0.035, P.red)
        var s = 40.0
        while s <= 200 {
            let major = s.truncatingRemainder(dividingBy: 10) == 0
            tick(&b, A(s), major ? 0.74 : 0.84, 0.96, major ? 0.026 : 0.014)
            if s.truncatingRemainder(dividingBy: 20) == 0 { label(&b, String(Int(s)), cw: A(s), r: 0.58, size: 0.12) }
            s += 5
        }
        b.text("AIRSPEED", at: Point2(0, 0.24), size: 0.062, P.marking)
        b.text("KNOTS", at: Point2(0, -0.36), size: 0.07, P.marking)
        needle(&b, cw: A(kt), length: 0.9)
        hub(&b)
        end(&b)
    }

    public static func attitude(_ b: inout DrawBuilder, center: Point2, radius: Double, pitch: Double, roll: Double) {
        begin(&b, center, radius)
        let k = 0.022  // radius per degree of pitch
        b.pushClipCircle(Point2(0, 0), 0.97)
        b.save()
        b.rotate(roll * .pi / 180)
        b.translate(0, -max(-40, min(40, pitch)) * k)
        // Sky and ground with a two-tone gradient.
        for i in 0..<8 {
            let t0 = Double(i) * 0.3, t1 = t0 + 0.31
            let f = Double(i) / 7
            b.rect(-2.5, t0, 2.5, t1, mix(P.sky, P.skyHigh, f))
            b.rect(-2.5, -t1, 2.5, -t0, mix(P.ground, P.groundLow, f))
        }
        b.line(Point2(-2.5, 0), Point2(2.5, 0), width: 0.025, P.marking)
        for deg in [-20.0, -15, -10, -5, 5, 10, 15, 20] {
            let y = deg * k
            let half = deg.truncatingRemainder(dividingBy: 10) == 0 ? 0.26 : 0.12
            b.line(Point2(-half, y), Point2(half, y), width: 0.018, P.marking)
            if deg.truncatingRemainder(dividingBy: 10) == 0 {
                b.text(String(Int(abs(deg))), at: Point2(-half - 0.13, y - 0.035), size: 0.07, P.marking)
                b.text(String(Int(abs(deg))), at: Point2(half + 0.13, y - 0.035), size: 0.07, P.marking)
            }
        }
        // Bank pointer on the gimballed card.
        b.fill([Point2(0, 0.78), Point2(-0.06, 0.66), Point2(0.06, 0.66)], P.marking)
        b.restore()
        b.popClip()
        // Fixed bank scale on the case.
        for (deg, long) in [(0.0, true), (10, false), (20, false), (30, true), (60, true), (-10, false), (-20, false), (-30, true), (-60, true)] {
            tick(&b, deg, long ? 0.8 : 0.86, 0.97, long ? 0.03 : 0.018)
        }
        for deg in [-45.0, 45] {
            b.save(); b.rotate(GaugeMath.dial(deg) - .pi / 2)
            b.fill([Point2(0, 0.86), Point2(-0.035, 0.96), Point2(0.035, 0.96)], P.marking)
            b.restore()
        }
        b.fill([Point2(0, 0.97), Point2(-0.06, 1.0), Point2(0.06, 1.0)], P.marking)
        // Miniature aircraft (fixed).
        let wing: [Point2] = [Point2(-0.62, 0.025), Point2(-0.2, 0.025), Point2(-0.12, -0.08), Point2(-0.16, -0.1),
                              Point2(-0.23, -0.025), Point2(-0.62, -0.025)]
        b.fill(wing, P.orange)
        b.fill(wing.map { Point2(-$0.x, $0.y) }, P.orange)
        b.circle(Point2(0, 0), 0.035, P.orange)
        // Lower case with adjustment knob.
        b.ring(Point2(0, 0), inner: 0.97, outer: 1.0, P.face)
        end(&b)
    }

    public static func altimeter(_ b: inout DrawBuilder, center: Point2, radius: Double, ft: Double, kollsmanInHg: Double) {
        begin(&b, center, radius)
        for i in 0..<50 {
            let major = i % 5 == 0
            tick(&b, Double(i) * 7.2, major ? 0.78 : 0.87, 0.96, major ? 0.03 : 0.014)
        }
        for i in 0..<10 { label(&b, String(i), cw: Double(i) * 36, r: 0.64, size: 0.17) }
        // Kollsman window.
        b.rect(0.15, -0.07, 0.49, 0.07, RGBA(hex: 0x050506))
        b.rectOutline(0.15, -0.07, 0.49, 0.07, width: 0.012, P.bezelHi)
        b.text(String(format: "%.2f", kollsmanInHg), at: Point2(0.32, -0.035), size: 0.07, P.marking)
        b.text("ALT", at: Point2(0, 0.3), size: 0.08, P.marking)
        b.text("100 FEET", at: Point2(0, -0.4), size: 0.06, P.marking)
        let h = GaugeMath.altimeterHands(ft)
        // 10,000 ft pointer: thin shaft with a triangle at the rim.
        b.save(); b.rotate(GaugeMath.dial(h.tenThousands))
        b.line(Point2(0, 0), Point2(0.84, 0), width: 0.018, P.marking)
        b.fill([Point2(0.98, 0), Point2(0.84, 0.05), Point2(0.84, -0.05)], P.marking)
        b.restore()
        needle(&b, cw: h.thousands, length: 0.5, tail: 0.1, width: 0.11)
        needle(&b, cw: h.hundreds, length: 0.88, tail: 0.2, width: 0.055)
        hub(&b)
        end(&b)
    }

    public static func turnCoordinator(_ b: inout DrawBuilder, center: Point2, radius: Double, turnRate: Double, ball: Double) {
        begin(&b, center, radius)
        for side in [-1.0, 1.0] {
            b.line(Point2(side * 0.66, 0), Point2(side * 0.9, 0), width: 0.035, P.marking)
            let a = -20 * Double.pi / 180
            b.line(Point2(side * 0.66 * cos(a), 0.66 * sin(a)), Point2(side * 0.9 * cos(a), 0.9 * sin(a)), width: 0.035, P.marking)
        }
        b.text("L", at: Point2(-0.62, -0.45), size: 0.1, P.marking)
        b.text("R", at: Point2(0.62, -0.45), size: 0.1, P.marking)
        b.text("TURN COORDINATOR", at: Point2(0, 0.5), size: 0.06, P.marking)
        b.text("2 MIN", at: Point2(0, -0.3), size: 0.07, P.marking)
        b.text("NO PITCH INFORMATION", at: Point2(0, 0.36), size: 0.042, P.marking.withAlpha(0.7))
        // Inclinometer tube.
        let tc = Point2(0, 0.42), tr = 1.0
        let a0 = (-90.0 - 15) * .pi / 180, a1 = (-90.0 + 15) * .pi / 180
        b.ring(tc, inner: tr - 0.09, outer: tr + 0.09, from: a0, to: a1, RGBA(hex: 0x3B3F44))
        b.ring(tc, inner: tr - 0.075, outer: tr + 0.075, from: a0 + 0.01, to: a1 - 0.01, RGBA(hex: 0xD9D6C8))
        for side in [-1.0, 1.0] {
            let a = (-90 + side * 4.6) * .pi / 180
            b.line(Point2(tc.x + (tr - 0.08) * cos(a), tc.y + (tr - 0.08) * sin(a)),
                   Point2(tc.x + (tr + 0.08) * cos(a), tc.y + (tr + 0.08) * sin(a)), width: 0.014, P.face)
        }
        let ba = (-90 + max(-1, min(1, ball)) * 13.5) * .pi / 180
        b.circle(Point2(tc.x + tr * cos(ba), tc.y + tr * sin(ba)), 0.068, RGBA(hex: 0x0A0A0A))
        // Miniature aircraft, banked by turn rate (right turn = right wing down).
        b.save(); b.rotate(-GaugeMath.turnCoordinatorBank(turnRate) * .pi / 180)
        b.fill([Point2(-0.66, 0.025), Point2(0.66, 0.025), Point2(0.66, -0.035), Point2(-0.66, -0.035)], P.marking)
        b.circle(Point2(0, 0), 0.1, P.marking)
        b.fill([Point2(-0.025, 0.08), Point2(0.025, 0.08), Point2(0.02, 0.24), Point2(-0.02, 0.24)], P.marking)
        b.fill([Point2(-0.2, 0.2), Point2(0.2, 0.2), Point2(0.2, 0.24), Point2(-0.2, 0.24)], P.marking)
        b.restore()
        end(&b)
    }

    public static func heading(_ b: inout DrawBuilder, center: Point2, radius: Double, heading: Double) {
        begin(&b, center, radius)
        b.save(); b.rotate(heading * .pi / 180)
        for i in 0..<72 {
            let deg = Double(i) * 5
            let major = i % 2 == 0
            tick(&b, deg, major ? 0.8 : 0.87, 0.95, major ? 0.026 : 0.014)
        }
        let names = ["N", "3", "6", "E", "12", "15", "S", "21", "24", "W", "30", "33"]
        for (i, n) in names.enumerated() {
            b.save(); b.rotate(-Double(i) * 30 * .pi / 180)
            b.text(n, at: Point2(0, 0.56), size: i % 3 == 0 ? 0.17 : 0.13, P.marking)
            b.restore()
        }
        b.restore()
        // Case marks: lubber line and 45° indices.
        b.fill([Point2(0, 0.8), Point2(-0.07, 0.99), Point2(0.07, 0.99)], P.orange)
        for deg in stride(from: 45.0, to: 360, by: 45) {
            b.save(); b.rotate(GaugeMath.dial(deg) - .pi / 2)
            b.fill([Point2(0, 0.88), Point2(-0.03, 0.99), Point2(0.03, 0.99)], P.marking)
            b.restore()
        }
        // Airplane silhouette.
        let plane: [Point2] = [Point2(0, 0.42), Point2(0.04, 0.34), Point2(0.04, 0.1), Point2(0.36, -0.02), Point2(0.36, -0.07),
                               Point2(0.04, -0.03), Point2(0.035, -0.26), Point2(0.13, -0.32), Point2(0.13, -0.36),
                               Point2(-0.13, -0.36), Point2(-0.13, -0.32), Point2(-0.035, -0.26), Point2(-0.04, -0.03),
                               Point2(-0.36, -0.07), Point2(-0.36, -0.02), Point2(-0.04, 0.1), Point2(-0.04, 0.34)]
        b.fill(plane, P.orange)
        end(&b)
    }

    public static func verticalSpeed(_ b: inout DrawBuilder, center: Point2, radius: Double, fpm: Double) {
        begin(&b, center, radius)
        let A = GaugeMath.verticalSpeedAngle
        var v = -2_000.0
        while v <= 2_000 {
            let major = v.truncatingRemainder(dividingBy: 500) == 0
            if abs(v) <= 1_000 || major { tick(&b, A(v), major ? 0.76 : 0.86, 0.96, major ? 0.03 : 0.016) }
            v += 100
        }
        for (val, text) in [(0.0, "0"), (500, ".5"), (1_000, "1"), (1_500, "1.5"), (2_000, "2")] {
            label(&b, text, cw: A(val), r: 0.6, size: 0.14)
            if val > 0 && val < 2_000 { label(&b, text, cw: A(-val), r: 0.6, size: 0.14) }
        }
        b.text("UP", at: Point2(-0.4, 0.22), size: 0.07, P.marking)
        b.text("DOWN", at: Point2(-0.38, -0.29), size: 0.07, P.marking)
        b.text("VERTICAL SPEED", at: Point2(0.18, 0.18), size: 0.055, P.marking)
        b.text("1000 FT PER MIN", at: Point2(0.18, -0.24), size: 0.05, P.marking)
        needle(&b, cw: A(fpm), length: 0.88)
        hub(&b)
        end(&b)
    }

    static func mix(_ a: RGBA, _ c: RGBA, _ t: Double) -> RGBA {
        RGBA(a.r + (c.r - a.r) * t, a.g + (c.g - a.g) * t, a.b + (c.b - a.b) * t, a.a + (c.a - a.a) * t)
    }

    /// Classic 3×2 panel: ASI, AI, ALT / TC, HI, VSI. Size is 3:2.
    public static func sixPack(_ d: InstrumentData, v: VSpeeds = .sf1Trainer, width: Double = 1500, height: Double = 1000) -> DrawList {
        var b = DrawBuilder(width: width, height: height)
        b.rect(0, 0, width, height, P.panel)
        let cw = width / 3, ch = height / 2
        let r = min(cw, ch) * 0.4
        func c(_ i: Int, _ j: Int) -> Point2 { Point2(cw * (Double(i) + 0.5), height - ch * (Double(j) + 0.5)) }
        airspeed(&b, center: c(0, 0), radius: r, kt: d.indicatedAirspeedKt, v: v)
        attitude(&b, center: c(1, 0), radius: r, pitch: d.pitchDeg, roll: d.rollDeg)
        altimeter(&b, center: c(2, 0), radius: r, ft: d.indicatedAltitudeFt, kollsmanInHg: d.kollsmanInHg)
        turnCoordinator(&b, center: c(0, 1), radius: r, turnRate: d.turnRateDegPerSec, ball: d.slipBall)
        heading(&b, center: c(1, 1), radius: r, heading: d.headingDeg)
        verticalSpeed(&b, center: c(2, 1), radius: r, fpm: d.verticalSpeedFpm)
        return b.list
    }
}
