import Testing
import Foundation
import SFMath
@testable import SFGameplay

@Suite struct MissionTests {
    @Test func frameRoundTripAndAxes() {
        let f = RunwayFrame(threshold: SIMD2(100, 200), heading: .pi / 2, length: 1_000, elevation: 50)
        let p = f.ned(along: 300, right: 40, up: 25)
        let l = f.local(p)
        #expect(abs(l.along - 300) < 1e-9 && abs(l.right - 40) < 1e-9 && abs(l.up - 25) < 1e-9)
        // Heading north: along is north, right is east.
        let n = testFrame.ned(along: 10, right: 5, up: 0)
        #expect(abs(n.x - 10) < 1e-9 && abs(n.y - 5) < 1e-9 && abs(n.z + 10) < 1e-9)
    }

    @Test func windIsRelativeToRunway() {
        let head = MissionWind(fromRelativeDegrees: 0, knots: 10).windNED(runwayHeading: 0)
        #expect(head.x < -5 && abs(head.y) < 1e-9)                   // from the north, blowing south
        let right = MissionWind(fromRelativeDegrees: 90, knots: 10).windNED(runwayHeading: 0)
        #expect(right.y < -5 && abs(right.x) < 1e-6)                 // from the east, blowing west
    }

    @Test func sequentialObjectivesAndTimeBonus() {
        var m = MissionDefinition(id: "t", title: "T", category: .training, briefing: "", difficulty: 1,
                                  recommendedAircraft: "x", spawn: MissionSpawn(along: 0, up: 100),
                                  objectives: [MissionObjective(id: "a", title: "A", kind: .flyTo(MissionWaypoint(1_000, 0, 100, radius: 100))),
                                               MissionObjective(id: "b", title: "B", kind: .flyTo(MissionWaypoint(2_000, 0, 100, radius: 100)))],
                                  parTime: 100, areaRadius: nil)
        m.timeLimit = 500
        var rt = MissionRuntime(mission: m, frame: testFrame, aircraftID: "x")
        // Passing the second waypoint first does nothing.
        rt.update(sample: airborne(along: 2_000, t: 0), targets: [])
        #expect(rt.objectiveIndex == 0)
        let e1 = rt.update(sample: airborne(along: 1_000, t: 10), targets: [])
        #expect(e1 == [.objectiveCompleted(id: "a")] && rt.objectiveIndex == 1)
        let e2 = rt.update(sample: airborne(along: 2_000, t: 20), targets: [])
        #expect(e2.contains(.succeeded) && rt.status == .succeeded)
        #expect(rt.result?.success == true && rt.result?.medal == .gold && rt.result!.score == 240)
    }

    @Test func failureRules() {
        let wp = ObjectiveKind.flyTo(MissionWaypoint(9_000, 0, 100))
        var rt = MissionRuntime(mission: oneObjectiveMission(wp, limit: 60), frame: testFrame, aircraftID: "x")
        rt.update(sample: airborne(t: 0), targets: [])
        rt.update(sample: airborne(t: 61), targets: [])
        #expect(rt.status == .failed("Out of time") && rt.result?.medal == Medal.none)

        var crash = MissionRuntime(mission: oneObjectiveMission(wp), frame: testFrame, aircraftID: "x")
        crash.update(sample: FlightSample(time: 1, positionNED: .zero, velocityNED: .zero, heightAGL: 0, onGround: true,
                                          crashed: true, crashReason: "Crashed into the ground"), targets: [])
        #expect(crash.status == .failed("Crashed into the ground"))

        var friendly = AITarget(id: "f", role: .friendly, position: .zero, heading: 0, speed: 0)
        friendly.health = 0
        var fr = MissionRuntime(mission: oneObjectiveMission(wp), frame: testFrame, aircraftID: "x")
        fr.update(sample: airborne(t: 0), targets: [friendly])
        #expect(fr.isFinished && fr.result?.success == false)
    }

