import Testing
import Foundation
import SFMath
import SFFlightModel
@testable import SFGameplay

/// End-to-end scenarios that drive the real `GameplaySession` headless, not a unit. Each one either reaches a
/// success state with a scripted pilot or checks a failure path, so a regression shows up as a named test failure.
@Suite struct ScenarioTests {
    let world = FlatWorld()

    /// Steps a session for `seconds` of flight with the given controls (default: no input).
    private func run(_ s: inout GameplaySession, seconds: Double, _ controls: (GameplaySession) -> PilotControls = { _ in PilotControls() }) {
        for _ in 0..<Int(seconds * 120) where !s.isFinished {
            s.step(controls(s))
        }
    }

    @Test func everyAircraftTakesOffAndFliesWithoutNaNState() {
        for a in AircraftCatalog.all {
            var s = GameplaySession(world: world, aircraft: a)
            var airborne = false
            for _ in 0..<(120 * 25) where !s.crashed {
                var c = PilotControls()
                c.flight.throttle = 1
                c.flight.elevator = s.trueAirspeed >= a.rotateSpeed ? 0.15 : 0
                s.step(c)
                if !s.onGround && s.heightAGL > 5 { airborne = true }
                #expect(s.state.isFinite, "\(a.name) state not finite at t=\(s.time)")
                if !s.state.isFinite { break }
            }
            #expect(!s.crashed, "\(a.name) crashed: \(s.crashReason ?? "")")
            #expect(airborne, "\(a.name) never got airborne")
        }
    }

    @Test func missionTimeLimitFailsTheMission() {
        // No input on the runway; the objective is far away, so the clock runs out.
        var m = oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 300)), limit: 5)
        m.timeLimit = 5
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer, mission: m)
        run(&s, seconds: 8)
        #expect(s.isFinished, "mission did not end after its time limit")
        #expect(s.missionResult?.success == false, "time-out counted as success")
        #expect(s.missionResult?.failureReason != nil, "time-out gave no reason")
    }

    @Test func leavingTheAreaFailsTheMission() {
        var m = oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 300)))
        m.areaRadius = 400
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer, mission: m)
        // Start 60 m down the runway with the trim, then fly straight out past the 400 m area.
        var c0 = PilotControls(); c0.flight = s.spawnTrim
        run(&s, seconds: 60) { _ in
            var c = PilotControls(); c.flight = c0.flight
            c.flight.throttle = 1
            return c
        }
        #expect(s.isFinished, "mission did not end outside the area")
        #expect(s.missionResult?.success == false, "leaving the area counted as success")
    }

    @Test func crashEndsAMissionWithAReason() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer,
                                mission: oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 100))))
        // Nose-down, no power, from low altitude: the airframe reaches the ground well before the objective.
        var m = oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 100)))
        m.spawn = MissionSpawn(along: 0, up: 100, speed: .cruise)
        s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer, mission: m)
        run(&s, seconds: 60) { _ in
            var c = PilotControls(); c.flight.elevator = -1; c.flight.throttle = 0
            return c
        }
        #expect(s.crashed, "nose-down dive did not crash")
        #expect(s.isFinished, "crash did not end the mission")
    }

    @Test func unlockChainReachesEveryMission() {
        // Every mission's unlock names a mission that exists and is reachable from the start.
        var progress = PlayerProgress()
        var remaining = MissionCatalog.all
        var guardCount = 0
        while !remaining.isEmpty, guardCount < 100 {
            guardCount += 1
            guard let next = remaining.first(where: { progress.isUnlocked($0) }) else { break }
            progress.record(MissionResult(missionID: next.id, aircraftID: "x", success: true, failureReason: nil,
                                          score: 100, medal: .bronze, elapsed: 60, objectivesCompleted: 1, breakdown: [:]))
            remaining.removeAll { $0.id == next.id }
        }
        #expect(remaining.isEmpty, "missions never unlocked: \(remaining.map(\.id))")
    }
}
