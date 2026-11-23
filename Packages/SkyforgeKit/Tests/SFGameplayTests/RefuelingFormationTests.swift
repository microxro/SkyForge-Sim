import Testing
import Foundation
import SFMath
@testable import SFGameplay

@Suite struct RefuelingFormationTests {
    /// A level tanker flying north at 150 m/s, 3 km up.
    let tanker = AITarget(id: "tanker", role: .friendly, position: SIMD3(0, 0, -3_000), heading: 0, speed: 150)

    /// Boom anchor for the tanker above, found from the same geometry the code uses:
    /// 30 m behind (south of) the tanker, 3 m below it.
    let boomPoint = SIMD3<Double>(-30, 0, -2_997)

    @Test func boomConnectsOnlyInsideTheStableZone() {
        let v = SIMD3<Double>(150, 0, 0)
        #expect(Refueling.anchorPoint(of: tanker, method: .boom) == boomPoint)
        #expect(Refueling.contact(method: .boom, tanker: tanker, receiverPosition: boomPoint, receiverVelocity: v) == .connected)
        // 5 m off the anchor: in the envelope, not stable.
        let near = boomPoint + SIMD3(0, 5, 0)
        #expect(Refueling.contact(method: .boom, tanker: tanker, receiverPosition: near, receiverVelocity: v) == .inEnvelope)
        // Stable position but closing at 5 m/s relative to the tanker: not connected.
        let fast = Refueling.contact(method: .boom, tanker: tanker, receiverPosition: boomPoint, receiverVelocity: v + SIMD3(5, 0, 0))
        #expect(fast == .inEnvelope)
        // Ahead of the tanker: out of range.
        let ahead = SIMD3<Double>(30, 0, -3_000)
        #expect(Refueling.contact(method: .boom, tanker: tanker, receiverPosition: ahead, receiverVelocity: v) == .none)
    }

    @Test func destroyedTankerNeverConnects() {
        var dead = tanker
        dead.health = 0
        #expect(Refueling.contact(method: .boom, tanker: dead, receiverPosition: boomPoint, receiverVelocity: SIMD3(150, 0, 0)) == .none)
    }

    @Test func refuelObjectiveTakesFuelWhileConnected() {
        let mission = MissionDefinition(
            id: "test-refuel", title: "Test refuel", category: .military, briefing: "", difficulty: 1,
            recommendedAircraft: "test", spawn: MissionSpawn(along: 0),
            targets: [TargetSpawn(id: "tanker", role: .friendly, along: 0, right: 0, up: 0, speed: 150)],
            objectives: [MissionObjective(id: "b", title: "Boom", kind: .refuel(tankerID: "tanker", method: .boom, kilograms: 90))],
            parTime: 60)
        var runtime = MissionRuntime(mission: mission, frame: RunwayFrame(threshold: .zero, heading: 0, length: 3_000, elevation: 0),
                                     aircraftID: "test")
        // 9 kg/s for 10 s is 90 kg. Step at 0.1 s; the first sample sets the clock, so the transfer runs from the second.
        var t = 0.0
        while !runtime.isFinished, t < 30 {
            runtime.update(sample: FlightSample(time: t, positionNED: boomPoint, velocityNED: SIMD3(150, 0, 0),
                                                heightAGL: 3_000, onGround: false), targets: [tanker])
            t += 0.1
        }
        #expect(runtime.status == .succeeded)
        #expect(runtime.result?.success == true)
        #expect(t > 9 && t < 12, "took \(t) s")
    }

    @Test func losingTheTankerFailsTheRefuelObjective() {
        let mission = MissionDefinition(
            id: "test-lost", title: "Lost tanker", category: .military, briefing: "", difficulty: 1,
            recommendedAircraft: "test", spawn: MissionSpawn(along: 0),
            targets: [TargetSpawn(id: "tanker", role: .friendly, along: 0, right: 0, up: 0, speed: 150)],
            objectives: [MissionObjective(id: "b", title: "Boom", kind: .refuel(tankerID: "tanker", method: .boom, kilograms: 90))],
            parTime: 60)
        var runtime = MissionRuntime(mission: mission, frame: RunwayFrame(threshold: .zero, heading: 0, length: 3_000, elevation: 0),
                                     aircraftID: "test")
        runtime.update(sample: FlightSample(time: 0, positionNED: boomPoint, velocityNED: SIMD3(150, 0, 0),
                                            heightAGL: 3_000, onGround: false), targets: [])
        #expect(runtime.isFinished)
        #expect(runtime.result?.success == false)
    }

    @Test func validationFlagsUnknownTankerAndLeader() {
        let badRefuel = MissionDefinition(
            id: "bad-refuel", title: "Bad", category: .military, briefing: "", difficulty: 1,
            recommendedAircraft: "test", spawn: MissionSpawn(along: 0),
            objectives: [MissionObjective(id: "b", title: "Boom", kind: .refuel(tankerID: "nobody", method: .boom, kilograms: 90))],
            parTime: 60)
        #expect(badRefuel.validationProblems.contains { $0.contains("unknown tanker") })

        let orphan = MissionDefinition(
            id: "orphan", title: "Orphan", category: .military, briefing: "", difficulty: 1,
            recommendedAircraft: "test", spawn: MissionSpawn(along: 0),
            targets: [TargetSpawn(id: "wing", role: .friendly, along: 0, right: 0, up: 0, speed: 100,
                                  behavior: .follow(leaderID: "missing", slot: .trail, spacing: 60))],
            objectives: [MissionObjective(id: "s", title: "Survive", kind: .survive(seconds: 10))],
            parTime: 60)
        #expect(orphan.validationProblems.contains { $0.contains("unknown or own leader") })
    }

    @Test func wingmanConvergesOnItsSlot() {
        var leader = AITarget(id: "lead", role: .friendly, position: SIMD3(0, 0, -1_000), heading: 0, speed: 140)
        var wing = AITarget(id: "wing", role: .friendly, position: SIMD3(-300, 80, -1_000), heading: 0.3, speed: 120,
                            behavior: .follow(leaderID: "lead", slot: .echelonRight, spacing: 60))
        var targets = [leader, wing]
        let dt = 1.0 / 120
        for _ in 0..<(120 * 20) {
            FormationFlight.step(&targets, dt: dt, threat: nil, threatVelocity: .zero)
        }
        leader = targets[0]
        wing = targets[1]
        let error = FormationGeometry.error(ownship: wing.position, leader: leader, slot: .echelonRight, spacing: 60)
        #expect(error < 1, "error \(error) m after 20 s")
    }

    @Test func followerCoastsWhenItsLeaderIsGone() {
        var leader = AITarget(id: "lead", role: .friendly, position: .zero, heading: 0, speed: 140)
        leader.health = 0
        let wing = AITarget(id: "wing", role: .friendly, position: SIMD3(0, 50, -1_000), heading: 0, speed: 100,
                            behavior: .follow(leaderID: "lead", slot: .trail, spacing: 60))
        var targets = [leader, wing]
        let dt = 1.0 / 120
        let before = targets[1].position
        FormationFlight.step(&targets, dt: dt, threat: nil, threatVelocity: .zero)
        let moved = targets[1].position - before
        #expect(abs(moved.x - 100 * dt) < 1e-9 && abs(moved.y) < 1e-9, "moved \(moved)")
    }
}