    @Test func altitudeHoldNeedsContinuousTime() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.reachAltitude(up: 100, tolerance: 20, hold: 5)), frame: testFrame, aircraftID: "x")
        var t = 0.0
        for _ in 0..<30 { rt.update(sample: airborne(up: 100, t: t), targets: []); t += 0.1 }    // 3 s
        rt.update(sample: airborne(up: 200, t: t), targets: []); t += 0.1                       // leaves the band
        for _ in 0..<30 { rt.update(sample: airborne(up: 100, t: t), targets: []); t += 0.1 }
        #expect(rt.status == .inProgress)
        for _ in 0..<30 { rt.update(sample: airborne(up: 100, t: t), targets: []); t += 0.1 }
        #expect(rt.status == .succeeded)
    }

    private func landing(sink: Double, touchAlong: Double = 300, right: Double = 0) -> MissionRuntime {
        var rt = MissionRuntime(mission: oneObjectiveMission(.land(aimAlong: 300, zoneHalfLength: 200, maxSinkRate: 3)), frame: testFrame, aircraftID: "x")
        var t = 0.0
        for _ in 0..<5 { rt.update(sample: airborne(along: touchAlong - 50, right: right, up: 3, velocity: SIMD3(40, 0, sink), t: t), targets: []); t += 0.1 }
        let g = { (along: Double, speed: Double, t: Double) in
            FlightSample(time: t, positionNED: testFrame.ned(along: along, right: right, up: 0), velocityNED: SIMD3(speed, 0, 0), heightAGL: 0, onGround: true)
        }
        rt.update(sample: g(touchAlong, 40, t), targets: []); t += 0.1
        var speed = 40.0, along = touchAlong
        while speed > 0.5 && rt.status == .inProgress {
            speed = max(0, speed - 0.5); along += speed * 0.1
            rt.update(sample: g(along, speed, t), targets: []); t += 0.1
        }
        return rt
    }

    @Test func landingScoresByTouchdownQuality() {
        let soft = landing(sink: 0.6), firm = landing(sink: 2.5)
        #expect(soft.status == .succeeded && firm.status == .succeeded)
        #expect(soft.result!.score > firm.result!.score)
        #expect(landing(sink: 4.0).status == .failed("Hard landing"))
        #expect(landing(sink: 1.0, touchAlong: 1_700).status == .failed("Landed off the runway"))
        #expect(landing(sink: 1.0, right: 60).status == .failed("Landed off the runway"))
    }

    @Test func destroyAndIdentify() {
        let drone = AITarget(id: "d", role: .hostile, position: testFrame.ned(along: 1_000, right: 0, up: 100), heading: 0, speed: 0)
        var rt = MissionRuntime(mission: oneObjectiveMission(.identify(targetID: "d", within: 500, hold: 2)), frame: testFrame, aircraftID: "x")
        var t = 0.0
        for _ in 0..<10 { rt.update(sample: airborne(along: 400, t: t), targets: [drone]); t += 0.1 }
        #expect(rt.status == .inProgress)
        for _ in 0..<30 { rt.update(sample: airborne(along: 800, t: t), targets: [drone]); t += 0.1 }
        #expect(rt.status == .succeeded)

        var dead = drone; dead.health = 0
        var kill = MissionRuntime(mission: oneObjectiveMission(.destroy(targetIDs: ["d"])), frame: testFrame, aircraftID: "x")
        kill.update(sample: airborne(t: 0), targets: [drone]); #expect(kill.progress == 0)
        kill.update(sample: airborne(t: 1), targets: [dead]); #expect(kill.status == .succeeded)
    }

    @Test func formationHoldAndDecay() {
        let leader = AITarget(id: "l", role: .friendly, position: testFrame.ned(along: 1_000, right: 0, up: 500), heading: 0, speed: 0)
        let slotNED = FormationGeometry.slotPosition(leaderPosition: leader.position, heading: 0, slot: .echelonRight, spacing: 60)
        #expect(abs(slotNED.x - (leader.position.x - 60)) < 1e-9 && abs(slotNED.y - (leader.position.y + 60)) < 1e-9)
        let kind = ObjectiveKind.formation(leaderID: "l", slot: .echelonRight, spacing: 60, tolerance: 30, hold: 10)
        var rt = MissionRuntime(mission: oneObjectiveMission(kind), frame: testFrame, aircraftID: "x")
        var t = 0.0
        let atSlot = FlightSample(time: 0, positionNED: slotNED, velocityNED: .zero, heightAGL: 500, onGround: false)
        for _ in 0..<60 { var s = atSlot; s.time = t; rt.update(sample: s, targets: [leader]); t += 0.1 }
        #expect(rt.status == .inProgress && rt.progress > 0.5)
        for _ in 0..<80 { var s = atSlot; s.time = t; s.positionNED += SIMD3(0, 200, 0); rt.update(sample: s, targets: [leader]); t += 0.1 }
        #expect(rt.progress == 0)
        for _ in 0..<110 { var s = atSlot; s.time = t; rt.update(sample: s, targets: [leader]); t += 0.1 }
        #expect(rt.status == .succeeded)
    }

    @Test func catalogIsConsistentAndFullyUnlockable() {
        var progress = PlayerProgress()
        for m in MissionCatalog.all {
            #expect(AircraftCatalog.spec(id: m.recommendedAircraft) != nil, m.id)
            #expect(m.allows(AircraftCatalog.spec(id: m.recommendedAircraft)!), m.id)
            #expect(Set(m.objectives.map(\.id)).count == m.objectives.count, m.id)
            let ids = Set(m.targets.map(\.id))
            #expect(ids.count == m.targets.count, m.id)
            for o in m.objectives {
                switch o.kind {
                case .destroy(let t): #expect(Set(t).isSubset(of: ids), m.id)
                case .identify(let t, _, _): #expect(ids.contains(t), m.id)
                case .formation(let l, _, _, _, _): #expect(ids.contains(l), m.id)
                default: break
                }
            }
            if case .mission(let req) = m.unlock { #expect(MissionCatalog.mission(id: req) != nil, m.id) }
        }
        // Play through in unlock order: every mission must become flyable with an unlocked aircraft.
        var remaining = MissionCatalog.all
        while !remaining.isEmpty {
            guard let next = remaining.first(where: { progress.isUnlocked($0) && !progress.aircraft(for: $0).isEmpty }) else {
                Issue.record("deadlock, stuck on \(remaining.map(\.id))"); return
            }
            progress.record(MissionResult(missionID: next.id, aircraftID: "x", success: true, failureReason: nil,
                                          score: 100, medal: .bronze, elapsed: 60, objectivesCompleted: 1, breakdown: [:]))
            remaining.removeAll { $0.id == next.id }
        }
        #expect(progress.unlockedAircraft.count == AircraftCatalog.all.count)
    }
}
