// SKYFORGE — Apache-2.0
// The player's damage model: airframe, engine and control-surface health, and a tally of combat
// statistics. Pure value types, deterministic, no clock and no randomness.
import Foundation

public enum DamageSource: String, Sendable, Codable, CaseIterable {
    case cannon, missile, collision
}

public enum DamageZone: String, Sendable, Codable, CaseIterable {
    case airframe, engine, controls
}

public struct AircraftDamage: Sendable, Equatable {
    public private(set) var airframe: Double = 1      // 1 intact, 0 destroyed
    public private(set) var engine: Double = 1        // 1 full thrust
    public private(set) var controls: Double = 1      // 1 full control authority
    public private(set) var lastSource: DamageSource? = nil

    public init() {}

    public static let cannonRoundDamage = 0.02        // airframe severity per cannon round hit
    public static let missileWarheadDamage = 0.5      // airframe severity per missile warhead hit
    public static let collisionDamage = 1.0           // airframe severity for a collision

    /// True when the airframe is at or below zero. A NaN airframe counts as destroyed.
    public var destroyed: Bool { !(airframe > 0) }

    /// True when the engine is at or below 0.1.
    public var engineOut: Bool { engine <= 0.1 }

    /// 0...1. Zero when engineOut, otherwise min(1, engine).
    public var thrustFactor: Double { engineOut ? 0 : min(1, engine) }

    /// Control authority, never below 0.2 so a damaged aircraft can still be flown.
    public var controlFactor: Double { max(0.2, min(1, controls)) }

    /// Applies a hit. `amount` is the hit's severity (>= 0). Non-finite or negative amounts are ignored.
    /// Airframe hits take amount x 1; engine and controls hits take amount x 2 from their zone and
    /// amount x 0.25 from the airframe. Values are clamped to 0...1 (tiny residues from repeated
    /// subtraction snap to 0). Returns true only on the hit that takes the airframe from alive to destroyed.
    public mutating func apply(source: DamageSource, zone: DamageZone, amount: Double) -> Bool {
        guard amount.isFinite, amount >= 0 else { return false }
        if destroyed { return false }
        switch zone {
        case .airframe:
            airframe = Self.clamp(airframe - amount)
        case .engine:
            engine = Self.clamp(engine - amount * 2)
            airframe = Self.clamp(airframe - amount * 0.25)
        case .controls:
            controls = Self.clamp(controls - amount * 2)
            airframe = Self.clamp(airframe - amount * 0.25)
        }
        lastSource = source
        return destroyed
    }

    private static func clamp(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        if value < 1e-9 { return 0 }
        if value > 1 { return 1 }
        return value
    }
}

public struct CombatTally: Sendable, Equatable, Codable {
    public var hitsTaken = 0
    public var damageTaken = 0.0            // sum of all damage amounts actually applied
    public var countermeasuresUsed = 0
    public var missilesFired = 0
    public var missilesHit = 0
    public init() {}
}
