// SKYFORGE — Apache-2.0
// Aircraft definition for the original "SF-1 Trainer". Coefficients come from textbook estimation
// methods for a high-wing, single piston-engine light aircraft (stability-derivative build-up as in
// public-domain NACA/NASA practice). Not a model of any real type.
import Foundation

public struct AeroCoefficients: Sendable, Codable, Equatable {
    // Lift
    public var cL0: Double = 0.31
    public var cLAlpha: Double = 5.14          // per rad
    public var cLQ: Double = 3.9               // per rad (q c / 2V)
    public var cLElevator: Double = 0.43       // per rad
    public var cLFlap: Double = 0.55           // full flap increment
    public var cLMaxClean: Double = 1.55
    public var cLMaxFlaps: Double = 2.05
    // Drag
    public var cD0: Double = 0.031
    public var cDFlap: Double = 0.045          // full flap increment
    public var cDGear: Double = 0.0            // fixed gear included in cD0
    public var oswald: Double = 0.75
    // Side force
    public var cYBeta: Double = -0.31
    public var cYRudder: Double = 0.187
    // Pitch
    public var cm0: Double = 0.02
    public var cmAlpha: Double = -0.89
    public var cmQ: Double = -12.4
    public var cmAlphaDot: Double = -5.2
    public var cmElevator: Double = -1.28
    public var cmFlap: Double = -0.05
    // Roll
    public var clBeta: Double = -0.089
    public var clP: Double = -0.47
    public var clR: Double = 0.096
    public var clAileron: Double = 0.178
    public var clRudder: Double = 0.0147
    // Yaw
    public var cnBeta: Double = 0.065
    public var cnP: Double = -0.03
    public var cnR: Double = -0.099
    public var cnAileron: Double = -0.053
    public var cnRudder: Double = -0.0657

    public init() {}
}

public struct GearLeg: Sendable, Codable, Equatable {
    /// Contact point in body axes (x forward, y right, z down), metres from CG, gear extended and unloaded.
    public var position: SIMD3<Double>
    public var stiffness: Double      // N/m
    public var damping: Double        // N s/m
    public var steerable: Bool
    public var braked: Bool
    public init(position: SIMD3<Double>, stiffness: Double, damping: Double, steerable: Bool, braked: Bool) {
        self.position = position; self.stiffness = stiffness; self.damping = damping
        self.steerable = steerable; self.braked = braked
    }
}

public struct AircraftConfig: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var mass: Double                 // kg
    public var inertia: SIMD3<Double>       // Ixx, Iyy, Izz (kg m^2)
    public var ixz: Double                  // kg m^2
    public var wingArea: Double             // m^2
    public var wingSpan: Double             // m
    public var chord: Double                // m
    public var aero: AeroCoefficients
    public var maxPower: Double             // W at sea level
    public var propDiameter: Double         // m
    public var maxRPM: Double
    public var staticThrustPerWatt: Double  // N/W at full throttle, standstill
    public var stallAlpha: Double           // rad, clean
    public var elevatorMax: Double          // rad
    public var aileronMax: Double           // rad
    public var rudderMax: Double            // rad
    public var flapMax: Double              // rad (for display)
    public var gear: [GearLeg]
    public var groundEffectSpanHeightRatio: Double = 1.0

    public var aspectRatio: Double { wingSpan * wingSpan / wingArea }

    /// The original SF-1 Trainer: ~1,000 kg two-seat trainer, 120 kW piston engine, fixed-pitch prop.
    public static let sf1Trainer = AircraftConfig(
        id: "org.skyforge.sf1", name: "SF-1 Trainer",
        mass: 1_000, inertia: SIMD3(1_285, 1_825, 2_667), ixz: 0,
        wingArea: 16.2, wingSpan: 11.0, chord: 1.49,
        aero: AeroCoefficients(),
        maxPower: 120_000, propDiameter: 1.9, maxRPM: 2_700,
        staticThrustPerWatt: 0.020,
        stallAlpha: 16 * .pi / 180,
        elevatorMax: 25 * .pi / 180, aileronMax: 18 * .pi / 180, rudderMax: 20 * .pi / 180,
        flapMax: 30 * .pi / 180,
        gear: [
            GearLeg(position: SIMD3(1.30, 0, 1.25), stiffness: 45_000, damping: 4_500, steerable: true, braked: false),
            GearLeg(position: SIMD3(-0.30, -1.10, 1.25), stiffness: 70_000, damping: 6_000, steerable: false, braked: true),
            GearLeg(position: SIMD3(-0.30, 1.10, 1.25), stiffness: 70_000, damping: 6_000, steerable: false, braked: true),
        ]
    )
}
