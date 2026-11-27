// SKYFORGE — Apache-2.0
// Additional original aircraft for the flight model. Coefficients come from textbook estimation
// (stability-derivative build-up, public-domain NACA/NASA practice) and are not models of real types.
// Gameplay metadata (names, loadouts, missions) lives in SFGameplay; these are flight-model data only.
import Foundation
import SFMath

extension AircraftConfig {
    /// All flight-model aircraft in this catalog.
    public static var catalog: [AircraftConfig] { [sf1Trainer, sf2Cruiser, sf3Twin, sf5Jet, sf9Fighter, sfBushcat, sfExecutive] }

    /// Looks up a catalog aircraft by id.
    public static func catalogEntry(id: String) -> AircraftConfig? { catalog.first { $0.id == id } }

    /// SF-C Cruiser (sf2Cruiser): ~1,500 kg retractable-gear single, 224 kW constant-speed propeller.
    public static let sf2Cruiser: AircraftConfig = {
        var a = AeroCoefficients()
        a.cL0 = 0.28; a.cLAlpha = 5.0; a.cLMaxClean = 1.45; a.cLMaxFlaps = 1.95
        a.cD0 = 0.024; a.cDGear = 0.020; a.cDFlap = 0.050; a.oswald = 0.78
        a.cmAlpha = -1.0; a.cmElevator = -1.35
        var p = PropulsionConfig(kind: .piston, engineCount: 1)
        p.powerPerEngine = 224_000; p.staticThrustPerWatt = 0.030; p.propEfficiency = 0.82
        p.maxRPM = 2_500; p.propTorqueRoll = 0.1; p.pFactorArm = 0.25
        var c = AircraftConfig(
            id: "org.skyforge.sfc", name: "SF-C Cruiser",
            mass: 1_500, inertia: SIMD3(1_650, 2_600, 3_850), ixz: 0,
            wingArea: 16.8, wingSpan: 10.2, chord: 1.65,
            aero: a,
            maxPower: 224_000, propDiameter: 2.0, maxRPM: 2_500,
            staticThrustPerWatt: 0.030,   // static T/W ~0.3, as for a light piston single
            stallAlpha: 15 * .pi / 180,
            elevatorMax: 25 * .pi / 180, aileronMax: 18 * .pi / 180, rudderMax: 20 * .pi / 180,
            flapMax: 30 * .pi / 180,
            gear: [
                GearLeg(position: SIMD3(1.55, 0, 1.30), stiffness: 55_000, damping: 6_550, steerable: true, braked: false),
                GearLeg(position: SIMD3(-0.35, -1.35, 1.30), stiffness: 90_000, damping: 7_250, steerable: false, braked: true),
                GearLeg(position: SIMD3(-0.35, 1.35, 1.30), stiffness: 90_000, damping: 7_250, steerable: false, braked: true),
            ],
            propulsion: p,
            stall: StallBehavior(autorotation: 1.3, wingDropGain: 0.12, noseDrop: 0.10, spinYawReversal: 1.0),
            retractableGear: true)
        c.groundEffectSpanHeightRatio = 1.0
        return c
    }()

    /// SF-3 Twin: ~2,300 kg light piston twin, 2 x 190 kW. Engine-out yaw and windmilling drag modelled.
    public static let sf3Twin: AircraftConfig = {
        var a = AeroCoefficients()
        a.cL0 = 0.30; a.cLAlpha = 5.1; a.cLMaxClean = 1.45; a.cLMaxFlaps = 1.95
        a.cD0 = 0.027; a.cDGear = 0.018; a.cDFlap = 0.050; a.oswald = 0.78
        a.cmAlpha = -1.05; a.cmQ = -13.5; a.cmElevator = -1.3
        a.cnBeta = 0.08; a.cnR = -0.12; a.cnRudder = -0.075; a.cYRudder = 0.2
        var p = PropulsionConfig(kind: .piston, engineCount: 2, engineSpanOffset: 2.1)
        p.powerPerEngine = 190_000; p.staticThrustPerWatt = 0.030; p.propEfficiency = 0.80
        p.maxRPM = 2_700; p.windmillDragArea = 0.45
        return AircraftConfig(
            id: "org.skyforge.sf3", name: "SF-3 Twin",
            mass: 2_300, inertia: SIMD3(3_100, 4_300, 7_000), ixz: 0,
            wingArea: 18.5, wingSpan: 11.5, chord: 1.6,
            aero: a,
            maxPower: 380_000, propDiameter: 1.9, maxRPM: 2_700,
            staticThrustPerWatt: 0.030,   // was 0.021 (static T/W 0.17): too low to lift off within a normal takeoff roll
            stallAlpha: 15 * .pi / 180,
            elevatorMax: 25 * .pi / 180, aileronMax: 18 * .pi / 180, rudderMax: 22 * .pi / 180,
            flapMax: 30 * .pi / 180,
            gear: [
                GearLeg(position: SIMD3(1.8, 0, 1.40), stiffness: 55_000, damping: 7_560, steerable: true, braked: false),
                GearLeg(position: SIMD3(-0.4, -1.8, 1.40), stiffness: 110_000, damping: 10_350, steerable: false, braked: true),
                GearLeg(position: SIMD3(-0.4, 1.8, 1.40), stiffness: 110_000, damping: 10_350, steerable: false, braked: true),
            ],
            propulsion: p,
            stall: StallBehavior(autorotation: 1.4, wingDropGain: 0.14, noseDrop: 0.10, spinYawReversal: 1.0),
            retractableGear: true)
    }()

