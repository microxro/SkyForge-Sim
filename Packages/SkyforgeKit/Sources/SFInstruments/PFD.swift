// SKYFORGE — Apache-2.0
// "SF-1000" generic glass primary flight display: full-width attitude, speed and altitude
// tapes, vertical speed scale, HSI rose. Original layout and colours; no third-party trade dress.
import Foundation

public struct PFDOptions: Sendable, Equatable {
    public var selectedAltitudeFt: Double?
    public var selectedHeadingDeg: Double?
    public var vSpeeds: VSpeeds = .sf1Trainer
    public init(selectedAltitudeFt: Double? = nil, selectedHeadingDeg: Double? = nil) {
        self.selectedAltitudeFt = selectedAltitudeFt; self.selectedHeadingDeg = selectedHeadingDeg
    }
}

public enum PFD {
    typealias P = GaugePalette
    static let cyan = RGBA(hex: 0x29D8F0)
    static let magenta = RGBA(hex: 0xE04FD6)
    static let tapeBG = RGBA(0.06, 0.07, 0.09, 0.55)

    public static func draw(_ d: InstrumentData, options o: PFDOptions = PFDOptions(), width: Double = 1280, height: Double = 800) -> DrawList {
        var b = DrawBuilder(width: width, height: height)
        let cx = width / 2, cy = height * 0.54
        let ppd = height / 88   // pixels per degree of pitch
        b.rect(0, 0, width, height, .black)
        b.pushClipRect(0, 0, width, height)

        // Attitude background.
        b.save()
        b.translate(cx, cy)
        b.rotate(d.rollDeg * .pi / 180)
        b.translate(0, -max(-60, min(60, d.pitchDeg)) * ppd)
        let span = width * 1.5
        let bands = 64
        for i in 0..<bands {
            let f = Double(i) / Double(bands - 1)
            let h0 = pow(Double(i) / Double(bands), 1.6) * span, h1 = pow(Double(i + 1) / Double(bands), 1.6) * span + 0.5
            b.rect(-span, h0, span, h1, SteamGauges.mix(RGBA(hex: 0x3B8DE0), RGBA(hex: 0x0D3A7A), f))
            b.rect(-span, -h1, span, -h0, SteamGauges.mix(RGBA(hex: 0x8A5A2B), RGBA(hex: 0x3E2510), f))
        }
        b.line(Point2(-span, 0), Point2(span, 0), width: 2.5, P.marking)
        b.restore()

        // Pitch ladder, clipped to the centre window.
        b.pushClipRect(cx - 190, cy - 165, cx + 190, cy + 175)
        b.save()
        b.translate(cx, cy)
        b.rotate(d.rollDeg * .pi / 180)
        b.translate(0, -max(-60, min(60, d.pitchDeg)) * ppd)
        var deg = -50.0
        while deg <= 50 {
            defer { deg += 2.5 }
            if deg == 0 { continue }
            let y = deg * ppd
            let isTen = deg.truncatingRemainder(dividingBy: 10) == 0
            let isFive = deg.truncatingRemainder(dividingBy: 5) == 0
            let half = isTen ? 70.0 : (isFive ? 36 : 16)
            b.line(Point2(-half, y), Point2(half, y), width: 2, P.marking)
            if isTen {
                let s = String(Int(abs(deg)))
                b.text(s, at: Point2(-half - 22, y - 7), size: 14, weight: 0.16, P.marking)
                b.text(s, at: Point2(half + 22, y - 7), size: 14, weight: 0.16, P.marking)
            }
        }
        b.restore()
        b.popClip()

        // Roll scale (fixed) and pointer (rotates with the horizon).
        let rr = 215.0
        b.save(); b.translate(cx, cy)
        b.stroke(DrawBuilder.arcPoints(center: Point2(0, 0), radius: rr, from: GaugeMath.dial(60), to: GaugeMath.dial(-60), segments: 48),
                 width: 2, P.marking)
        for (a, len) in [(10.0, 12.0), (20, 12), (30, 22), (60, 22), (-10, 12), (-20, 12), (-30, 22), (-60, 22)] {
            let t = GaugeMath.dial(a)
            b.line(Point2(rr * cos(t), rr * sin(t)), Point2((rr + len) * cos(t), (rr + len) * sin(t)), width: 2.5, P.marking)
        }
        for a in [45.0, -45] {
            b.save(); b.rotate(GaugeMath.dial(a) - .pi / 2)
            b.fill([Point2(0, rr), Point2(-6, rr + 13), Point2(6, rr + 13)], P.marking)
            b.restore()
        }
        b.fill([Point2(0, rr), Point2(-10, rr + 18), Point2(10, rr + 18)], P.marking)
        b.rotate(d.rollDeg * .pi / 180)
        b.fill([Point2(0, rr - 2), Point2(-11, rr - 20), Point2(11, rr - 20)], P.marking)
        let slip = max(-1, min(1, d.slipBall)) * 18
        b.fill([Point2(-13 + slip, rr - 24), Point2(13 + slip, rr - 24), Point2(15 + slip, rr - 31), Point2(-15 + slip, rr - 31)], P.marking)
        b.restore()

        // Aircraft symbol.
        b.save(); b.translate(cx, cy)
        for side in [-1.0, 1.0] {
            let bar: [Point2] = [Point2(side * 70, 4), Point2(side * 150, 4), Point2(side * 150, -4), Point2(side * 70, -4)]
            b.fill(bar.map { Point2($0.x, $0.y - 1.5) }, RGBA(0, 0, 0, 0.6))
            b.fill(bar, P.yellow)
            b.fill([Point2(side * 70, 4), Point2(side * 70, -16), Point2(side * 78, -16), Point2(side * 78, 4)], P.yellow)
        }
        b.fill([Point2(0, 0), Point2(-46, -26), Point2(-30, -26), Point2(0, -10), Point2(30, -26), Point2(46, -26)], P.yellow)
        b.rect(-4, -4, 4, 4, P.yellow)
        b.restore()

        speedTape(&b, d, o, x: 150, y: cy, height: 400)
        altitudeTape(&b, d, o, x: width - 270, y: cy, height: 400)
        vsiScale(&b, d, x: width - 150, y: cy)
        hsi(&b, d, o, center: Point2(cx, 132), radius: 150)

        // Top data strip.
        b.rect(0, height - 34, width, height, RGBA(hex: 0x111317, alpha: 0.92))
        b.text("SF-1000", at: Point2(16, height - 24), size: 14, align: .left, P.marking.withAlpha(0.8))
        b.text(String(format: "GS %3.0fKT", d.groundSpeedKt), at: Point2(cx - 120, height - 24), size: 14, P.marking)
        b.text(String(format: "FLAPS %2.0f°", d.flapsFraction * 30), at: Point2(cx + 120, height - 24), size: 14, P.marking)
        b.text(String(format: "RPM %4.0f", d.rpm), at: Point2(width - 16, height - 24), size: 14, align: .right, P.marking)
        b.popClip()
        return b.list
    }

