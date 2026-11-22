import Testing
import Foundation
import SFMath
import SFFlightModel
@testable import SFGameplay

@Suite struct HardeningTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sfgameplay-\(UUID().uuidString)")
    }

    @Test func builtInMissionsAreValid() {
        for m in MissionCatalog.all { #expect(m.validationProblems.isEmpty, "\(m.id): \(m.validationProblems)") }
    }

    @Test func invalidMissionsFailAtOnceInsteadOfSoftLocking() {
        let empty = MissionDefinition(id: "e", title: "E", category: .training, briefing: "", difficulty: 1, recommendedAircraft: "x",
                                      spawn: MissionSpawn(along: 0), objectives: [], parTime: 10)
        #expect(empty.validationProblems == ["no objectives"])
        var rt = MissionRuntime(mission: empty, frame: testFrame, aircraftID: "x")
        rt.update(sample: airborne(t: 0), targets: [])
        #expect(rt.status == .failed("Invalid mission: no objectives"))

        let unknown = oneObjectiveMission(.destroy(targetIDs: ["ghost"]))
        #expect(unknown.validationProblems.contains("o: unknown target id"))
        #expect(MissionRuntime(mission: unknown, frame: testFrame, aircraftID: "x").isFinished)
        #expect(!oneObjectiveMission(.destroy(targetIDs: [])).validationProblems.isEmpty)
    }

    @Test func extremeSaveValuesAreClampedNotTrapped() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProgressStore(url: dir.appendingPathComponent("progress.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"version":1,"selectedAircraftID":"org.skyforge.sff1","records":{"first-flight":
        {"attempts":9223372036854775807,"completions":-5,"bestScore":9223372036854775807,"bestMedal":2,"bestTime":-1}}}
        """
        try Data(json.utf8).write(to: store.url)
        var p = store.load()
        let r = p.records["first-flight"]!
        #expect(r.attempts == MissionRecord.limit && r.completions == 0 && r.bestScore == MissionRecord.limit && r.bestTime == nil)
        #expect(p.selectedAircraftID == AircraftCatalog.sf1Trainer.id)      // the fighter is still locked
        // Recording on top of a maxed record must not overflow.
        let result = MissionResult(missionID: "first-flight", aircraftID: "x", success: true, failureReason: nil, score: Int.max,
                                   medal: .gold, elapsed: .nan, objectivesCompleted: 1, breakdown: [:])
        p.record(result)
        #expect(p.records["first-flight"]!.attempts == MissionRecord.limit && p.records["first-flight"]!.bestTime == nil)
    }

    @Test func unreadableSavesAreKeptAsBackups() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProgressStore(url: dir.appendingPathComponent("progress.json"))
        try Data("{ broken".utf8).write(to: store.url)
        func backups() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("progress.json.bak") }.count
        }
        #expect(store.load() == PlayerProgress())
        #expect(backups() == 1)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        // A save larger than the cap is treated the same way.
        Thread.sleep(forTimeInterval: 0.01)
        try Data(repeating: 0x20, count: ProgressStore.maxFileSize + 1).write(to: store.url)
        #expect(store.load() == PlayerProgress())
        #expect(backups() == 2)                 // the first backup survives
        // A newer version is not overwritten silently.
        Thread.sleep(forTimeInterval: 0.01)
        try Data(#"{"version":99}"#.utf8).write(to: store.url)
        #expect(store.load() == PlayerProgress())
        #expect(backups() == 3)
        // An unknown medal value loses the medal but keeps the record.
        try Data(#"{"version":1,"records":{"first-flight":{"completions":2,"bestMedal":42}}}"#.utf8).write(to: store.url)
        #expect(store.load().records["first-flight"]?.completions == 2)
    }

    @Test func missingFieldsFallBackToDefaults() throws {
        let p = try JSONDecoder().decode(PlayerProgress.self, from: Data("{}".utf8))
        #expect(p == PlayerProgress())
    }

    @Test func canStartChecksUnlocksAndRoles() {
        var p = PlayerProgress()
        #expect(p.canStart(MissionCatalog.firstFlight, in: AircraftCatalog.sf1Trainer))
        #expect(!p.canStart(MissionCatalog.firstFlight, in: AircraftCatalog.sfT1Jet))            // wrong role and locked
        #expect(!p.canStart(MissionCatalog.patternLanding, in: AircraftCatalog.sf1Trainer))      // mission locked
        p.record(MissionResult(missionID: "first-flight", aircraftID: "x", success: true, failureReason: nil, score: 1,
                               medal: .bronze, elapsed: 1, objectivesCompleted: 1, breakdown: [:]))
        #expect(p.canStart(MissionCatalog.patternLanding, in: AircraftCatalog.sf1Trainer))
    }

    @Test func nonFiniteFrameTimesAreIgnored() {
        var s = GameplaySession(world: FlatWorld(), aircraft: AircraftCatalog.sf1Trainer)
        s.update(realDt: .nan, controls: PilotControls())
        s.update(realDt: -1, controls: PilotControls())
        s.update(realDt: .infinity, controls: PilotControls())
        #expect(s.time == 0)
        s.update(realDt: 0.05, controls: PilotControls())
        #expect(s.time > 0.04)
    }

    @Test func lowLevelRouteFailsBelowTheFloorAndMissionAreaIsEnforced() {
        let kind = ObjectiveKind.lowLevelRoute(points: [MissionWaypoint(5_000, 0, 100)], minAGL: 30, maxAGL: 200)
        var rt = MissionRuntime(mission: oneObjectiveMission(kind), frame: testFrame, aircraftID: "x")
        var t = 0.0
        for _ in 0..<50 where !rt.isFinished { rt.update(sample: airborne(along: 100, up: 10, t: t), targets: []); t += 0.1 }
        #expect(rt.status == .failed("Terrain clearance lost"))

        var m = oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 100)))
        m.areaRadius = 1_000
        var area = MissionRuntime(mission: m, frame: testFrame, aircraftID: "x")
        area.update(sample: airborne(along: 5_000, t: 0), targets: [])
        #expect(area.status == .failed("Left the mission area"))
    }

    @Test func aBouncedLandingStillCountsButScoresLess() {
        func run(bounce: Bool) -> Int? {
            var rt = MissionRuntime(mission: oneObjectiveMission(.land(aimAlong: 300, zoneHalfLength: 200, maxSinkRate: 3)), frame: testFrame, aircraftID: "x")
            var t = 0.0
            func air(_ along: Double) { rt.update(sample: airborne(along: along, up: 2, velocity: SIMD3(40, 0, 1), t: t), targets: []); t += 0.1 }
            func ground(_ along: Double, _ v: Double) {
                rt.update(sample: FlightSample(time: t, positionNED: testFrame.ned(along: along, right: 0, up: 0),
                                               velocityNED: SIMD3(v, 0, 0), heightAGL: 0, onGround: true), targets: []); t += 0.1
            }
            for _ in 0..<3 { air(250) }
            ground(300, 40)
            if bounce { for _ in 0..<8 { air(340) }; ground(380, 38) }
            var v = 38.0, a = 380.0
            while v > 0.5 && !rt.isFinished { v = max(0, v - 0.5); a += v * 0.1; ground(a, v) }
            return rt.result?.success == true ? rt.result?.score : nil
        }
        let clean = run(bounce: false), bounced = run(bounce: true)
        #expect(clean != nil && bounced != nil)
        #expect(clean! > bounced!)
    }

    @Test func wheelFlickerDuringRolloutIsNotABounce() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.land(aimAlong: 300, zoneHalfLength: 200, maxSinkRate: 3)), frame: testFrame, aircraftID: "x")
        var t = 0.0
        for _ in 0..<5 { rt.update(sample: airborne(along: 250, up: 2, velocity: SIMD3(40, 0, 1), t: t), targets: []); t += 0.1 }
        var a = 300.0, v = 40.0, flicker = 0
        while v > 0.5 && !rt.isFinished {
            v = max(0, v - 0.4); a += v * 0.1
            // Every fifth step the wheels lift for one sample, at a sink rate that would fail a landing.
            let lifted = v > 20 && (flicker % 5 == 4)
            flicker += 1
            rt.update(sample: FlightSample(time: t, positionNED: testFrame.ned(along: a, right: 0, up: lifted ? 0.2 : 0),
                                           velocityNED: SIMD3(v, 0, lifted ? 5 : 0), heightAGL: lifted ? 0.2 : 0, onGround: !lifted), targets: [])
            t += 0.1
        }
        #expect(rt.status == .succeeded)
    }

    @Test func landingObjectiveStartedOnTheGroundCompletesAfterStopping() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.land(aimAlong: 300, zoneHalfLength: 200, maxSinkRate: 3)), frame: testFrame, aircraftID: "x")
        var t = 0.0, v = 10.0
        while v > 0.5 && !rt.isFinished {
            v = max(0, v - 0.5)
            rt.update(sample: FlightSample(time: t, positionNED: testFrame.ned(along: 300, right: 0, up: 0), velocityNED: SIMD3(v, 0, 0),
                                           heightAGL: 0, onGround: true), targets: [])
            t += 0.1
        }
        #expect(rt.status == .succeeded)
    }

    @Test func nanHealthTargetsCountAsDestroyed() {
        var t = AITarget(id: "t", role: .hostile, position: .zero, heading: 0, speed: 0)
        #expect(!t.destroyed)
        t.health = .nan
        #expect(t.destroyed)
    }

    @Test func friendlyFireDestroysTheMission() {
        let own = Ownship(position: SIMD3(0, 0, -3_000), velocity: SIMD3(200, 0, 0), forward: SIMD3(1, 0, 0))
        var weapons = WeaponSystem(kinds: [.cannon])
        var targets = [AITarget(id: "lead", role: .friendly, position: SIMD3(500, 0, -3_000), heading: 0, speed: 0)]
        for _ in 0..<(120 * 3) { _ = weapons.update(dt: 1.0 / 120, ownship: own, input: WeaponInput(fireGun: true), targets: &targets) }
        #expect(targets[0].destroyed)           // the gun does not discriminate
        var rt = MissionRuntime(mission: oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 100))), frame: testFrame, aircraftID: "x")
        rt.update(sample: airborne(t: 0), targets: targets)
        #expect(rt.status == .failed("A friendly or neutral aircraft was destroyed"))
    }

    @Test func directorCountsKillsIntoTheResult() {
        let drone = TargetSpawn(id: "d", role: .hostile, along: 600, right: 0, up: 3_000, speed: 0, health: 6)
        let mission = oneObjectiveMission(.destroy(targetIDs: ["d"]), targets: [drone])
        var director = GameplayDirector(aircraft: AircraftCatalog.sfF1Fighter, frame: testFrame, mission: mission)
        var state = AircraftState(positionNED: testFrame.ned(along: 0, right: 0, up: 3_000), velocityBody: SIMD3(200, 0, 0),
                                  attitude: .identity, bodyRates: .zero)
        let outputs = AircraftCatalog.sfF1Fighter.model.outputs(state, inputs: ControlInputs(), environment: FlightEnvironment())
        var t = 0.0
        for _ in 0..<(120 * 3) where !director.isFinished {
            state.time = t
            director.advance(dt: 1.0 / 120, snapshot: FlightSnapshot(time: t, state: state, outputs: outputs, flaps: 0, heightAGL: 3_000),
                             weaponInput: WeaponInput(fireGun: true))
            t += 1.0 / 120
        }
        #expect(director.kills == 1)
        #expect(director.runtime?.result?.success == true && director.runtime?.result?.kills == 1)
    }
}