    /// SF-T1 Jet Trainer (sf5Jet): ~4,500 kg subsonic jet trainer, one 26 kN turbofan, speed brake, retractable gear.
    public static let sf5Jet: AircraftConfig = {
        var a = AeroCoefficients()
        a.cL0 = 0.12; a.cLAlpha = 4.3; a.cLMaxClean = 1.25; a.cLMaxFlaps = 1.85
        a.cLQ = 3.0; a.cLElevator = 0.38; a.cLFlap = 0.45
        a.cD0 = 0.021; a.cDGear = 0.013; a.cDFlap = 0.040; a.cDSpeedbrake = 0.020; a.oswald = 0.80
        a.cYBeta = -0.45; a.cYRudder = 0.16
        a.cm0 = 0.0; a.cmAlpha = -0.80; a.cmQ = -11.0; a.cmAlphaDot = -3.5; a.cmElevator = -1.15; a.cmFlap = -0.04
        a.clBeta = -0.09; a.clP = -0.38; a.clR = 0.08; a.clAileron = 0.14; a.clRudder = 0.012
        a.cnBeta = 0.09; a.cnP = -0.025; a.cnR = -0.18; a.cnAileron = -0.02; a.cnRudder = -0.06
        var p = PropulsionConfig(kind: .turbojet, engineCount: 1)
        p.dryThrust = 26_000; p.idleFraction = 0.04; p.windmillDragArea = 0.12
        return AircraftConfig(
            id: "org.skyforge.sft1", name: "SF-T1 Jet Trainer",
            mass: 4_500, inertia: SIMD3(4_200, 13_500, 16_500), ixz: 0,
            wingArea: 18.0, wingSpan: 9.4, chord: 2.1,
            aero: a,
            maxPower: 7_150_000, propDiameter: 1.0, maxRPM: 100,   // informational only (jets use `propulsion`)
            staticThrustPerWatt: 0.02,
            stallAlpha: 17 * .pi / 180,
            elevatorMax: 25 * .pi / 180, aileronMax: 20 * .pi / 180, rudderMax: 25 * .pi / 180,
            flapMax: 30 * .pi / 180,
            gear: [
                GearLeg(position: SIMD3(3.0, 0, 1.35), stiffness: 70_000, damping: 9_000, steerable: true, braked: false,
                        steerAngleMax: 30 * .pi / 180),
                GearLeg(position: SIMD3(-0.6, -1.6, 1.35), stiffness: 150_000, damping: 18_200, steerable: false, braked: true),
                GearLeg(position: SIMD3(-0.6, 1.6, 1.35), stiffness: 150_000, damping: 18_200, steerable: false, braked: true),
            ],
            propulsion: p,
            mach: MachSchedule(points: [
                .init(mach: 0.0, liftSlope: 1.00, clMax: 1.00, waveDrag: 0.000),
                .init(mach: 0.70, liftSlope: 1.08, clMax: 1.00, waveDrag: 0.000),
                .init(mach: 0.80, liftSlope: 1.14, clMax: 0.95, waveDrag: 0.004, pitchStability: 1.05, controlPower: 0.95),
                .init(mach: 0.90, liftSlope: 1.20, clMax: 0.88, waveDrag: 0.020, pitchStability: 1.20, controlPower: 0.85),
                .init(mach: 1.05, liftSlope: 1.05, clMax: 0.80, waveDrag: 0.050, pitchStability: 1.60, controlPower: 0.70),
            ]),
            stall: StallBehavior(autorotation: 1.2, wingDropGain: 0.10, noseDrop: 0.15, buffetStartMargin: 5 * .pi / 180),
            retractableGear: true)
    }()

