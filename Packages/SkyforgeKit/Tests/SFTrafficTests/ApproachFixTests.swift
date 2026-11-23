import Testing
import Foundation
import SFFlightModel
@testable import SFTraffic

private let fixRunway = TrafficRunway(threshold: SIMD2<Double>(0, 0), heading: 0, length: 2_000, elevation: 0)

/// A runway-length field with one trainer type, a fixed seed, and no spawns once an arrival is placed by hand.
private func quietSystem() -> TrafficSystem {
    TrafficSystem(runway: fixRunway, seed: 11, schedule: TrafficSchedule(), fleet: [.sf1Trainer])
}

@Suite struct ApproachFixTests {

    @Test func controlOnlyFitsAnInboundArrival() {
        var system = quietSystem()
        // Nothing has spawned yet at time zero, so there is no aircraft to instruct.
        #expect(system.apply(.hold, to: "T1") == false)
        #expect(system.apply(.vectorToFix, to: "T1") == false)
    }

    @Test func aVectorIsSeenInTheSnapshotAndCanBeCancelled() {
        var system = quietSystem()
        // Run until the first arrival appears at 20 s.
        for _ in 0..<50 { system.step(dt: 0.5) }
        guard let arrival = system.aircraft.first(where: { $0.kind == .arrival }) else {
            Issue.record("no arrival spawned")
            return
        }
        #expect(system.apply(.vectorToFix, to: arrival.id))
        #expect(system.snapshot(of: system.aircraft.first { $0.id == arrival.id }!).vectored)
        #expect(system.apply(.direct, to: arrival.id))
        let after = system.aircraft.first { $0.id == arrival.id }!
        #expect(!system.snapshot(of: after).vectored)
    }

    @Test func aHeldArrivalOrbitsTheFixAndStaysInbound() {
        var system = quietSystem()
        for _ in 0..<50 { system.step(dt: 0.5) }
        guard let arrival = system.aircraft.first(where: { $0.kind == .arrival }) else {
            Issue.record("no arrival spawned")
            return
        }
        #expect(system.apply(.hold, to: arrival.id))
        // Ten minutes: the arrival flies to the orbit and keeps circling the fix.
        for _ in 0..<1_200 { system.step(dt: 0.5) }
        let a = system.aircraft.first { $0.id == arrival.id }!
        #expect(a.phase == .inbound)
        #expect(a.holding)
        #expect(system.distanceToApproachFix(a.position) < TrafficSystem.holdRadius + 1_000)
    }

    @Test func aReleasedArrivalReachesTheDownwind() {
        var system = quietSystem()
        for _ in 0..<50 { system.step(dt: 0.5) }
        guard let arrival = system.aircraft.first(where: { $0.kind == .arrival }) else {
            Issue.record("no arrival spawned")
            return
        }
        #expect(system.apply(.hold, to: arrival.id))
        for _ in 0..<600 { system.step(dt: 0.5) }
        #expect(system.apply(.release, to: arrival.id))
        var reached = false
        for _ in 0..<1_800 {
            system.step(dt: 0.5)
            if let a = system.aircraft.first(where: { $0.id == arrival.id }), a.phase != .inbound {
                reached = true
                break
            }
        }
        #expect(reached)
    }

    @Test func approachFixIsTheDownwindEntry() {
        let system = quietSystem()
        #expect(system.approachFix.x == TrafficPatternGeometry(leftTraffic: false).downwindStart)
        #expect(system.approachFix.y == TrafficPatternGeometry(leftTraffic: false).downwindOffset)
    }
}
