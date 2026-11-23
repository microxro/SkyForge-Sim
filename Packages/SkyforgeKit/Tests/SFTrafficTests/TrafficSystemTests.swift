import Testing
import Foundation
import SFFlightModel
@testable import SFTraffic

/// A north-pointing runway: along is north, right is east, threshold at the origin.
private func northRunway() -> TrafficRunway {
    TrafficRunway(threshold: SIMD2<Double>(0, 0), heading: 0, length: 2_000, elevation: 0)
}

private func makeSystem(fleet: [AircraftConfig], schedule: TrafficSchedule = TrafficSchedule()) -> TrafficSystem {
    TrafficSystem(runway: northRunway(), schedule: schedule, fleet: fleet)
}

/// Issues clearances the way a controller would: a landing once an arrival is on base, a takeoff once a
/// departure is holding short. Only the kinds that are switched on are issued.
private func issueClearances(_ sys: inout TrafficSystem, landings: Bool, takeoffs: Bool) {
    for s in sys.snapshots {
        if landings, s.kind == .arrival, s.phase == .base, !s.clearedToLand {
            _ = sys.issue(.land, to: s.id)
        }
        if takeoffs, s.kind == .departure, s.phase == .holdShort, !s.clearedToTakeoff {
            _ = sys.issue(.takeoff, to: s.id)
        }
    }
}

/// Steps `seconds` of sim time at 0.1 s and returns every event raised along the way.
private func runSim(_ sys: inout TrafficSystem, seconds: Double, landings: Bool, takeoffs: Bool) -> [TrafficEvent] {
    var events: [TrafficEvent] = []
    for _ in 0..<Int((seconds / 0.1).rounded()) {
        sys.step(dt: 0.1)
        events += sys.drainEvents()
        issueClearances(&sys, landings: landings, takeoffs: takeoffs)
    }
    return events
}

@Suite struct TrafficSystemTests {

    // MARK: - Runway

    @Test func designatorComesFromHeading() {
        let west = TrafficRunway(threshold: SIMD2<Double>(0, 0), heading: 280 * Double.pi / 180, length: 2_000, elevation: 0)
        #expect(west.designator == "28")
        #expect(northRunway().designator == "36")
    }

    @Test func runwayFrameRoundTrips() {
        let rwy = TrafficRunway(threshold: SIMD2<Double>(500, -300), heading: 280 * Double.pi / 180,
                                length: 2_000, elevation: 120)
        let p = rwy.ned(along: 1_234, right: -56, up: 30)
        let l = rwy.local(p)
        #expect(abs(l.x - 1_234) < 1e-6)
        #expect(abs(l.y + 56) < 1e-6)
        #expect(abs(l.z - 30) < 1e-6)
    }

    @Test func alongMovesNorthOnANorthRunway() {
        let p = northRunway().ned(along: 100, right: 0, up: 0)
        #expect(abs(p.x - 100) < 1e-9)
        #expect(abs(p.y) < 1e-9)
    }

    // MARK: - Performance

    @Test func flapsLowerTheStallSpeed() {
        let clean = TrafficPerformance.stallSpeed(AircraftConfig.sf1Trainer, density: 1.225, flaps: false)
        let flapped = TrafficPerformance.stallSpeed(AircraftConfig.sf1Trainer, density: 1.225, flaps: true)
        #expect(flapped < clean)
        // Lift equation at sea level for the 1 t trainer: about 25 m/s clean.
        #expect(clean > 20 && clean < 30)
    }

    @Test func approachIsSlowerThanDownwindAndTheJetIsFaster() {
        let trainer = TrafficPerformance.speeds(AircraftConfig.sf1Trainer, density: 1.225)
        let jet = TrafficPerformance.speeds(AircraftConfig.sf5Jet, density: 1.225)
        #expect(trainer.approach < trainer.downwind)
        #expect(jet.rotate > trainer.rotate)
        #expect(jet.climb > trainer.climb)
        #expect(jet.approach > trainer.approach)
        #expect(jet.downwind > trainer.downwind)
    }

    @Test func climbRateStaysWithinLimits() {
        let configs = [AircraftConfig.sf1Trainer, AircraftConfig.sf2Cruiser, AircraftConfig.sf3Twin, AircraftConfig.sf5Jet]
        for config in configs {
            let climb = TrafficPerformance.maxClimbRate(config)
            #expect(climb >= 2 && climb <= 12)
        }
    }

    @Test func heavyThresholdFollowsMass() {
        #expect(!TrafficPerformance.isHeavy(AircraftConfig.sf1Trainer))
        #expect(TrafficPerformance.isHeavy(AircraftConfig.sf5Jet))
    }