    static func speedTape(_ b: inout DrawBuilder, _ d: InstrumentData, _ o: PFDOptions, x: Double, y: Double, height h: Double) {
        let w = 100.0, ppk = 4.4
        let v = d.indicatedAirspeedKt
        b.rect(x, y - h / 2, x + w, y + h / 2, tapeBG)
        b.pushClipRect(x, y - h / 2, x + w, y + h / 2)
        let lo = Int((v - h / 2 / ppk) / 5) * 5 - 5, hi = Int((v + h / 2 / ppk) / 5) * 5 + 5
        for s in stride(from: max(0, lo), through: hi, by: 5) {
            let yy = y + (Double(s) - v) * ppk
            let major = s % 10 == 0
            b.line(Point2(x + w - (major ? 20 : 11), yy), Point2(x + w, yy), width: 2, P.marking)
            if major && s >= 20 { b.text(String(s), at: Point2(x + w - 28, yy - 8), size: 16, align: .right, weight: 0.15, P.marking) }
        }
        // V-speed bands on the right edge.
        let vs = o.vSpeeds
        func band(_ a: Double, _ c: Double, _ x0: Double, _ x1: Double, _ col: RGBA) {
            b.rect(x0, y + (a - v) * ppk, x1, y + (c - v) * ppk, col)
        }
        band(vs.vso, vs.vfe, x + w - 6, x + w - 2, P.marking)
        band(vs.vs1, vs.vno, x + w - 10, x + w - 6, P.green)
        band(vs.vno, vs.vne, x + w - 10, x + w - 6, P.yellow)
        band(vs.vne, vs.vne + 200, x + w - 10, x + w - 2, P.red)
        band(0, vs.vso, x + w - 10, x + w - 6, P.red.withAlpha(0.7))
        b.popClip()
        // Readout.
        let bh = 25.0
        b.fill([Point2(x + 6, y - bh), Point2(x + w - 14, y - bh), Point2(x + w - 14, y - 9), Point2(x + w - 2, y),
                Point2(x + w - 14, y + 9), Point2(x + w - 14, y + bh), Point2(x + 6, y + bh)], .black)
        b.stroke([Point2(x + 6, y - bh), Point2(x + w - 14, y - bh), Point2(x + w - 14, y - 9), Point2(x + w - 2, y),
                  Point2(x + w - 14, y + 9), Point2(x + w - 14, y + bh), Point2(x + 6, y + bh), Point2(x + 6, y - bh)], width: 2, P.marking)
        b.text(String(Int(v.rounded())), at: Point2(x + w - 22, y - 12), size: 24, align: .right, weight: 0.14, P.marking)
        b.rect(x, y + h / 2, x + w, y + h / 2 + 30, RGBA(hex: 0x111317))
        b.text(String(format: "TAS %.0fKT", d.trueAirspeedKt), at: Point2(x + w / 2, y + h / 2 + 9), size: 12, P.marking)
    }

