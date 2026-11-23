import Testing
import Foundation
import SFMath
import SFFlightModel
@testable import SFGameplay

/// Combat wired into the director, the session and the HUD. Mutating calls are hoisted into locals before
/// each #expect, because #expect captures its expression immutably.
private func isPlayerDamaged(_ e: GameEvent) -> Bool {
    if case .playerDamaged = e { return true }
    return false
}

@Suite struct CombatSessionTests {
    let world = FlatWorld()

    @Test func freeFlightWithoutCombatInputTakesNoDamage() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer)
        var damageEvents = 0
        for _ in 0..<240 {
            s.step(PilotControls())
            let events: [GameEvent] = s.drainEvents()
            damageEvents += events.filter { isPlayerDamaged($0) }.count
        }
        #expect(damageEvents == 0)
        #expect(s.damage == AircraftDamage())
        #expect(s.damage.airframe == 1)
        #expect(s.combat == CombatTally())
        #expect(!s.crashed && s.onGround)
        #expect(s.radar.mode == .off)
        #expect(s.countermeasures.flares == CountermeasureSystem.defaultFlares)
    }

    @Test func intactDamageLeavesInputsUnchanged() {
        let inputs = ControlInputs(elevator: -0.3, aileron: 0.7, rudder: -1, throttle: 0.85, flaps: 0.5,
                                   brakes: 0.2, elevatorTrim: 0.1, gear: 0.4, speedbrake: 0.3)
        let scaled: ControlInputs = GameplaySession.applyDamageScaling(inputs, damage: AircraftDamage())
        #expect(scaled == inputs)
        let zero: ControlInputs = GameplaySession.applyDamageScaling(ControlInputs(), damage: AircraftDamage())
        #expect(zero == ControlInputs())
    }

    @Test func deadEngineGivesZeroThrottleAndDeadControlsKeepMinimumAuthority() {
        var engineHit = AircraftDamage()
        let engineKilled: Bool = engineHit.apply(source: .missile, zone: .engine, amount: 0.5)
        #expect(!engineKilled)
        #expect(engineHit.engineOut)
        let inputs = ControlInputs(elevator: 0.5, aileron: -0.5, rudder: 0.25, throttle: 1, flaps: 1, gear: 1)
        let noThrust: ControlInputs = GameplaySession.applyDamageScaling(inputs, damage: engineHit)
        #expect(noThrust.throttle == 0)
        #expect(noThrust.elevator == 0.5 && noThrust.aileron == -0.5 && noThrust.rudder == 0.25)
        #expect(noThrust.flaps == 1 && noThrust.gear == 1)

        var controlsHit = AircraftDamage()
        let controlsKilled: Bool = controlsHit.apply(source: .missile, zone: .controls, amount: 0.5)
        #expect(!controlsKilled)
        let sluggish: ControlInputs = GameplaySession.applyDamageScaling(inputs, damage: controlsHit)
        #expect(abs(sluggish.elevator - 0.1) < 1e-12)       // 0.5 x the 0.2 authority floor
        #expect(abs(sluggish.aileron + 0.1) < 1e-12)
        #expect(abs(sluggish.rudder - 0.05) < 1e-12)
        #expect(sluggish.throttle == 1 && sluggish.flaps == 1 && sluggish.gear == 1)
    }

    @Test func hitZoneRuleIsDeterministic() {
        #expect(GameplayDirector.hitZone(hitIndex: 0) == .airframe)
        #expect(GameplayDirector.hitZone(hitIndex: 3) == .airframe)
        #expect(GameplayDirector.hitZone(hitIndex: 4) == .engine)
        #expect(GameplayDirector.hitZone(hitIndex: 6) == .controls)
        #expect(GameplayDirector.hitZone(hitIndex: 9) == .engine)
        #expect(GameplayDirector.hitZone(hitIndex: 13) == .controls)
        #expect(GameplayDirector.hitZone(hitIndex: 34) == .engine)       // both rules: engine wins
        #expect(GameplayDirector.hitZone(hitIndex: -5) == .airframe)
        var engine = 0, controls = 0
        for i in 0..<70 {
            let zone: DamageZone = GameplayDirector.hitZone(hitIndex: i)
            if zone == .engine { engine += 1 }
            if zone == .controls { controls += 1 }
        }
        #expect(engine == 14 && controls == 8)
    }

    @Test func destroyedAirframeShootsTheSessionDown() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sfF1Fighter)
        s.step(PilotControls())
        let before: [GameEvent] = s.drainEvents()
        #expect(before.filter { isPlayerDamaged($0) }.isEmpty)

        s.receiveHostileEvents([.missileHit(sourceID: "bandit")])
        #expect(!s.crashed)
        #expect(s.damage.airframe == 0.5)
        s.receiveHostileEvents([.missileHit(sourceID: "bandit"), .missileHit(sourceID: "late")])
        #expect(s.damage.destroyed)
        #expect(s.crashed)
        #expect(s.crashReason == "Shot down by bandit")
        #expect(s.crashReason?.hasPrefix("Shot down") == true)
        #expect(s.director.destroyedBy == "bandit")
        #expect(s.isFinished)
        // The hit after destruction applies nothing and is not counted.
        #expect(s.combat.hitsTaken == 2)
        #expect(s.combat.damageTaken == 1.0)

        let events: [GameEvent] = s.drainEvents()
        #expect(events.filter { isPlayerDamaged($0) }.count == 2)
        #expect(events.contains(.playerDamaged(source: .missile, amount: AircraftDamage.missileWarheadDamage)))
        #expect(events.contains(.hostile(.missileHit(sourceID: "bandit"))))
        #expect(events.contains(.hostile(.missileHit(sourceID: "late"))))
        #expect(events.contains(.crashed("Shot down by bandit")))
    }

    @Test func cannonHitsFollowTheZoneRule() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sfF1Fighter)
        let burst: [HostileWeaponEvent] = Array(repeating: .cannonHit(sourceID: "gunner"), count: 5)
        s.receiveHostileEvents(burst)
        // Hits 0...3 strike the airframe; hit 4 strikes the engine (2x to the engine, 0.25x to the airframe).
        let expectedAirframe: Double = 1 - 4 * AircraftDamage.cannonRoundDamage - 0.25 * AircraftDamage.cannonRoundDamage
        #expect(abs(s.damage.airframe - expectedAirframe) < 1e-12)
        #expect(abs(s.damage.engine - (1 - 2 * AircraftDamage.cannonRoundDamage)) < 1e-12)
        #expect(s.damage.controls == 1)
        #expect(s.combat.hitsTaken == 5)
        #expect(abs(s.combat.damageTaken - 5 * AircraftDamage.cannonRoundDamage) < 1e-12)
        #expect(!s.crashed)
        #expect(s.damage.lastSource == .cannon)
    }

    @Test func nonHitHostileEventsDoNoDamage() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sfF1Fighter)
        s.receiveHostileEvents([.missileLaunched(sourceID: "b"), .missileDecoyed(sourceID: "b", decoy: .flare),
                                .missileMissed(sourceID: "b")])
        #expect(s.damage == AircraftDamage())
        #expect(s.combat.hitsTaken == 0)
        let events: [GameEvent] = s.drainEvents()
        #expect(events.count == 3)
        #expect(events.filter { isPlayerDamaged($0) }.isEmpty)
    }

    @Test func flarePressDeploysOneFlare() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sfF1Fighter)
        var press = PilotControls()
        press.countermeasures = CountermeasureInput(flare: true)
        s.step(press)
        s.step(press)                   // held: edge-triggered, so no second flare
        s.step(PilotControls())
        #expect(s.combat.countermeasuresUsed == 1)
        #expect(s.countermeasures.flares == 29)
        #expect(s.countermeasures.chaff == CountermeasureSystem.defaultChaff)
        let events: [GameEvent] = s.drainEvents()
        #expect(events.contains(.countermeasure(.deployed(.flare))))
        #expect(s.hud.flares == 29)
    }

    @Test func radarCycleMovesOffToStandby() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sfF1Fighter)
        #expect(s.radar.mode == .off)
        s.step(PilotControls(radar: RadarInput(cycleMode: true)))
        #expect(s.radar.mode == .standby)
        let events: [GameEvent] = s.drainEvents()
        #expect(events.contains(.radar(.modeChanged(.standby))))
    }

    @Test func hudReflectsCombatState() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sfF1Fighter)
        let fresh: GameplayHUD = s.hud
        #expect(fresh.radarMode == .off && fresh.radarLockText == nil && fresh.contacts.isEmpty)
        #expect(fresh.airframeHealth == 1 && fresh.engineHealth == 1 && fresh.controlsHealth == 1)
        #expect(fresh.flares == CountermeasureSystem.defaultFlares && fresh.chaff == CountermeasureSystem.defaultChaff)
        #expect(fresh.radarMissiles == s.weapons.radarMissilesRemaining)

        s.step(PilotControls(radar: RadarInput(cycleMode: true), countermeasures: CountermeasureInput(flare: true)))
        let h: GameplayHUD = s.hud
        #expect(h.radarMode == .standby)
        #expect(h.flares == 29)
        #expect(h.airframeHealth == 1)
        #expect(h.lockText == nil)              // no targets in a free flight: the heat seeker has nothing to lock

        s.receiveHostileEvents([.missileHit(sourceID: "b")])
        let hit: GameplayHUD = s.hud
        #expect(hit.airframeHealth == 0.5)
    }

    @Test func memberwiseHUDDefaultsKeepOldCallsValid() {
        let h = GameplayHUD(objectiveTitle: nil, objectiveNumber: 0, objectiveCount: 0, objectiveProgress: 0, elapsed: 0,
                            warnings: [], loadFactor: 1, mach: 0, lockText: nil, cannonRounds: 0, missiles: 0, status: nil)
        #expect(h.radarMode == .off && h.contacts.isEmpty && h.radarLockText == nil)
        #expect(h.airframeHealth == 1 && h.engineHealth == 1 && h.controlsHealth == 1)
        #expect(h.flares == 0 && h.chaff == 0 && h.radarMissiles == 0)
    }
}