    @Test func anglesWrapAndTurnsAreRateLimited() {
        let wrapped = TrafficPerformance.wrapAngle(3 * Double.pi)
        // +pi and -pi are the same heading and the wrap interval is (-pi, pi], so either end is a correct answer.
        #expect(abs(abs(wrapped) - Double.pi) < 1e-9)
        // A turn toward pi in one 0.1 s step at 0.5 rad/s can move at most 0.05 rad.
        let turned = TrafficPerformance.turn(from: 0, toward: Double.pi, rate: 0.5, dt: 0.1)
        #expect(abs(turned) <= 0.05 + 1e-12)
        // A small heading change inside the rate limit is taken in full.
        let near = TrafficPerformance.turn(from: 0, toward: 0.01, rate: 0.5, dt: 0.1)
        #expect(abs(near - 0.01) < 1e-12)
    }

    // MARK: - Pattern geometry

    @Test func patternSideAndDownwindWaypoints() {
        let right = TrafficPatternGeometry(leftTraffic: false)
        let left = TrafficPatternGeometry(leftTraffic: true)
        #expect(right.side == 1)
        #expect(left.side == -1)
        let rightDownwind = right.waypoint(for: .downwind)
        #expect(rightDownwind.x == right.baseCorner)
        #expect(rightDownwind.y == right.downwindOffset)
        let leftDownwind = left.waypoint(for: .downwind)
        #expect(leftDownwind.x == left.baseCorner)
        #expect(leftDownwind.y == -left.downwindOffset)
    }

    // MARK: - Arrivals

    @Test func arrivalWithoutClearanceGoesAround() throws {
        var sys = makeSystem(fleet: [AircraftConfig.sf1Trainer],
                             schedule: TrafficSchedule(meanArrivalInterval: 1_000, maxAircraft: 1))
        var extendedID: String?
        var steps = 0
        while extendedID == nil && steps < 9_000 {   // up to 900 s of sim time
            sys.step(dt: 0.1)
            steps += 1
            for event in sys.drainEvents() {
                if case .extended(let id) = event { extendedID = id }
            }
        }
        let id = try #require(extendedID)
        #expect(sys.aircraft.contains(where: { $0.id == id }))
        #expect(sys.aircraft.first(where: { $0.id == id })?.phase == .extended)
    }

    @Test func arrivalWithClearanceTouchesDownAndLeaves() throws {
        var sys = makeSystem(fleet: [AircraftConfig.sf1Trainer],
                             schedule: TrafficSchedule(meanArrivalInterval: 1_000, maxAircraft: 1))
        var arrivalID: String?
        var touchdownTime: Double?
        var touchdownAlong: Double?
        var completedAt: Double?
        var steps = 0
        while completedAt == nil && steps < 9_000 {   // up to 900 s of sim time
            sys.step(dt: 0.1)
            steps += 1
            let events = sys.drainEvents()
            if arrivalID == nil { arrivalID = sys.aircraft.first?.id }
            guard let current = arrivalID else { continue }
            if touchdownTime == nil && events.contains(.touchedDown(id: current)) {
                touchdownTime = sys.time
                touchdownAlong = sys.snapshots.first(where: { $0.id == current })?.alongRunway
            }
            if touchdownTime != nil && events.contains(.completed(id: current, kind: .arrival)) {
                completedAt = sys.time
            }
            // Clear the landing as soon as the arrival is on the base leg, well before the final turn.
            if let s = sys.snapshots.first(where: { $0.id == current }), s.phase == .base, !s.clearedToLand {
                _ = sys.issue(.land, to: current)
            }
        }
        let id = try #require(arrivalID)
        let touchedAt = try #require(touchdownTime)
        let along = try #require(touchdownAlong)
        let finished = try #require(completedAt)
        #expect(touchedAt <= 600)
        #expect(along > -100 && along < 600)
        #expect(finished - touchedAt <= 120)
        #expect(!sys.aircraft.contains(where: { $0.id == id }))
    }

    // MARK: - Departures