    static func altitudeTape(_ b: inout DrawBuilder, _ d: InstrumentData, _ o: PFDOptions, x: Double, y: Double, height h: Double) {
        let w = 110.0, ppf = 0.4
        let alt = d.indicatedAltitudeFt
        b.rect(x, y - h / 2, x + w, y + h / 2, tapeBG)
        b.pushClipRect(x, y - h / 2, x + w, y + h / 2)
        let lo = Int((alt - h / 2 / ppf) / 20) * 20 - 20, hi = Int((alt + h / 2 / ppf) / 20) * 20 + 20
        for a in stride(from: lo, through: hi, by: 20) {
            let yy = y + (Double(a) - alt) * ppf
            let major = a % 100 == 0
            b.line(Point2(x, yy), Point2(x + (major ? 20 : 9), yy), width: 2, P.marking)
            if major { b.text(String(a), at: Point2(x + 28, yy - 8), size: 16, align: .left, weight: 0.15, P.marking) }
        }
        if let sel = o.selectedAltitudeFt {
            let yy = max(y - h / 2, min(y + h / 2, y + (sel - alt) * ppf))
            b.fill([Point2(x, yy - 14), Point2(x + 10, yy - 14), Point2(x + 10, yy - 5), Point2(x + 4, yy), Point2(x + 10, yy + 5),
                    Point2(x + 10, yy + 14), Point2(x, yy + 14)], cyan)
        }
        b.popClip()
        let bh = 25.0
        let box = [Point2(x + 2, y), Point2(x + 14, y + 9), Point2(x + 14, y + bh), Point2(x + w - 4, y + bh),
                   Point2(x + w - 4, y - bh), Point2(x + 14, y - bh), Point2(x + 14, y - 9)]
        b.fill(box, .black)
        b.stroke(box + [box[0]], width: 2, P.marking)
        b.text(String(Int((alt / 10).rounded() * 10)), at: Point2(x + w - 12, y - 11), size: 22, align: .right, weight: 0.14, P.marking)
        if let sel = o.selectedAltitudeFt {
            b.rect(x, y + h / 2, x + w, y + h / 2 + 32, RGBA(hex: 0x111317))
            b.text(String(Int(sel)), at: Point2(x + w / 2, y + h / 2 + 9), size: 16, cyan)
        }
        b.rect(x, y - h / 2 - 32, x + w, y - h / 2, RGBA(hex: 0x111317))
        b.text(String(format: "%.2fIN", d.kollsmanInHg), at: Point2(x + w / 2, y - h / 2 - 22), size: 14, cyan)
    }

