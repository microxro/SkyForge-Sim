import Testing
import Foundation
import SFMath
import SFFlightModel
@testable import SFGameplay

@Suite struct ProgressTests {
    private func result(_ id: String, success: Bool = true, score: Int = 200, medal: Medal = .silver, elapsed: Double = 90) -> MissionResult {
        MissionResult(missionID: id, aircraftID: "x", success: success, failureReason: nil, score: score, medal: medal,
                      elapsed: elapsed, objectivesCompleted: 1, breakdown: [:])
    }

    @Test func freshProgressUnlocksOnlyTheBasics() {
        let p = PlayerProgress()
        #expect(p.unlockedAircraft.map(\.id) == [AircraftCatalog.sf1Trainer.id, AircraftCatalog.sfCruiser.id])
        #expect(p.unlockedMissions.map(\.id) == ["first-flight"])
    }

    @Test func recordingUnlocksAndKeepsBests() {
        var p = PlayerProgress()
        let unlocked = p.record(result("first-flight"))
        #expect(unlocked.aircraft.map(\.id) == [AircraftCatalog.sfAerobat.id] && unlocked.missions.map(\.id) == ["pattern-landing"])
        p.record(result("first-flight", score: 150, medal: .bronze, elapsed: 120))
        p.record(result("first-flight", success: false, score: 0, medal: .none))
        let r = p.records["first-flight"]!
        #expect(r.attempts == 3 && r.completions == 2 && r.bestScore == 200 && r.bestMedal == .silver && r.bestTime == 90)
        #expect(p.totalMedals == 1)
        let again = p.record(result("first-flight"))
        #expect(again.aircraft.isEmpty && again.missions.isEmpty)    // nothing new the second time
    }

    @Test func medalRequirement() {
        var p = PlayerProgress()
        #expect(!p.isUnlocked(UnlockRequirement.medals(1)))
        p.record(result("first-flight"))
        #expect(p.isUnlocked(UnlockRequirement.medals(1)) && !p.isUnlocked(UnlockRequirement.medals(2)))
    }

    @Test func storeRoundTripsAndToleratesCorruption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfgameplay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProgressStore(url: dir.appendingPathComponent("progress.json"))
        #expect(store.load() == PlayerProgress())           // missing file
        var p = PlayerProgress()
        p.record(result("first-flight"))
        p.selectedAircraftID = AircraftCatalog.sfAerobat.id
        try store.save(p)
        #expect(store.load() == p)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load() == PlayerProgress())           // corrupt file
    }

    @Test func missionAndAircraftFilters() {
        var p = PlayerProgress()
        let wingman = MissionCatalog.wingman
        #expect(p.aircraft(for: wingman).isEmpty)           // jets locked
        p.record(result("first-flight")); p.record(result("pattern-landing"))
        #expect(p.aircraft(for: wingman).map(\.id) == [AircraftCatalog.sfT1Jet.id])
        #expect(p.aircraft(for: MissionCatalog.firstFlight).count == 3)
    }
}

@Suite struct SessionTests {
    let world = FlatWorld()

    @Test func freeFlightSitsOnTheRunwayAndStaysFinite() {
        for a in AircraftCatalog.all {
            var s = GameplaySession(world: world, aircraft: a)
            for _ in 0..<240 { s.step(PilotControls()) }
            #expect(!s.crashed && s.onGround && s.state.isFinite, "\(a.name) crashed=\(s.crashed) \(s.crashReason ?? "")")
            #expect(abs(s.state.velocityBody.x) < 0.5, "\(a.name) should be at rest")
        }
    }

    @Test func missionSpawnTrimmedAndFlyable() {
        let s0 = GameplaySession(world: world, aircraft: AircraftCatalog.sfF1Fighter, mission: MissionCatalog.intercept)
        #expect(abs(s0.trueAirspeed - 220) < 3 && abs(s0.heightAGL - 3_000) < 5)
        var s = s0
        for _ in 0..<(120 * 5) { var c = PilotControls(); c.flight = s0.spawnTrim; s.step(c) }
        #expect(!s.crashed && abs(s.heightAGL - 3_000) < 80, "drifted to \(s.heightAGL) m")
        #expect(s.targets.count == 1 && s.runtime?.currentObjective?.id == "identify")
    }

    @Test func precisionLandingStartsOnFinalWithCrosswind() {
        let s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer, mission: MissionCatalog.precisionLanding)
        let local = s.frame.local(s.state.positionNED)
        #expect(abs(local.along + 2_500) < 1 && abs(local.up - 135) < 1)
        #expect(abs(s.environment.windNED.y) > 5)           // crosswind from the right blows toward the left
        #expect(abs(s.trueAirspeed - AircraftCatalog.sf1Trainer.approachSpeed) < 2)
    }

    @Test func scriptedTakeoffGetsAirborne() {
        for a in [AircraftCatalog.sf1Trainer, AircraftCatalog.sfT1Jet] {
            var s = GameplaySession(world: world, aircraft: a)
            var airborneAt: Double?
            for _ in 0..<(120 * 60) {
                var c = PilotControls()
                c.flight.throttle = 1
                c.flight.elevator = s.trueAirspeed >= a.rotateSpeed ? 0.15 : 0
                s.step(c)
                if !s.onGround && airborneAt == nil { airborneAt = s.time }
                if s.crashed { break }
            }
            #expect(!s.crashed, "\(a.name): \(s.crashReason ?? "")")
            #expect(airborneAt != nil && s.heightAGL > 5, "\(a.name) airborne at \(String(describing: airborneAt)), height \(s.heightAGL)")
        }
    }

    @Test func fighterLimiterKeepsTheAirframeIntactUnderFullBackStick() {
        let a = AircraftCatalog.sfF1Fighter
        var s = GameplaySession(world: world, aircraft: a, mission: MissionCatalog.intercept)
        var peak = 0.0
        for _ in 0..<(120 * 6) {
            var c = PilotControls(); c.flight = s.spawnTrim; c.flight.elevator = 1
            s.step(c)
            peak = max(peak, s.loadFactor)
        }
        #expect(!s.crashed, "\(s.crashReason ?? "")")
        #expect(peak < a.limits.nzMax * 1.5, "peak \(peak) g")
        #expect(s.state.isFinite)
    }

    @Test func crashEndsTheMission() {
        // Nose-down with no power from 100 m: hits the ground well below the overspeed limit.
        let m = oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 100)))
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer, mission: m)
        for _ in 0..<(120 * 60) where !s.isFinished {
            var c = PilotControls(); c.flight.elevator = -0.2
            s.step(c)
        }
        #expect(s.crashed && s.missionResult?.success == false)
        let reason = s.crashReason ?? ""
        #expect(s.drainEvents().contains(.crashed(reason)))
        #expect(s.drainEvents().isEmpty)
    }

    @Test func hudReflectsMissionState() {
        let s = GameplaySession(world: world, aircraft: AircraftCatalog.sfF1Fighter, mission: MissionCatalog.intercept)
        let h = s.hud
        #expect(h.objectiveCount == 2 && h.objectiveNumber == 1 && h.objectiveTitle?.hasPrefix("Identify") == true)
        #expect(h.cannonRounds == 500 && h.missiles == 4 && h.timeText == "0:00")
    }
}
