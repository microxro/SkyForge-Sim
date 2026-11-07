// SKYFORGE — Apache-2.0
// Runway surface and simplified ICAO Annex 14 markings as flat local quads (ENU metres).
import Foundation
import SFMath

public enum RunwayPaint: Int, Sendable { case surface, shoulder, white }

public struct RunwayQuad: Sendable {
    public var corners: [SIMD2<Double>]   // 4 corners, counter-clockwise from above
    public var paint: RunwayPaint
}

public struct RunwaySpec: Sendable {
    /// Low-end threshold position (local ENU, metres) and true heading toward the high end (rad from north).
    public var threshold: SIMD2<Double>
    public var heading: Double
    public var length: Double
    public var width: Double
    public var lowDesignator: String
    public var highDesignator: String
    public init(threshold: SIMD2<Double>, heading: Double, length: Double, width: Double, lowDesignator: String, highDesignator: String) {
        self.threshold = threshold; self.heading = heading; self.length = length; self.width = width
        self.lowDesignator = lowDesignator; self.highDesignator = highDesignator
    }

    /// Designator from a magnetic-ish heading in degrees (e.g. 2 -> "36", 118 -> "12").
    public static func designator(headingDegrees h: Double) -> String {
        var n = Int((h / 10).rounded()) % 36
        if n == 0 { n = 36 }
        return n < 10 ? "0\(n)" : "\(n)"
    }
}

public enum RunwayGeometry {
    /// Seven-segment strokes for digits (segments a–g), drawn as rectangles in a 1 x 2 cell.
    static let segments: [Character: [Int]] = [
        "0": [0, 1, 2, 3, 4, 5], "1": [1, 2], "2": [0, 1, 6, 4, 3], "3": [0, 1, 6, 2, 3], "4": [5, 6, 1, 2],
        "5": [0, 5, 6, 2, 3], "6": [0, 5, 6, 4, 3, 2], "7": [0, 1, 2], "8": [0, 1, 2, 3, 4, 5, 6], "9": [0, 1, 2, 3, 5, 6],
    ]

    public static func build(_ r: RunwaySpec) -> [RunwayQuad] {
        let along = SIMD2(sin(r.heading), cos(r.heading))      // ENU: x east, y north
        let across = SIMD2(along.y, -along.x)                    // to the right of the runway direction
        func q(_ s0: Double, _ s1: Double, _ c0: Double, _ c1: Double, _ p: RunwayPaint) -> RunwayQuad {
            let o = r.threshold
            return RunwayQuad(corners: [o + along * s0 + across * c0, o + along * s0 + across * c1,
                                        o + along * s1 + across * c1, o + along * s1 + across * c0].reversed(), paint: p)
        }
        var out: [RunwayQuad] = []
        let hw = r.width / 2
        out.append(q(-60, r.length + 60, -hw - 7.5, hw + 7.5, .shoulder))
        out.append(q(0, r.length, -hw, hw, .surface))
        // Edge stripes
        out.append(q(0, r.length, -hw + 0.3, -hw + 1.2, .white))
        out.append(q(0, r.length, hw - 1.2, hw - 0.3, .white))
        func endMarkings(fromLow: Bool, designator: String) {
            // s measured from this end toward the other end.
            func qq(_ s0: Double, _ s1: Double, _ c0: Double, _ c1: Double) -> RunwayQuad {
                fromLow ? q(s0, s1, c0, c1, .white) : q(r.length - s1, r.length - s0, -c1, -c0, .white)
            }
            // Threshold stripes (8 for 30 m, 12 for 45 m widths).
            let stripes = r.width >= 45 ? 12 : (r.width >= 30 ? 8 : 6)
            let stripeW = 1.8, gap = (r.width - 6 - Double(stripes) * stripeW) / Double(stripes - 1)
            for i in 0..<stripes {
                let c0 = -hw + 3 + Double(i) * (stripeW + gap)
                out.append(qq(6, 36, c0, c0 + stripeW))
            }
            // Designator digits: 9 m tall, 3 m wide per digit.
            let digitH = 9.0, digitW = 3.0, stroke = 0.9
            let chars = Array(designator)
            let totalW = Double(chars.count) * digitW + Double(chars.count - 1) * 1.5
            for (k, ch) in chars.enumerated() {
                guard let segs = segments[ch] else { continue }
                let left = -totalW / 2 + Double(k) * (digitW + 1.5)
                let base = 48.0
                for sgm in segs {
                    // Segment rectangles in (across, along) relative to the digit cell; along grows "up" the digit.
                    let rect: (Double, Double, Double, Double)
                    switch sgm {
                    case 0: rect = (left, left + digitW, base + digitH - stroke, base + digitH)
                    case 1: rect = (left + digitW - stroke, left + digitW, base + digitH / 2, base + digitH)
                    case 2: rect = (left + digitW - stroke, left + digitW, base, base + digitH / 2)
                    case 3: rect = (left, left + digitW, base, base + stroke)
                    case 4: rect = (left, left + stroke, base, base + digitH / 2)
                    case 5: rect = (left, left + stroke, base + digitH / 2, base + digitH)
                    default: rect = (left, left + digitW, base + digitH / 2 - stroke / 2, base + digitH / 2 + stroke / 2)
                    }
                    out.append(qq(rect.2, rect.3, rect.0, rect.1))
                }
            }
            // Aiming point (300 m) and touchdown zone pairs every 150 m.
            out.append(qq(300, 345, -hw / 2 - 2, -hw / 2 + 2))
            out.append(qq(300, 345, hw / 2 - 2, hw / 2 + 2))
            for s in stride(from: 150.0, through: min(900, r.length / 2 - 50), by: 150) where s != 300 {
                for c in [-hw / 2 + 1.5, hw / 2 - 3.3] { out.append(qq(s, s + 22.5, c, c + 1.8)) }
            }
        }
        endMarkings(fromLow: true, designator: r.lowDesignator)
        endMarkings(fromLow: false, designator: r.highDesignator)
        // Centre-line: 30 m stripes, 20 m gaps, between the designators.
        var s = 70.0
        while s + 30 < r.length - 70 { out.append(q(s, s + 30, -0.45, 0.45, .white)); s += 50 }
        return out
    }
}