    static func vsiScale(_ b: inout DrawBuilder, _ d: InstrumentData, x: Double, y: Double) {
        let w = 46.0, half = 150.0
        func pos(_ fpm: Double) -> Double {
            let a = min(2_000, abs(fpm))
            let f = a <= 1_000 ? 0.62 * a / 1_000 : 0.62 + 0.38 * (a - 1_000) / 1_000
            return y + (fpm < 0 ? -1 : 1) * f * half
        }
        b.fill([Point2(x, y - half - 10), Point2(x + w, y - half - 10), Point2(x + w, y + half + 10), Point2(x, y + half + 10)], tapeBG)
        for v in stride(from: -2_000.0, through: 2_000, by: 500) {
            let major = v.truncatingRemainder(dividingBy: 1_000) == 0
            b.line(Point2(x, pos(v)), Point2(x + (major ? 14 : 8), pos(v)), width: 2, P.marking)
            if major && v != 0 { b.text(String(Int(abs(v) / 1_000)), at: Point2(x + 26, pos(v) - 6), size: 13, P.marking) }
        }
        let py = pos(d.verticalSpeedFpm)
        let box = [Point2(x + 2, py), Point2(x + 12, py + 11), Point2(x + 62, py + 11), Point2(x + 62, py - 11), Point2(x + 12, py - 11)]
        b.fill(box, .black)
        b.stroke(box + [box[0]], width: 1.5, P.marking)
        let shown = Int((d.verticalSpeedFpm / 50).rounded() * 50)
        b.text(String(shown), at: Point2(x + 58, py - 6), size: 12, align: .right, P.marking)
    }

    static func hsi(_ b: inout DrawBuilder, _ d: InstrumentData, _ o: PFDOptions, center c: Point2, radius r: Double) {
        b.circle(c, r + 6, RGBA(0.05, 0.06, 0.08, 0.72))
        b.save(); b.translate(c.x, c.y); b.rotate(d.headingDeg * .pi / 180)
        for i in 0..<72 {
            let major = i % 2 == 0
            let t = GaugeMath.dial(Double(i) * 5)
            let r0 = r - (major ? 16 : 9)
            b.line(Point2(r0 * cos(t), r0 * sin(t)), Point2(r * cos(t), r * sin(t)), width: 2, P.marking)
        }
        let names = ["N", "3", "6", "E", "12", "15", "S", "21", "24", "W", "30", "33"]
        for (i, n) in names.enumerated() {
            b.save(); b.rotate(-Double(i) * 30 * .pi / 180)
            b.text(n, at: Point2(0, r - 40), size: i % 3 == 0 ? 18 : 15, weight: 0.15, P.marking)
            b.restore()
        }
        if let sel = o.selectedHeadingDeg {
            b.save(); b.rotate(-sel * .pi / 180)
            b.fill([Point2(-11, r), Point2(-11, r + 8), Point2(11, r + 8), Point2(11, r), Point2(5, r), Point2(0, r - 6), Point2(-5, r)], cyan)
            b.restore()
        }
        b.restore()
        // Aircraft symbol and lubber line.
        b.save(); b.translate(c.x, c.y)
        b.fill([Point2(0, 26), Point2(4, 18), Point2(4, 6), Point2(24, -2), Point2(24, -6), Point2(4, -3), Point2(3, -18),
                Point2(10, -23), Point2(10, -26), Point2(-10, -26), Point2(-10, -23), Point2(-3, -18), Point2(-4, -3),
                Point2(-24, -6), Point2(-24, -2), Point2(-4, 6), Point2(-4, 18)], P.marking)
        b.fill([Point2(0, r - 2), Point2(-8, r + 12), Point2(8, r + 12)], P.marking)
        b.restore()
        // Heading readout.
        let bx = c.x, by = c.y + r + 26
        b.rect(bx - 34, by - 15, bx + 34, by + 15, .black)
        b.rectOutline(bx - 34, by - 15, bx + 34, by + 15, width: 2, P.marking)
        var h = Int(d.headingDeg.rounded()) % 360
        if h == 0 { h = 360 }
        b.text(String(format: "%03d°", h), at: Point2(bx, by - 8), size: 16, weight: 0.15, P.marking)
    }
}
