// SKYFORGE — Apache-2.0
// Departures start at a gate behind the threshold, taxi to the hold line, and are not ready for takeoff clearance
// until they get there.
import Testing
import Foundation
import SFFlightModel
@testable import SFTraffic

private func taxiSystem() -> TrafficSystem {
    TrafficSystem(runway: TrafficRunway(threshold: SIMD2<Double>(0, 0), heading: 0, length: 2_000, elevation: 0),
                  schedule: TrafficSchedule(meanArrivalInterval: 1_000, meanDepartureInterval: 1_000, maxAircraft: 6),
                  fleet: [AircraftConfig.sf1Trainer])
}

@Suite struct TaxiGateTests {
    @Test func departureTaxisFromTheGateToTheHoldLine() {
        var sys = taxiSystem()
        var departureID: String?
        var steps = 0
        while departureID == nil && steps < 1_000 {   // the departure is due at 45 s
            sys.step(dt: 0.1)
            steps += 1
            for event in sys.drainEvents() {
                if case .spawned(let spawnedID, let kind) = event, kind == .departure { departureID = spawnedID }
            }
        }
        guard let id = departureID else {
            Issue.record("no departure spawned")
            return
        }
        let gate = sys.snapshots.first { $0.id == id }!
        #expect(gate.alongRunway < -250)     // spawns at the gate behind the threshold
        #expect(!gate.takeoffFits)           // not ready for takeoff clearance while it taxis

        // 300 m at 15 m/s takes 20 s; give it 30 s.
        for _ in 0..<300 {
            sys.step(dt: 0.1)
            _ = sys.drainEvents()
        }
        let holdLine = sys.snapshots.first { $0.id == id }!
        #expect(holdLine.phase == .holdShort)
        #expect(abs(holdLine.alongRunway) < 1)
        #expect(holdLine.takeoffFits)
    }
}
