// SKYFORGE — Apache-2.0
// Steam catapult launch. The shuttle has a fixed stroke and accelerates the aircraft at a constant
// setting (in g). The exit speed over the deck plus the headwind gives the airspeed at the bow.
import Foundation

public enum CatapultOutcome: String, Sendable, Codable, Equatable {
    case safe               // flying speed at the bow, within the g limit
    case insufficientEnergy // airspeed at the bow below flying speed: the aircraft sinks off the bow
    case overStress         // enough energy, but the setting exceeds the airframe launch limit
}

public struct CatapultLaunch: Sendable, Codable, Equatable {
    public static let strokeLength: Double = 94      // m, shuttle stroke
    public static let maxLaunchG: Double = 4.0       // launch acceleration limit, g
    public static let gravity: Double = 9.80665

    public var settingG: Double         // crew-set acceleration for this shot, g (non-finite becomes 0)
    public var exitDeckSpeed: Double    // m/s over the deck at the bow
    public var exitAirspeed: Double     // m/s airspeed at the bow (deck speed plus headwind)
    public var outcome: CatapultOutcome

    /// Fly a shot. `takeoffAirspeed` is the flying speed the aircraft needs at the bow, with margin, in m/s.
    public static func fly(settingG: Double, headwind: Double, takeoffAirspeed: Double) -> CatapultLaunch {
        let g = settingG.isFinite ? max(0, settingG) : 0
        let wind = headwind.isFinite ? headwind : 0
        let exitDeck = (2 * g * gravity * strokeLength).squareRoot()
        let exitAir = exitDeck + wind
        let outcome: CatapultOutcome
        // A 1e-9 m/s allowance keeps an exactly-computed setting from failing on float rounding.
        if !(exitAir + 1e-9 >= takeoffAirspeed) {
            outcome = .insufficientEnergy
        } else if g > maxLaunchG {
            outcome = .overStress
        } else {
            outcome = .safe
        }
        return CatapultLaunch(settingG: g, exitDeckSpeed: exitDeck, exitAirspeed: exitAir, outcome: outcome)
    }

    /// The setting (g) that gives exactly `takeoffAirspeed` at the bow in the given headwind.
    /// The deck crew uses this as the base, then adds margin.
    public static func requiredSettingG(headwind: Double, takeoffAirspeed: Double) -> Double {
        let wind = headwind.isFinite ? headwind : 0
        let needed = max(0, takeoffAirspeed - wind)
        return needed * needed / (2 * gravity * strokeLength)
    }
}
