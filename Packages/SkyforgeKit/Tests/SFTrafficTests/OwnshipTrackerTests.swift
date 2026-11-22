import Testing
import Foundation
import SFFlightModel
@testable import SFTraffic

/// A north-pointing runway: along is north, right is east, threshold at the origin.
private let northRunway = TrafficRunway(threshold: SIMD2<Double>(0, 0), heading: 0, length: 2_000, elevation: 0)
private let rightPattern = TrafficPatternGeometry(leftTraffic: false)

/// Ownship at a runway-frame position, moving north at `speed`.
private func report(onGround: Bool, speed: Double = 0, along: Double, right: Double = 0, height: Double) -> OwnshipReport {
    OwnshipReport(config: AircraftConfig.sf1Trainer,
                  positionNED: northRunway.ned(along: along, right: right, up: height),
                  velocityNED: SIMD3<Double>(speed, 0, 0), onGround: onGround)
}

@Suite struct OwnshipTrackerTests {

    // MARK: - Departure

    @Test func holdsShortRollsAndClimbsOut() {
        var tracker = OwnshipTracker(startsOnRunway: true)
        let hold = tracker.phase(for: report(onGround: true, along: 0, height: 0), runway: northRunway, pattern: rightPattern)
        #expect(hold == .holdShort)

        let roll = tracker.phase(for: report(onGround: true, speed: 12, along: 400, height: 0),
                                 runway: northRunway, pattern: rightPattern)
        #expect(roll == .takeoffRoll)

        let climb = tracker.phase(for: report(onGround: false, speed: 30, along: 700, height: 20),
                                  runway: northRunway, pattern: rightPattern)
        #expect(climb == .departing)
        #expect(tracker.climbingOut)
        #expect(!tracker.awaitingTakeoff)
    }

    @Test func climbOutEndsAfterThreeKilometres() {
        var tracker = OwnshipTracker(startsOnRunway: true)
        _ = tracker.phase(for: report(onGround: true, speed: 12, along: 400, height: 0), runway: northRunway, pattern: rightPattern)
        _ = tracker.phase(for: report(onGround: false, speed: 30, along: 700, height: 20), runway: northRunway, pattern: rightPattern)

        let stillClimbing = tracker.phase(for: report(onGround: false, speed: 40, along: 2_000, height: 200),
                                          runway: northRunway, pattern: rightPattern)
        #expect(stillClimbing == .departing)

        // Far out, the climb out is over and the aircraft is inbound to the pattern like any arrival.
        let far = tracker.phase(for: report(onGround: false, speed: 40, along: 3_500, height: 400),
                                runway: northRunway, pattern: rightPattern)
        #expect(far == .inbound)
        #expect(!tracker.climbingOut)
    }

    @Test func landingAfterADepartureIsNotATakeoffAgain() {
        var tracker = OwnshipTracker(startsOnRunway: true)
        _ = tracker.phase(for: report(onGround: true, speed: 12, along: 400, height: 0), runway: northRunway, pattern: rightPattern)
        _ = tracker.phase(for: report(onGround: false, speed: 30, along: 700, height: 20), runway: northRunway, pattern: rightPattern)
        let rollout = tracker.phase(for: report(onGround: true, speed: 8, along: 300, height: 0),
                                    runway: northRunway, pattern: rightPattern)
        #expect(rollout == .landing)
    }

    // MARK: - Pattern legs

    @Test func arrivalFliesTheLegsOfThePattern() {
        var tracker = OwnshipTracker(startsOnRunway: false)
        // The downwind leg sits 1 km to the right of the runway at pattern altitude.
        #expect(tracker.phase(for: report(onGround: false, speed: 30, along: 0, right: 1_000, height: 305),
                              runway: northRunway, pattern: rightPattern) == .downwind)
        // Over the base corner, on the base leg.
        #expect(tracker.phase(for: report(onGround: false, speed: 30, along: -1_000, right: 500, height: 130),
                              runway: northRunway, pattern: rightPattern) == .base)
        // Close to the final approach path, about 40 m up at 500 m short of the aim point.
        #expect(tracker.phase(for: report(onGround: false, speed: 30, along: -500, right: 0, height: 40),
                              runway: northRunway, pattern: rightPattern) == .final)
    }

    @Test func farAwayIsInboundAndPastTheEntryIsInbound() {
        #expect(OwnshipTracker.patternPhase(at: SIMD3(0, 5_000, 305), pattern: rightPattern) == .inbound)
        #expect(OwnshipTracker.patternPhase(at: SIMD3(1_300, 0, 305), pattern: rightPattern) == .inbound)
    }

    @Test func leftTrafficMirrorsTheDownwind() {
        let left = TrafficPatternGeometry(leftTraffic: true)
        #expect(OwnshipTracker.patternPhase(at: SIMD3(0, -1_000, 305), pattern: left) == .downwind)
        #expect(OwnshipTracker.patternPhase(at: SIMD3(0, 1_000, 305), pattern: left) == .inbound)
    }

    // MARK: - Snapshot

    @Test func snapshotCarriesWhatTheTowerReads() {
        let system = TrafficSystem(runway: northRunway, fleet: [AircraftConfig.sf1Trainer])
        var tracker = OwnshipTracker(startsOnRunway: true)
        let snap = tracker.snapshot(of: report(onGround: true, along: 0, height: 0), system: system,
                                    clearedToLand: false, clearedToTakeoff: true)
        #expect(snap.id == TrafficOwnship.id)
        #expect(snap.callsign == TrafficOwnship.callsign)
        #expect(snap.kind == .departure)
        #expect(snap.phase == .holdShort)
        #expect(snap.clearedToTakeoff)
        #expect(!snap.clearedToLand)
        #expect(snap.takeoffFits)
        #expect(!snap.isHeavy)
        // The aim point is 300 m along the runway, so the threshold is 300 m from touchdown.
        #expect(abs(snap.distanceToTouchdown - 300) < 1e-6)
    }
}
