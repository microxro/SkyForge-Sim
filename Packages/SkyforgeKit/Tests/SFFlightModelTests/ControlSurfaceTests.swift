import Testing
import Foundation
@testable import SFFlightModel

@Suite struct ControlSurfaceTests {
    private let config = AircraftConfig.sf3Twin

    @Test func neutralInputsGiveNeutralSurfaces() {
        let angles = ControlSurfaces.angles(for: ControlInputs(), config: config)
        #expect(angles == .neutral)
    }

    @Test func rightRollRaisesTheRightAileronAndLowersTheLeft() {
        let angles = ControlSurfaces.angles(for: ControlInputs(aileron: 1), config: config)
        #expect(angles.leftAileron == config.aileronMax)
        #expect(angles.rightAileron == -config.aileronMax)
    }

    @Test func stickBackRaisesTheElevatorTrailingEdge() {
        let angles = ControlSurfaces.angles(for: ControlInputs(elevator: 1), config: config)
        #expect(angles.elevator == -config.elevatorMax)
        let nose = ControlSurfaces.angles(for: ControlInputs(elevator: -1), config: config)
        #expect(nose.elevator == config.elevatorMax)
    }

    @Test func rightYawMovesTheRudderTrailingEdgeLeft() {
        let angles = ControlSurfaces.angles(for: ControlInputs(rudder: 1), config: config)
        #expect(angles.rudder == -config.rudderMax)
    }

    @Test func flapsFollowTheLeverUpToTheFullAngle() {
        let half = ControlSurfaces.angles(for: ControlInputs(flaps: 0.5), config: config)
        #expect(half.flap == 0.5 * config.flapMax)
        let full = ControlSurfaces.angles(for: ControlInputs(flaps: 1), config: config)
        #expect(full.flap == config.flapMax)
    }

    @Test func inputsPastFullDeflectionStopAtTheStop() {
        let far = ControlSurfaces.angles(for: ControlInputs(elevator: 7, aileron: -3, rudder: 9), config: config)
        #expect(far.elevator == -config.elevatorMax)
        #expect(far.leftAileron == -config.aileronMax)
        #expect(far.rudder == -config.rudderMax)
    }

    @Test func nonFiniteInputsCountAsNeutral() {
        let angles = ControlSurfaces.angles(for: ControlInputs(elevator: .nan, aileron: .infinity), config: config)
        #expect(angles.elevator == 0)
        #expect(angles.leftAileron == 0)
    }
}
