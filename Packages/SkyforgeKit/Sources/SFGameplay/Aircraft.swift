// SKYFORGE — Apache-2.0
// Playable aircraft: the SF-1 Trainer plus original civil and military types. Every type is an
// `AircraftConfig` for the existing 6-DOF `FlightModel`; nothing here models a real aircraft.
// Jets reuse the model's power-based thrust law T = eta*P / sqrt(V^2 + V0^2): thrust is flat up to
// V0 (the knee speed) and then falls off as 1/V, which is a fair stand-in for a turbojet or turbofan
// without touching FlightDynamics.swift. The model has no compressibility, so the military types
// carry a Mach limit that the envelope monitor and flight control law enforce instead.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel

public enum AircraftRole: String, Sendable, Codable, CaseIterable {
    case lightTrainer, tourer, aerobatic, jetTrainer, fighter, bush, airliner, businessJet

    public var isMilitary: Bool { self == .jetTrainer || self == .fighter }

    public var displayName: String {
        switch self {
        case .lightTrainer: return "Light trainer"
        case .tourer: return "Tourer"
        case .aerobatic: return "Aerobatic"
        case .jetTrainer: return "Jet trainer"
        case .fighter: return "Fighter"
        case .bush: return "Bush utility"
        case .airliner: return "Airliner"
        case .businessJet: return "Business jet"
        }
    }
}

/// Operating limits used by the envelope monitor and the fly-by-wire control law.
public struct EnvelopeLimits: Sendable, Codable, Equatable {
    public var vne: Double          // never-exceed true airspeed (m/s)
    public var mmo: Double          // maximum operating Mach number
    public var vfe: Double          // maximum airspeed with flaps extended (m/s)
    public var nzMax: Double        // positive load factor limit (g)
    public var nzMin: Double        // negative load factor limit (g, negative)
    public var alphaLimit: Double   // angle-of-attack limit for the control law (rad)
    public init(vne: Double, mmo: Double, vfe: Double, nzMax: Double, nzMin: Double, alphaLimit: Double) {
        self.vne = vne; self.mmo = mmo; self.vfe = vfe; self.nzMax = nzMax; self.nzMin = nzMin; self.alphaLimit = alphaLimit
    }
}

public enum UnlockRequirement: Sendable, Codable, Equatable {
    case none
    case mission(String)     // complete this mission id
    case medals(Int)         // earn this many medals in total
}

public struct PlaneSpec: Sendable, Codable, Equatable, Identifiable {
    public var config: AircraftConfig
    public var role: AircraftRole
    public var summary: String
    public var limits: EnvelopeLimits
    public var cruiseSpeed: Double      // m/s TAS, default spawn speed in flight
    public var approachSpeed: Double    // m/s, final approach with approach flaps
    public var rotateSpeed: Double      // m/s
    public var approachFlaps: Double    // 0...1
    public var flyByWire: Bool
    public var armament: [WeaponKind]
    public var unlock: UnlockRequirement

    public var id: String { config.id }
    public var name: String { config.name }
    public var isMilitary: Bool { role.isMilitary }
    public var model: FlightModel { FlightModel(config: config) }

    /// Lowest point of the gear below the centre of gravity (m).
    public var gearHeight: Double { config.gear.map { $0.position.z }.max() ?? 1.0 }

    public func stallSpeed(altitude: Double = 0, flaps: Double = 0) -> Double {
        model.designStallSpeed(altitude: altitude, flaps: flaps)
    }

    /// Headline numbers for the selection screen.
    public struct Highlights: Sendable, Equatable {
        public var stallKnots: Double
        public var cruiseKnots: Double
        public var neverExceedKnots: Double
        public var massKg: Double
        public var maxG: Double
    }

    public var highlights: Highlights {
        Highlights(stallKnots: stallSpeed(flaps: 1) * Conv.msToKnots,
                   cruiseKnots: cruiseSpeed * Conv.msToKnots,
                   neverExceedKnots: limits.vne * Conv.msToKnots,
                   massKg: config.mass, maxG: limits.nzMax)
    }
}

enum Conv {
    static let msToKnots = 1.0 / 0.514_444
    static let knotsToMS = 0.514_444
    static let feetToMetres = 0.3048
    static let metresToFeet = 1.0 / 0.3048
    static let fpmToMS = 0.3048 / 60
}

/// The built-in fleet.
public enum AircraftCatalog {
    public static let sf1Trainer = PlaneSpec(
        config: .sf1Trainer, role: .lightTrainer,
        summary: "Docile two-seat trainer. Forgiving stall, gentle handling: the place to start.",
        limits: EnvelopeLimits(vne: 62, mmo: 0.3, vfe: 36, nzMax: 4.4, nzMin: -1.8, alphaLimit: 0.30),
        cruiseSpeed: 46, approachSpeed: 34, rotateSpeed: 28, approachFlaps: 0.5,
        flyByWire: false, armament: [], unlock: .none)

    public static let sfCruiser = PlaneSpec(
        config: .sf2Cruiser, role: .tourer,
        summary: "Retractable-gear tourer with a constant-speed prop. Stable and efficient.",
        limits: EnvelopeLimits(vne: 74, mmo: 0.3, vfe: 40, nzMax: 3.8, nzMin: -1.5, alphaLimit: 0.30),
        cruiseSpeed: 52, approachSpeed: 38, rotateSpeed: 30, approachFlaps: 0.5,
        flyByWire: false, armament: [], unlock: .none)