    /// SF-F1 Interceptor (sf9Fighter): ~12,000 kg supersonic fighter, one afterburning turbofan (76 kN dry, 125 kN reheat).
    public static let sf9Fighter: AircraftConfig = {
        var a = AeroCoefficients()
        a.cL0 = 0.10; a.cLAlpha = 3.5; a.cLMaxClean = 1.40; a.cLMaxFlaps = 1.75
        a.cLQ = 2.5; a.cLElevator = 0.35; a.cLFlap = 0.30
        a.cD0 = 0.019; a.cDGear = 0.015; a.cDFlap = 0.030; a.cDSpeedbrake = 0.025; a.oswald = 0.80
        a.cYBeta = -0.50; a.cYRudder = 0.15
        a.cm0 = 0.0; a.cmAlpha = -0.60; a.cmQ = -8.0; a.cmAlphaDot = -2.0; a.cmElevator = -1.0; a.cmFlap = -0.03
        a.clBeta = -0.08; a.clP = -0.30; a.clR = 0.06; a.clAileron = 0.12; a.clRudder = 0.01
        a.cnBeta = 0.10; a.cnP = -0.02; a.cnR = -0.25; a.cnAileron = -0.01; a.cnRudder = -0.07
        var p = PropulsionConfig(kind: .turbojet, engineCount: 1)
        p.dryThrust = 76_000; p.afterburnerThrust = 125_000; p.idleFraction = 0.04; p.windmillDragArea = 0.15
        var c = AircraftConfig(
            id: "org.skyforge.sff1", name: "SF-F1 Interceptor",
            mass: 12_000, inertia: SIMD3(12_000, 70_000, 80_000), ixz: 0,
            wingArea: 28.0, wingSpan: 9.4, chord: 3.5,
            aero: a,
            maxPower: 20_900_000, propDiameter: 1.0, maxRPM: 100,   // informational only (jets use `propulsion`)
            staticThrustPerWatt: 0.02,
            stallAlpha: 24 * .pi / 180,
            elevatorMax: 25 * .pi / 180, aileronMax: 20 * .pi / 180, rudderMax: 30 * .pi / 180,
            flapMax: 25 * .pi / 180,
            gear: [
                GearLeg(position: SIMD3(3.2, 0, 1.7), stiffness: 130_000, damping: 18_400, steerable: true, braked: false,
                        steerAngleMax: 35 * .pi / 180),
                GearLeg(position: SIMD3(-0.6, -1.2, 1.7), stiffness: 330_000, damping: 46_300, steerable: false, braked: true),
                GearLeg(position: SIMD3(-0.6, 1.2, 1.7), stiffness: 330_000, damping: 46_300, steerable: false, braked: true),
            ],
            propulsion: p,
            mach: MachSchedule(points: [
                .init(mach: 0.0, liftSlope: 1.00, clMax: 1.00, waveDrag: 0.000, pitchStability: 1.00, controlPower: 1.00),
                .init(mach: 0.8, liftSlope: 1.10, clMax: 1.00, waveDrag: 0.000, pitchStability: 1.00, controlPower: 1.00),
                .init(mach: 0.9, liftSlope: 1.15, clMax: 0.95, waveDrag: 0.008, pitchStability: 1.10, controlPower: 0.92),
                .init(mach: 1.0, liftSlope: 1.10, clMax: 0.90, waveDrag: 0.035, pitchStability: 1.50, controlPower: 0.80),
                .init(mach: 1.1, liftSlope: 0.95, clMax: 0.85, waveDrag: 0.040, pitchStability: 1.90, controlPower: 0.75),
                .init(mach: 1.3, liftSlope: 0.72, clMax: 0.80, waveDrag: 0.034, pitchStability: 2.10, controlPower: 0.80),
                .init(mach: 2.0, liftSlope: 0.50, clMax: 0.75, waveDrag: 0.024, pitchStability: 2.30, controlPower: 0.90),
            ]),
            stall: StallBehavior(autorotation: 1.2, wingDropGain: 0.10, noseDrop: 0.20, buffetStartMargin: 5 * .pi / 180),
            retractableGear: true)
        c.groundEffectSpanHeightRatio = 1.0
        return c
    }()