    @Test func departureHoldsShortUntilTakeoffClearance() throws {
        var sys = makeSystem(fleet: [AircraftConfig.sf1Trainer],
                             schedule: TrafficSchedule(meanArrivalInterval: 1_000, meanDepartureInterval: 1_000,
                                                       maxAircraft: 6))
        var departureID: String?
        var steps = 0
        while departureID == nil && steps < 1_000 {   // the departure is due at 45 s
            sys.step(dt: 0.1)
            steps += 1
            for event in sys.drainEvents() {
                if case .spawned(let spawnedID, let kind) = event, kind == .departure { departureID = spawnedID }
            }
        }
        let id = try #require(departureID)

        // No clearance: the departure stays at the hold line for a full minute of sim time.
        var phases: [TrafficPhase] = []
        for _ in 0..<600 {
            sys.step(dt: 0.1)
            _ = sys.drainEvents()
            if let s = sys.snapshots.first(where: { $0.id == id }) { phases.append(s.phase) }
        }
        #expect(phases.count == 600)
        #expect(phases.allSatisfy({ $0 == .holdShort }))

        // Clearance kinds only fit their own aircraft: a landing never fits a departure, and a takeoff never
        // fits an arrival or an id that is not in the system.
        let landingOnDeparture = sys.issue(.land, to: id)
        #expect(!landingOnDeparture)
        let arrivalID = try #require(sys.aircraft.first(where: { $0.kind == .arrival })?.id)
        let takeoffOnArrival = sys.issue(.takeoff, to: arrivalID)
        #expect(!takeoffOnArrival)
        let takeoffOnUnknown = sys.issue(.takeoff, to: "NOPE")
        #expect(!takeoffOnUnknown)

        // Takeoff clearance: the departure rolls, rotates, climbs out on its route and completes.
        let cleared = sys.issue(.takeoff, to: id)
        #expect(cleared)
        var sawTookOff = false
        var completedAt: Double?
        var more = 0
        while completedAt == nil && more < 9_000 {   // up to 900 s of sim time
            sys.step(dt: 0.1)
            more += 1
            for event in sys.drainEvents() {
                if case .tookOff(let tookOffID) = event, tookOffID == id { sawTookOff = true }
                if case .completed(let doneID, _) = event, doneID == id { completedAt = sys.time }
            }
        }
        #expect(sawTookOff)
        #expect(completedAt != nil)
    }

    // MARK: - Determinism

    @Test func identicalInputsReplayIdentically() {
        var first = makeSystem(fleet: TrafficSystem.defaultFleet)
        var second = makeSystem(fleet: TrafficSystem.defaultFleet)
        let firstEvents = runSim(&first, seconds: 300, landings: true, takeoffs: true)
        let secondEvents = runSim(&second, seconds: 300, landings: true, takeoffs: true)
        #expect(first.time == second.time)
        #expect(firstEvents == secondEvents)
        #expect(first.snapshots == second.snapshots)
        #expect(!first.snapshots.isEmpty)
    }

    // MARK: - Wakes

    @Test func heavyAircraftShedWakesOnceAirborne() throws {
        var sys = makeSystem(fleet: [AircraftConfig.sf5Jet])
        var airborneSince: Double?
        var steps = 0
        while steps < 3_000 {   // up to 300 s of sim time
            sys.step(dt: 0.1)
            steps += 1
            for event in sys.drainEvents() {
                if case .spawned(_, let kind) = event, kind == .arrival, airborneSince == nil {
                    airborneSince = sys.time
                }
            }
            if let since = airborneSince, sys.time - since >= 10 { break }
        }
        let spawned = try #require(airborneSince)
        #expect(sys.time - spawned >= 10)
        #expect(!sys.wakes.active.isEmpty)
    }

    @Test func lightAircraftNeverShedWakes() {
        var sys = makeSystem(fleet: [AircraftConfig.sf1Trainer])
        var sawWake = false
        for _ in 0..<6_000 {   // 600 s of sim time
            sys.step(dt: 0.1)
            _ = sys.drainEvents()
            if !sys.wakes.active.isEmpty { sawWake = true }
        }
        #expect(!sawWake)
        // Traffic was flying the whole time, so the check above means something.
        #expect(!sys.snapshots.isEmpty)
    }

    // MARK: - Limits and robustness

    @Test func aircraftCountNeverExceedsTheSchedule() {
        var sys = makeSystem(fleet: TrafficSystem.defaultFleet,
                             schedule: TrafficSchedule(meanArrivalInterval: 20, meanDepartureInterval: 20, maxAircraft: 2))
        var most = 0
        for _ in 0..<6_000 {   // 600 s of sim time
            sys.step(dt: 0.1)
            _ = sys.drainEvents()
            most = max(most, sys.aircraft.count)
        }
        #expect(most <= 2)
        // The cap is reached, so the bound is tested and not just trivially met.
        #expect(most == 2)
    }

    @Test func aircraftNeverDropBelowTheRunway() {
        var sys = makeSystem(fleet: [AircraftConfig.sf3Twin])
        var lowest = Double.infinity
        var samples = 0
        for _ in 0..<6_000 {   // 600 s of sim time, with every arrival landed and every departure cleared
            sys.step(dt: 0.1)
            _ = sys.drainEvents()
            issueClearances(&sys, landings: true, takeoffs: true)
            for s in sys.snapshots {
                lowest = min(lowest, s.heightAboveRunway)
                samples += 1
            }
        }
        #expect(samples > 0)
        #expect(lowest >= -0.5)
    }

    @Test func badStepSizesChangeNothing() {
        var sys = makeSystem(fleet: [AircraftConfig.sf1Trainer])
        for dt in [0.0, -1.0, 2.0, Double.nan, Double.infinity] {
            sys.step(dt: dt)
        }
        #expect(sys.time == 0)
        #expect(sys.aircraft.isEmpty)
        let events = sys.drainEvents()
        #expect(events.isEmpty)
    }
}
