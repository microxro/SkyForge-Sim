// SKYFORGE — Apache-2.0
// Engine character per aircraft: cylinder count sets the firing frequency, blade count sets the
// blade-pass tone, and exhaust brightness scales how much harmonic content the note has at load.
// Pure Swift so it is unit-tested on Linux.
import Foundation
import SFFlightModel

public struct EngineProfile: Sendable, Equatable {
    /// Cylinders. A 4-stroke engine fires each cylinder once every two revolutions.
    public var cylinders: Int
    /// Propeller blade count (blade-pass frequency = rev/s × blades).
    public var bladeCount: Int
    /// 0…1. Scales the harmonic content that rises with throttle (a radial is rougher than an inline).
    public var exhaustBrightness: Double

    public init(cylinders: Int, bladeCount: Int, exhaustBrightness: Double) {
        self.cylinders = max(1, cylinders)
        self.bladeCount = max(1, bladeCount)
        self.exhaustBrightness = min(max(exhaustBrightness.isFinite ? exhaustBrightness : 1, 0), 1)
    }

    /// Four-cylinder inline piston, two-blade fixed-pitch prop (the SF-1 default).
    public static let inline4 = EngineProfile(cylinders: 4, bladeCount: 2, exhaustBrightness: 1.0)
    /// Six-cylinder inline piston, two-blade prop.
    public static let inline6 = EngineProfile(cylinders: 6, bladeCount: 2, exhaustBrightness: 0.85)
    /// Nine-cylinder radial, three-blade prop. Lower firing rate, rougher harmonic content.
    public static let radial9 = EngineProfile(cylinders: 9, bladeCount: 3, exhaustBrightness: 0.6)

    /// Firing frequency in Hz at `rpm`.
    public func firingHz(_ rpm: Double) -> Double { rpm / 60 * Double(cylinders) / 2 }

    /// Blade-pass frequency in Hz at `rpm`.
    public func bladePassHz(_ rpm: Double) -> Double { rpm / 60 * Double(bladeCount) }

    /// Picks a profile from the aircraft's rated power. The flight model does not tag engine layout,
    /// so power is the proxy: light singles use the inline four, mid-size twins the inline six, and
    /// large radials the nine-cylinder.
    public static func forAircraft(_ config: AircraftConfig) -> EngineProfile {
        let p = config.maxPower.isFinite ? config.maxPower : 0
        if p < 250_000 { return .inline4 }
        if p < 500_000 { return .inline6 }
        return .radial9
    }
}
