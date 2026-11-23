import Testing
import Foundation
import SFMath
@testable import SFGameplay

@Suite struct CombatMissionTests {
    private func hostile(_ id: String = "b", health: Double = 10) -> AITarget {
        AITarget(id: id, role: .hostile, position: testFrame.ned(along: 5_000, right: 0, up: 100), heading: 0, speed: 100, health: health)
    }

    private func bandit(_ id: String = "b") -> TargetSpawn {
        TargetSpawn(id: id, role: .hostile, along: 5_000, right: 0, up: 100, speed: 100)
    }

    @Test func surviveCompletesAfterSecondsAndNotBefore() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.survive(seconds: 5)), frame: testFrame, aircraftID: "x")
        var step = 0
        while step <= 45 {
            rt.update(sample: airborne(t: Double(step) * 0.1), targets: [])
            step += 1
        }
        #expect(rt.status == .inProgress)
        #expect(rt.progress > 0.85 && rt.progress < 1)
        while step <= 55 && rt.status == .inProgress {
            rt.update(sample: airborne(t: Double(step) * 0.1), targets: [])
            step += 1
        }
        #expect(rt.status == .succeeded)
        #expect(step <= 53)
    }

    @Test func surviveFailsIfCrashed() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.survive(seconds: 5)), frame: testFrame, aircraftID: "x")
        rt.update(sample: airborne(t: 0), targets: [])
        let crashed = FlightSample(time: 1, positionNED: testFrame.ned(along: 0, right: 0, up: 0), velocityNED: .zero,
                                   heightAGL: 0, onGround: true, crashed: true, crashReason: "Shot down")
        rt.update(sample: crashed, targets: [])
        #expect(rt.status == .failed("Shot down"))
    }

    @Test func radarLockCompletesAfterHold() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.radarLock(targetID: "b", hold: 2), targets: [bandit()]),
                                frame: testFrame, aircraftID: "x")
        var step = 0
        while step <= 15 {
            rt.update(sample: airborne(t: Double(step) * 0.1), targets: [hostile()], radarLockedID: "b")
            step += 1
        }
        #expect(rt.status == .inProgress)
        while step <= 25 && rt.status == .inProgress {
            rt.update(sample: airborne(t: Double(step) * 0.1), targets: [hostile()], radarLockedID: "b")
            step += 1
        }
        #expect(rt.status == .succeeded)
    }

    @Test func radarLockResetsWhenLockDrops() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.radarLock(targetID: "b", hold: 2), targets: [bandit()]),
                                frame: testFrame, aircraftID: "x")
        var step = 0
        // 1.5 s locked, 0.5 s without a lock, then 1.5 s locked again: never 2 s in a row.
        while step <= 15 { rt.update(sample: airborne(t: Double(step) * 0.1), targets: [hostile()], radarLockedID: "b"); step += 1 }
        while step <= 20 { rt.update(sample: airborne(t: Double(step) * 0.1), targets: [hostile()], radarLockedID: nil); step += 1 }
        #expect(rt.progress == 0)
        while step <= 35 { rt.update(sample: airborne(t: Double(step) * 0.1), targets: [hostile()], radarLockedID: "b"); step += 1 }
        #expect(rt.status == .inProgress)
        // A lock on some other target does not count either.
        rt.update(sample: airborne(t: 3.6), targets: [hostile()], radarLockedID: "other")
        #expect(rt.progress == 0)
    }

    @Test func radarLockFailsWhenTargetDestroyedFirst() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.radarLock(targetID: "b", hold: 2), targets: [bandit()]),
                                frame: testFrame, aircraftID: "x")
        rt.update(sample: airborne(t: 0), targets: [hostile()], radarLockedID: "b")
        rt.update(sample: airborne(t: 0.1), targets: [hostile(health: 0)], radarLockedID: "b")
        #expect(rt.status == .failed("Target destroyed before it was locked"))
    }

    @Test func combatTallyIsStoredAndReported() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.survive(seconds: 1)), frame: testFrame, aircraftID: "x")
        var tally = CombatTally()
        tally.hitsTaken = 3; tally.damageTaken = 12.5; tally.countermeasuresUsed = 4
        tally.missilesFired = 2; tally.missilesHit = 1
        var step = 0
        while step <= 15 && rt.status == .inProgress {
            rt.update(sample: airborne(t: Double(step) * 0.1), targets: [], combat: tally)
            step += 1
        }
        #expect(rt.status == .succeeded)
        #expect(rt.combat == tally)
        #expect(rt.result?.combat == tally)
    }

    @Test func resultDecodesWithoutCombatKey() throws {
        var tally = CombatTally()
        tally.hitsTaken = 2
        let original = MissionResult(missionID: "m", aircraftID: "a", success: true, failureReason: nil, score: 400,
                                     medal: .silver, elapsed: 90, objectivesCompleted: 2, kills: 1,
                                     breakdown: ["o": 400], combat: tally)
        let data = try JSONEncoder().encode(original)
        let roundTrip = try JSONDecoder().decode(MissionResult.self, from: data)
        #expect(roundTrip == original)

        let object = try JSONSerialization.jsonObject(with: data)
        guard var dict = object as? [String: Any] else { Issue.record("result is not a JSON object"); return }
        #expect(dict["combat"] != nil)
        dict.removeValue(forKey: "combat")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let old = try JSONDecoder().decode(MissionResult.self, from: stripped)
        #expect(old.combat == CombatTally())
        #expect(old.missionID == "m" && old.score == 400 && old.kills == 1 && old.medal == .silver)
    }

    @Test func newMissionsAreSoundAndChained() {
        for id in ["radar-intercept", "two-ship-defence"] {
            guard let m = MissionCatalog.mission(id: id) else { Issue.record("missing \(id)"); continue }
            #expect(m.validationProblems.isEmpty, "\(id): \(m.validationProblems)")
            #expect(Set(m.objectives.map(\.id)).count == m.objectives.count, "\(id)")
            #expect(m.category == .military)
            #expect(m.allowedRoles == [.fighter])
            #expect(m.recommendedAircraft == AircraftCatalog.sfF1Fighter.id)
            if case .mission(let req) = m.unlock { #expect(MissionCatalog.mission(id: req) != nil, "\(id)") }
            else { Issue.record("\(id) should unlock behind a mission") }
        }
        #expect(MissionCatalog.mission(id: "two-ship-defence")?.unlock == .mission("radar-intercept"))
        #expect(MissionCatalog.mission(id: "radar-intercept")?.unlock == .mission("air-combat-training"))
    }

    @Test func validationCatchesBadCombatObjectives() {
        let badSurvive = oneObjectiveMission(.survive(seconds: 0))
        #expect(!badSurvive.validationProblems.isEmpty)
        let unknownLock = oneObjectiveMission(.radarLock(targetID: "ghost", hold: 2), targets: [bandit()])
        #expect(!unknownLock.validationProblems.isEmpty)
        let negativeHold = oneObjectiveMission(.radarLock(targetID: "b", hold: -1), targets: [bandit()])
        #expect(!negativeHold.validationProblems.isEmpty)
        let ok = oneObjectiveMission(.radarLock(targetID: "b", hold: 0), targets: [bandit()])
        #expect(ok.validationProblems.isEmpty)
    }

    @Test func dogfightBehaviorRoundTripsAndMaps() throws {
        var settings = DogfightSettings()
        settings.maxTurnRate = 0.31
        let behavior = MissionTargetBehavior.dogfight(settings)
        let data = try JSONEncoder().encode(behavior)
        let decoded = try JSONDecoder().decode(MissionTargetBehavior.self, from: data)
        #expect(decoded == behavior)

        let spawned = TargetSpawn(id: "d", role: .hostile, along: 1_000, right: 0, up: 100, speed: 150, behavior: behavior)
        let target = spawned.makeTarget(frame: testFrame)
        #expect(target.behavior == .dogfight(settings))
    }
}