    /// Twin-engine passenger aircraft from the flight-model catalog (org.skyforge.sf3).
    public static let sfTwin = PlaneSpec(
        config: .sf3Twin, role: .tourer,
        summary: "Six-seat twin-engine airliner. Stable at low speed, with power for a heavy load.",
        limits: EnvelopeLimits(vne: 100, mmo: 0.3, vfe: 55, nzMax: 3.8, nzMin: -1.5, alphaLimit: 0.30),
        cruiseSpeed: 70, approachSpeed: 48, rotateSpeed: 42, approachFlaps: 0.5,
        flyByWire: false, armament: [], unlock: .mission("precision-landing"))

    public static let sfAerobat: PlaneSpec = {
        var c = AircraftConfig.sf1Trainer
        c.id = "org.skyforge.sfa"; c.name = "SF-A Aerobat"
        c.mass = 800; c.inertia = SIMD3(760, 1_150, 1_680)
        c.wingArea = 12.0; c.wingSpan = 9.0; c.chord = 1.35
        c.maxPower = 150_000; c.staticThrustPerWatt = 0.022
        c.elevatorMax = 30 * .pi / 180; c.aileronMax = 22 * .pi / 180
        c.aero.cL0 = 0.1; c.aero.cLMaxClean = 1.45; c.aero.cLMaxFlaps = 1.8
        c.aero.cD0 = 0.028; c.aero.oswald = 0.8; c.aero.cmAlpha = -0.8
        c.gear = fleetGear(massFactor: 0.8, nose: SIMD3(1.15, 0, 1.15), main: SIMD3(-0.25, 1.0, 1.15))
        return PlaneSpec(
            config: c, role: .aerobatic,
            summary: "Light, powerful and quick to roll. Rated +6 / -3 g for loops, rolls and spins.",
            limits: EnvelopeLimits(vne: 92, mmo: 0.3, vfe: 40, nzMax: 6.0, nzMin: -3.0, alphaLimit: 0.30),
            cruiseSpeed: 60, approachSpeed: 36, rotateSpeed: 30, approachFlaps: 0.5,
            flyByWire: false, armament: [], unlock: .mission("first-flight"))
    }()

    public static let sfT1Jet = PlaneSpec(
        config: .sf5Jet, role: .jetTrainer,
        summary: "Twin-seat advanced jet trainer. Fast, agile, with a fly-by-wire g limiter.",
        limits: EnvelopeLimits(vne: 226, mmo: 0.85, vfe: 100, nzMax: 7.3, nzMin: -3.0, alphaLimit: 0.26),
        cruiseSpeed: 150, approachSpeed: 66, rotateSpeed: 62, approachFlaps: 1.0,
        flyByWire: true, armament: [.cannon], unlock: .mission("pattern-landing"))

    public static let sfF1Fighter = PlaneSpec(
        config: .sf9Fighter, role: .fighter,
        summary: "Single-seat supersonic interceptor: afterburner, +9 g, cannon, heat-seeking and radar missiles.",
        limits: EnvelopeLimits(vne: 450, mmo: 1.6, vfe: 120, nzMax: 9.0, nzMin: -3.0, alphaLimit: 0.30),
        cruiseSpeed: 220, approachSpeed: 80, rotateSpeed: 80, approachFlaps: 1.0,
        flyByWire: true, armament: [.cannon, .heatMissile, .radarMissile], unlock: .mission("wingman-formation"))

    /// High-wing bush utility (org.skyforge.sfb): short field, slow, carries three.
    public static let sfBushcat = PlaneSpec(
        config: .sfBushcat, role: .bush,
        summary: "High-wing bush utility. Lands short and slow on rough strips, and carries three.",
        limits: EnvelopeLimits(vne: 80, mmo: 0.3, vfe: 45, nzMax: 3.8, nzMin: -1.5, alphaLimit: 0.30),
        cruiseSpeed: 50, approachSpeed: 33, rotateSpeed: 26, approachFlaps: 0.5,
        flyByWire: false, armament: [], unlock: .medals(4))

    /// Twin-jet business aircraft (org.skyforge.sfe): eight seats, smooth and fast.
    public static let sfExecutive = PlaneSpec(
        config: .sfExecutive, role: .businessJet,
        summary: "Eight-seat business jet. Fast over long range, with a smooth ride.",
        limits: EnvelopeLimits(vne: 270, mmo: 0.80, vfe: 130, nzMax: 2.5, nzMin: -1.0, alphaLimit: 0.26),
        cruiseSpeed: 210, approachSpeed: 66, rotateSpeed: 60, approachFlaps: 1.0,
        flyByWire: false, armament: [], unlock: .medals(8))

    public static let all: [PlaneSpec] = [sf1Trainer, sfCruiser, sfTwin, sfAerobat, sfT1Jet, sfF1Fighter, sfBushcat, sfExecutive]

    public static func spec(id: String) -> PlaneSpec? { all.first { $0.id == id } }
    public static var civil: [PlaneSpec] { all.filter { !$0.isMilitary } }
    public static var military: [PlaneSpec] { all.filter { $0.isMilitary } }

    /// Tricycle gear scaled with mass so the spring and damper keep the SF-1's natural frequency and damping ratio.
    static func fleetGear(massFactor f: Double, nose: SIMD3<Double>, main: SIMD3<Double>) -> [GearLeg] {
        [GearLeg(position: nose, stiffness: 45_000 * f, damping: 4_500 * f, steerable: true, braked: false),
         GearLeg(position: SIMD3(main.x, -main.y, main.z), stiffness: 70_000 * f, damping: 6_000 * f, steerable: false, braked: true),
         GearLeg(position: SIMD3(main.x, main.y, main.z), stiffness: 70_000 * f, damping: 6_000 * f, steerable: false, braked: true)]
    }
}
