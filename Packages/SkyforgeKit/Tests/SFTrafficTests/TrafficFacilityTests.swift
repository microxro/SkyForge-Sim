import Testing
import Foundation
import SFFlightModel
@testable import SFTraffic

/// A north-pointing runway, 2 km long, with the threshold at the origin.
private let facilityRunway = TrafficRunway(threshold: SIMD2<Double>(0, 0), heading: 0, length: 2_000, elevation: 0)
private let facilityPattern = TrafficPatternGeometry(leftTraffic: false)

/// Ownship at a runway-frame position (along, right, up), moving north at `speed`.
private func ownReport(onGround: Bool, speed: Double = 0, along: Double, right: Double = 0, height: Double) -> OwnshipReport {
    OwnshipReport(config: AircraftConfig.sf1Trainer,
                  positionNED: facilityRunway.ned(along: along, right: right, up: height),
                  velocityNED: SIMD3<Double>(speed, 0, 0), onGround: onGround)
}

@Suite struct TrafficFacilityTests {

    // MARK: - The rule

    @Test func arrivalIsWithApproachUntilItReachesThePatternThenWithTheTower() {
        var facility = TrafficFacility.approach
        facility = TrafficSystem.facility(current: facility, phase: .inbound, alongRunway: 5_000)
        #expect(facility == .approach)
        facility = TrafficSystem.facility(current: facility, phase: .downwind, alongRunway: 1_200)
        #expect(facility == .tower)
        facility = TrafficSystem.facility(current: facility, phase: .final, alongRunway: 0)
        #expect(facility == .tower)
    }

    @Test func departureStaysWithTheTowerUntilTheHandoffPoint() {
        var facility = TrafficFacility.tower
        facility = TrafficSystem.facility(current: facility, phase: .holdShort, alongRunway: 0)
        facility = TrafficSystem.facility(current: facility, phase: .takeoffRoll, alongRunway: 400)
        #expect(facility == .tower)
        facility = TrafficSystem.facility(current: facility, phase: .departing, alongRunway: 2_999)
        #expect(facility == .tower)
        facility = TrafficSystem.facility(current: facility, phase: .departing, alongRunway: 3_000)
        #expect(facility == .departure)
    }

    @Test func departureControlKeepsADepartureOnItsWayOut() {
        var facility = TrafficFacility.departure
        facility = TrafficSystem.facility(current: facility, phase: .departing, alongRunway: 4_500)
        #expect(facility == .departure)
        facility = TrafficSystem.facility(current: facility, phase: .complete, alongRunway: 9_000)
        #expect(facility == .departure)
    }

    @Test func ownshipComingBackAfterItsClimbOutIsWithDepartureThenTheTower() {
        // Past the handoff point with the tower, flying inbound: the change is to departure, not approach.
        #expect(TrafficSystem.facility(current: .tower, phase: .inbound, alongRunway: 3_100) == .departure)
        #expect(TrafficSystem.facility(current: .departure, phase: .inbound, alongRunway: 3_500) == .departure)
        #expect(TrafficSystem.facility(current: .departure, phase: .downwind, alongRunway: 1_200) == .tower)
    }

    // MARK: - Ownship

    @Test func ownshipStartsWithTheTowerOnTheRunwayAndWithApproachInTheAir() {
        #expect(OwnshipTracker(startsOnRunway: true).facility == .tower)
        #expect(OwnshipTracker(startsOnRunway: false).facility == .approach)
    }

    @Test func ownshipTrackerHandsOverAtTheEndOfItsClimbOutAndBackAtTheDownwind() {
        var tracker = OwnshipTracker(startsOnRunway: true)
        _ = tracker.phase(for: ownReport(onGround: true, speed: 12, along: 400, height: 0),
                          runway: facilityRunway, pattern: facilityPattern)
        _ = tracker.phase(for: ownReport(onGround: false, speed: 30, along: 700, height: 20),
                          runway: facilityRunway, pattern: facilityPattern)
        #expect(tracker.facility == .tower)

        _ = tracker.phase(for: ownReport(onGround: false, speed: 40, along: 3_500, height: 400),
                          runway: facilityRunway, pattern: facilityPattern)
        #expect(tracker.facility == .departure)

        // Back on the downwind leg, the tower has the aircraft again.
        let phase = tracker.phase(for: ownReport(onGround: false, speed: 30, along: 0, right: 1_000, height: 305),
                                  runway: facilityRunway, pattern: facilityPattern)
        #expect(phase == .downwind)
        #expect(tracker.facility == .tower)
    }

    // MARK: - Through the system

    @Test func aDepartureIsHandedToDepartureControlAtTheHandoffPoint() {
        var system = TrafficSystem(runway: facilityRunway, seed: 7, schedule: TrafficSchedule(), fleet: [.sf1Trainer])
        var departureID: String?
        var handedOver = false
        // Ten minutes at half-second steps is plenty for a trainer to roll out and climb past 3 km.
        for _ in 0..<1_200 {
            system.step(dt: 0.5)
            _ = system.drainEvents()
            if departureID == nil {
                departureID = system.aircraft.first(where: { $0.kind == .departure })?.id
            }
            guard let id = departureID else { continue }
            system.issue(.takeoff, to: id)
            guard let a = system.aircraft.first(where: { $0.id == id }) else { break }
            if a.facility == .departure {
                handedOver = true
                // The hand-over happens at the handoff point, not before.
                #expect(facilityRunway.local(a.position).x >= TrafficSystem.departureHandoffDistance)
                break
            }
        }
        #expect(departureID != nil)
        #expect(handedOver)
    }

    @Test func snapshotsCarryTheFacilityOfEachAircraft() {
        let system = TrafficSystem(runway: facilityRunway, seed: 7, schedule: TrafficSchedule(), fleet: [.sf1Trainer])
        var ownship = OwnshipTracker(startsOnRunway: false)
        let snap = ownship.snapshot(of: ownReport(onGround: false, speed: 30, along: 7_000, height: 400),
                                    system: system, clearedToLand: false, clearedToTakeoff: false)
        #expect(snap.facility == .approach)
    }
}
