// SKYFORGE — Apache-2.0
// Needle and card angles. Angles are clockwise from 12 o'clock, in degrees, as a pilot
// reads a dial; conversion to builder radians happens in the drawing code.
import Foundation

public enum GaugeMath {
    /// ASI: 0–40 kt compressed into the first 30°, 40–200 kt linear over 30°–340°.
    public static func airspeedAngle(_ kt: Double) -> Double {
        let v = max(0, min(205, kt))
        if v <= 40 { return v / 40 * 30 }
        return 30 + (v - 40) / 160 * 310
    }

    /// Altimeter hands (100 ft, 1,000 ft, 10,000 ft), each a full turn per 1,000/10,000/100,000 ft.
    public static func altimeterHands(_ ft: Double) -> (hundreds: Double, thousands: Double, tenThousands: Double) {
        func wrap(_ a: Double) -> Double { let r = a.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }
        return (wrap(ft / 1_000 * 360), wrap(ft / 10_000 * 360), wrap(ft / 100_000 * 360))
    }

    /// VSI: 0 at 9 o'clock (−90°). ±1,000 fpm uses 60 % of the ±170° swing, the rest to ±2,000.
    public static func verticalSpeedAngle(_ fpm: Double) -> Double {
        let v = max(-2_000, min(2_000, fpm))
        let a = abs(v)
        let f = a <= 1_000 ? 0.6 * a / 1_000 : 0.6 + 0.4 * (a - 1_000) / 1_000
        return -90 + (v < 0 ? -1 : 1) * 170 * f
    }

    /// Turn coordinator miniature-aircraft bank: standard rate (3°/s) aligns with the 20° index.
    public static func turnCoordinatorBank(_ degPerSec: Double) -> Double {
        max(-40, min(40, degPerSec / 3 * 20))
    }

    /// Tachometer: 0–3,500 RPM over 250°, starting at 7 o'clock (−125°).
    public static func tachAngle(_ rpm: Double) -> Double {
        -125 + max(0, min(3_500, rpm)) / 3_500 * 250
    }

    /// Clockwise-from-12 degrees → counter-clockwise-from-3-o'clock radians (builder space).
    @inline(__always) public static func dial(_ cwDeg: Double) -> Double { (90 - cwDeg) * .pi / 180 }
}