    /// SF-B Bushcat (sfBushcat): ~1,350 kg high-wing utility single, 260 kW piston, fixed gear, short-field STOL.
    /// Tricycle gear here; the bush class normally uses a tailwheel, which the model does not yet have.
    public static let sfBushcat: AircraftConfig = {
        var a = AeroCoefficients()
        a.cL0 = 0.30; a.cLAlpha = 5.0; a.cLMaxClean = 1.70; a.cLMaxFlaps = 2.20
        a.cD0 = 0.032; a.cDFlap = 0.060; a.oswald = 0.75
        a.cmAlpha = -1.0; a.cmElevator = -1.3
        a.cnBeta = 0.08; a.cnR = -0.12; a.cnRudder = -0.075; a.cYRudder = 0.2
        var p = PropulsionConfig(kind: .piston, engineCount: 1)
        p.powerPerEngine = 260_000; p.staticThrustPerWatt = 0.030; p.propEfficiency = 0.80
        p.maxRPM = 2_600; p.propTorqueRoll = 0.12; p.pFactorArm = 0.25
        return AircraftConfig(
            id: "org.skyforge.sfb", name: "SF-B Bushcat",
            mass: 1_350, inertia: SIMD3(1_500, 2_300, 3_600), ixz: 0,
            wingArea: 17.5, wingSpan: 11.6, chord: 1.5,
            aero: a,
            maxPower: 260_000, propDiameter: 2.0, maxRPM: 2_600,
            staticThrustPerWatt: 0.030,
            stallAlpha: 16 * .pi / 180,
            elevatorMax: 25 * .pi / 180, aileronMax: 20 * .pi / 180, rudderMax: 22 * .pi / 180,
            flapMax: 35 * .pi / 180,
            gear: [
                GearLeg(position: SIMD3(1.25, 0, 1.30), stiffness: 60_750, damping: 6_075, steerable: true, braked: false),
                GearLeg(position: SIMD3(-0.30, -1.10, 1.30), stiffness: 94_500, damping: 8_100, steerable: false, braked: true),
                GearLeg(position: SIMD3(-0.30, 1.10, 1.30), stiffness: 94_500, damping: 8_100, steerable: false, braked: true),
            ],
            propulsion: p,
            stall: StallBehavior(autorotation: 1.3, wingDropGain: 0.12, noseDrop: 0.10),
            retractableGear: false)
    }()

    /// SF-E Executive (sfExecutive): ~9 t twin-jet business aircraft, 22 kN per engine, retractable gear.
    public static let sfExecutive: AircraftConfig = {
        var a = AeroCoefficients()
        a.cL0 = 0.35; a.cLAlpha = 4.8; a.cLMaxClean = 1.45; a.cLMaxFlaps = 2.00
        a.cLQ = 3.0; a.cLElevator = 0.40; a.cLFlap = 0.50
        a.cD0 = 0.020; a.cDGear = 0.012; a.cDFlap = 0.040; a.cDSpeedbrake = 0.020; a.oswald = 0.82
        a.cYBeta = -0.40; a.cYRudder = 0.16
        a.cm0 = 0.0; a.cmAlpha = -0.90; a.cmQ = -11.0; a.cmAlphaDot = -3.0; a.cmElevator = -1.10; a.cmFlap = -0.04
        a.clBeta = -0.08; a.clP = -0.34; a.clR = 0.08; a.clAileron = 0.13; a.clRudder = 0.012
        a.cnBeta = 0.09; a.cnP = -0.025; a.cnR = -0.16; a.cnAileron = -0.02; a.cnRudder = -0.06
        var p = PropulsionConfig(kind: .turbojet, engineCount: 2, engineSpanOffset: 2.4)
        p.dryThrust = 22_000; p.idleFraction = 0.04; p.windmillDragArea = 0.12
        return AircraftConfig(
            id: "org.skyforge.sfe", name: "SF-E Executive",
            mass: 9_000, inertia: SIMD3(12_000, 20_000, 28_000), ixz: 0,
            wingArea: 32, wingSpan: 16.8, chord: 2.0,
            aero: a,
            maxPower: 800_000, propDiameter: 1.0, maxRPM: 100,   // informational only (jets use `propulsion`)
            staticThrustPerWatt: 0.02,
            stallAlpha: 17 * .pi / 180,
            elevatorMax: 25 * .pi / 180, aileronMax: 20 * .pi / 180, rudderMax: 25 * .pi / 180,
            flapMax: 30 * .pi / 180,
            gear: [
                GearLeg(position: SIMD3(5.2, 0, 1.6), stiffness: 405_000, damping: 40_500, steerable: true, braked: false,
                        steerAngleMax: 30 * .pi / 180),
                GearLeg(position: SIMD3(-0.6, -2.0, 1.6), stiffness: 630_000, damping: 54_000, steerable: false, braked: true),
                GearLeg(position: SIMD3(-0.6, 2.0, 1.6), stiffness: 630_000, damping: 54_000, steerable: false, braked: true),
            ],
            propulsion: p,
            stall: StallBehavior(autorotation: 1.2, wingDropGain: 0.10, noseDrop: 0.15, buffetStartMargin: 5 * .pi / 180),
            retractableGear: true)
    }()
}
