// SKYFORGE — Apache-2.0
// Airframe icing: a single ice-severity index (0 clean … 1 heavily iced) that grows in supercooled liquid
// water and melts above freezing. The index reduces CLmax and lift-curve slope and adds profile drag.
// The orchestrator integrates the index and passes it to `FlightEnvironment.iceIndex`. Shedding, ice
// shape and the stall-warning change are not modelled. Coefficients are order-of-magnitude engineering
// estimates, not certification data.
import Foundation

public enum IcingModel {
    /// Index gained per second at 1 g/m^3 liquid water and 100 m/s true airspeed.
    public static let accretionRate = 0.02
    /// Index lost per second above freezing.
    public static let meltRate = 0.005
    /// Fractional CLmax loss at full ice.
    public static let clMaxLoss = 0.35
    /// Fractional lift-curve-slope loss at full ice.
    public static let liftSlopeLoss = 0.10
    /// Profile-drag coefficient added at full ice.
    public static let dragAtFullIce = 0.03

    /// Advances the ice index by `dt` seconds.
    /// - Parameters:
    ///   - liquidWater: supercooled liquid water content (g/m^3), 0 outside cloud.
    ///   - tas: true airspeed (m/s).
    ///   - temperatureK: static air temperature (K).
    public static func step(index: Double, liquidWater: Double, tas: Double, temperatureK: Double, dt: Double) -> Double {
        let i = index.isFinite ? min(1, max(0, index)) : 0
        guard dt.isFinite, dt > 0 else { return i }
        if temperatureK >= 273.15 {
            return max(0, i - meltRate * dt)
        }
        let lwc = liquidWater.isFinite ? max(0, liquidWater) : 0
        let speed = tas.isFinite ? max(0, tas) : 0
        let rate = accretionRate * lwc * (speed / 100)
        return min(1, i + rate * dt)
    }

    /// Multiplier on CLmax for an ice index.
    public static func clMaxFactor(_ index: Double) -> Double { 1 - clMaxLoss * clamp01(index) }
    /// Multiplier on the lift-curve slope for an ice index.
    public static func liftSlopeFactor(_ index: Double) -> Double { 1 - liftSlopeLoss * clamp01(index) }
    /// Extra profile drag for an ice index.
    public static func dragIncrement(_ index: Double) -> Double { dragAtFullIce * clamp01(index) }

    private static func clamp01(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
}
