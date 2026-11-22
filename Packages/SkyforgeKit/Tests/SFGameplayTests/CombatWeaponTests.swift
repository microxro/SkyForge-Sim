import Testing
import Foundation
import SFMath
@testable import SFGameplay

@Suite struct CombatWeaponTests {
    let own = Ownship(position: SIMD3(0, 0, -3_000), velocity: SIMD3(200, 0, 0), forward: SIMD3(1, 0, 0))
    let dt = 1.0 / 120
    let fighterKinds: [WeaponKind] = [.cannon, .heatMissile, .radarMissile]

    // MARK: Loadout and labels

    @Test func fighterCarriesRadarMissiles() {
        #expect(AircraftCatalog.sfF1Fighter.armament == [.cannon, .heatMissile, .radarMissile])
        #expect(WeaponKind.radarMissile.displayName == "Radar missile")
        #expect(WeaponKind.heatMissile.displayName == "Heat-seeking missile")
        #expect(WeaponKind.cannon.displayName == "Cannon")
        let w = WeaponSystem(kinds: fighterKinds, missiles: 3)
        #expect(w.radarMissilesRemaining == 3 && w.missilesRemaining == 3)
        let gunOnly = WeaponSystem(kinds: [.cannon])
        #expect(gunOnly.radarMissilesRemaining == 0)
    }

    // MARK: Radar missile

    @Test func radarMissileNeedsALockThenKillsTheTarget() {
        var w = WeaponSystem(kinds: fighterKinds)
        var targets = [AITarget(id: "b", role: .hostile, position: SIMD3(10_000, 0, -3_000), heading: .pi, speed: 200)]

        // No radar lock: nothing launches.
        let noLock = w.update(dt: dt, ownship: own, input: WeaponInput(launchRadarMissile: true), targets: &targets)
        #expect(!noLock.contains(.radarMissileLaunched))
        #expect(w.radarMissilesRemaining == 4 && w.missilesInFlight == 0)

        // A lock on an id that is not in the target list does not launch either.
        _ = w.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets)
        let ghost = w.update(dt: dt, ownship: own, input: WeaponInput(launchRadarMissile: true), targets: &targets,
                             radarLockID: "ghost")
        #expect(!ghost.contains(.radarMissileLaunched) && w.missilesInFlight == 0)

        // Release, then press with a lock: one launch.
        _ = w.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets)
        let launch = w.update(dt: dt, ownship: own, input: WeaponInput(launchRadarMissile: true), targets: &targets,
                              radarLockID: "b")
        #expect(launch.contains(.radarMissileLaunched))
        #expect(!launch.contains(.missileLaunched))
        #expect(w.radarMissilesRemaining == 3 && w.missilesRemaining == 4 && w.missilesInFlight == 1)

        // Fly at the target until the missile connects. Holding the button does not fire again.
        var o = own
        var events: [WeaponEvent] = []
        for _ in 0..<(120 * 25) {
            events += w.update(dt: dt, ownship: o, input: WeaponInput(launchRadarMissile: true), targets: &targets,
                               radarLockID: "b")
            targets[0].step(dt: dt)
            o.position += o.velocity * dt
            if targets[0].destroyed { break }
        }
        #expect(w.radarMissilesRemaining == 3, "held input fired again")
        #expect(!events.contains(.radarMissileLaunched))
        #expect(events.contains(.hit(targetID: "b", weapon: .radarMissile)), "events \(events)")
        #expect(targets[0].destroyed)
    }

    @Test func radarMissileStockDropsByOnePerLaunchAndRunsOut() {
        var w = WeaponSystem(kinds: fighterKinds, missiles: 2)
        var targets = [AITarget(id: "b", role: .hostile, position: SIMD3(20_000, 0, -3_000), heading: 0, speed: 0,
                                health: 1_000)]
        var launches = 0
        // Press, release, wait out the cooldown; repeat more times than the stock allows.
        for _ in 0..<4 {
            let pressed = w.update(dt: dt, ownship: own, input: WeaponInput(launchRadarMissile: true), targets: &targets,
                                   radarLockID: "b")
            if pressed.contains(.radarMissileLaunched) { launches += 1 }
            #expect(w.radarMissilesRemaining == 2 - launches)
            for _ in 0..<150 {
                _ = w.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets, radarLockID: "b")
            }
        }
        #expect(launches == 2 && w.radarMissilesRemaining == 0)
    }

    @Test func radarMissileIgnoresFlares() {
        var w = WeaponSystem(kinds: fighterKinds)
        var targets = [AITarget(id: "b", role: .hostile, position: SIMD3(4_000, 0, -3_000), heading: 0, speed: 0)]
        let flare = Decoy(kind: .flare, position: SIMD3(1_000, 0, -3_000), velocity: .zero)
        var events = w.update(dt: dt, ownship: own, input: WeaponInput(launchRadarMissile: true), targets: &targets,
                              radarLockID: "b", decoys: [flare])
        for _ in 0..<(120 * 15) {
            events += w.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets,
                               radarLockID: "b", decoys: [flare])
            if targets[0].destroyed { break }
        }
        let anyDecoyed: Bool = events.contains { (e: WeaponEvent) -> Bool in
            if case .decoyed = e { return true } else { return false }
        }
        #expect(events.contains(.radarMissileLaunched))
        #expect(!anyDecoyed)
        #expect(targets[0].destroyed, "events \(events)")
    }

    @Test func chaffOnTheLineOfSightCanOnlyDecoyARadarMissileOnce() {
        var decoyedRuns = 0
        for seed in UInt64(1)...UInt64(16) {
            var w = WeaponSystem(kinds: fighterKinds, seed: seed)
            var targets = [AITarget(id: "b", role: .hostile, position: SIMD3(4_000, 0, -3_000), heading: 0, speed: 0)]
            let chaff = Decoy(kind: .chaff, position: SIMD3(1_000, 0, -3_000), velocity: .zero)
            var events = w.update(dt: dt, ownship: own, input: WeaponInput(launchRadarMissile: true), targets: &targets,
                                  radarLockID: "b", decoys: [chaff])
            for _ in 0..<(120 * 15) {
                events += w.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets,
                                   radarLockID: "b", decoys: [chaff])
                if targets[0].destroyed || w.missilesInFlight == 0 { break }
            }
            let decoyed: [WeaponEvent] = events.filter { (e: WeaponEvent) -> Bool in
                if case .decoyed = e { return true } else { return false }
            }
            let allChaff: Bool = decoyed.allSatisfy { $0 == .decoyed(weapon: .radarMissile, decoy: .chaff) }
            #expect(decoyed.count <= 1)
            #expect(allChaff)
            if decoyed.isEmpty {
                // The roll failed: the missile kept guiding and connected.
                #expect(targets[0].destroyed, "seed \(seed) events \(events)")
            } else {
                decoyedRuns += 1
                #expect(!targets[0].destroyed && w.missilesInFlight == 0)
            }
        }
        // 75 % capture: across 16 seeds at least one is decoyed (and the outcome is deterministic per seed).
        #expect(decoyedRuns > 0)
    }

    // MARK: Heat missile and flares

    @Test func heatMissileIsDecoyedByAFlareInItsCone() {
        var w = WeaponSystem(kinds: fighterKinds)
        var targets = [AITarget(id: "b", role: .hostile, position: SIMD3(4_000, 0, -3_000), heading: 0, speed: 0)]
        for _ in 0..<240 { _ = w.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets) }
        #expect(w.lock == .locked(targetID: "b"))

        let launch = w.update(dt: dt, ownship: own, input: WeaponInput(launchMissile: true), targets: &targets)
        #expect(launch.contains(.missileLaunched) && w.missilesInFlight == 1)

        // The only decoy is a flare between the missile and the target, on the seeker's axis. Each step
        // draws a fresh roll, and the flare stays in the cone for hundreds of steps, so a capture is certain.
        let flare = Decoy(kind: .flare, position: SIMD3(1_000, 0, -3_000), velocity: .zero)
        var events: [WeaponEvent] = []
        for _ in 0..<(120 * 5) {
            events += w.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets, decoys: [flare])
            if w.missilesInFlight == 0 { break }
        }
        let decoyed = events.filter { $0 == .decoyed(weapon: .heatMissile, decoy: .flare) }
        #expect(decoyed.count == 1, "events \(events)")
        #expect(w.missilesInFlight == 0 && w.missilesRemaining == 3)
        #expect(!targets[0].destroyed)
        #expect(!events.contains(.missileMissed))
    }

    // MARK: Determinism

    @Test func gunSequenceIsUnchangedByTheNewAPI() {
        func burst(newAPI: Bool, kinds: [WeaponKind], decoys: [Decoy]) -> (health: Double, rounds: Int, events: [WeaponEvent]) {
            var w = WeaponSystem(kinds: kinds, seed: 42)
            var t = [AITarget(id: "d", role: .hostile, position: SIMD3(900, 0, -3_000), heading: 0, speed: 0, health: 1_000)]
            var events: [WeaponEvent] = []
            for _ in 0..<240 {
                if newAPI {
                    events += w.update(dt: dt, ownship: own, input: WeaponInput(fireGun: true), targets: &t,
                                       radarLockID: nil, decoys: decoys)
                } else {
                    events += w.update(dt: dt, ownship: own, input: WeaponInput(fireGun: true), targets: &t)
                }
            }
            return (health: t[0].health, rounds: w.cannonRounds, events: events)
        }
        let a = burst(newAPI: false, kinds: [.cannon], decoys: [])
        let b = burst(newAPI: false, kinds: [.cannon], decoys: [])
        let c = burst(newAPI: true, kinds: [.cannon], decoys: [])
        #expect(a.health == b.health && a.rounds == b.rounds && a.events == b.events)
        #expect(a.health == c.health && a.rounds == c.rounds && a.events == c.events)
        #expect(a.health < 1_000)
        // Arming radar missiles and passing decoys does not disturb the gun's dispersion sequence.
        let flare = Decoy(kind: .flare, position: SIMD3(500, 0, -3_000), velocity: .zero)
        let d = burst(newAPI: true, kinds: [.cannon, .heatMissile, .radarMissile], decoys: [flare])
        #expect(a.health == d.health && a.rounds == d.rounds)
    }

    // MARK: Dogfight AI

    @Test func dogfightTargetTurnsTowardTheThreat() {
        var t = AITarget(id: "b", role: .hostile, position: .zero, heading: 0, speed: 180,
                         behavior: .dogfight(DogfightSettings()))
        for _ in 0..<120 { t.step(dt: dt, threat: SIMD3(0, 5_000, 0), threatVelocity: .zero) }
        #expect(t.heading > 0.15 && t.heading < .pi / 2, "heading \(t.heading)")
        #expect(t.position.y > 0)

        // Without a threat it holds course.
        var hold = AITarget(id: "h", role: .hostile, position: .zero, heading: 0.3, speed: 180,
                            behavior: .dogfight(DogfightSettings()))
        for _ in 0..<120 { hold.step(dt: dt) }
        #expect(abs(hold.heading - 0.3) < 1e-12 && hold.flightPath == 0)
        #expect(hold.position.x > 100)
    }

    /// Runs HostileWeapons against a stationary player at the origin, stepping the shooters.
    private func fight(_ start: [AITarget], seconds: Double, decoys: [Decoy] = [], stepTargets: Bool = true)
        -> (events: [HostileWeaponEvent], weapons: HostileWeapons) {
        let player = Ownship(position: .zero, velocity: .zero, forward: SIMD3(1, 0, 0))
        var hostile = HostileWeapons()
        var targets = start
        var events: [HostileWeaponEvent] = []
        let steps = Int(seconds * 120)
        for _ in 0..<steps {
            events += hostile.update(dt: dt, targets: targets, player: player, decoys: decoys)
            if stepTargets {
                for i in targets.indices {
                    targets[i].step(dt: dt, threat: player.position, threatVelocity: player.velocity)
                }
            }
        }
        return (events: events, weapons: hostile)
    }

    @Test func hostileDogfighterInTheNoseHitsThePlayerWithItsCannon() {
        let bandit = AITarget(id: "bandit", role: .hostile, position: SIMD3(800, 0, 0), heading: .pi, speed: 180,
                              behavior: .dogfight(DogfightSettings()))
        let result = fight([bandit], seconds: 3)
        #expect(result.events.contains(.cannonHit(sourceID: "bandit")), "events \(result.events)")
        #expect(result.events.contains(.missileLaunched(sourceID: "bandit")))
        // One burst in 3 s (4 s cooldown): at most burstDuration x rate rounds can hit.
        let hits = result.events.filter { $0 == .cannonHit(sourceID: "bandit") }.count
        let maxRounds = Int((HostileWeapons.burstDuration * HostileWeapons.burstRoundsPerSecond).rounded()) + 1
        #expect(hits <= maxRounds)
    }

    @Test func friendlyNeutralAndNonDogfightTargetsNeverFire() {
        let friendly = AITarget(id: "f", role: .friendly, position: SIMD3(800, 0, 0), heading: .pi, speed: 180,
                                behavior: .dogfight(DogfightSettings()))
        let neutral = AITarget(id: "n", role: .neutral, position: SIMD3(800, 50, 0), heading: .pi, speed: 180,
                               behavior: .dogfight(DogfightSettings()))
        let straight = AITarget(id: "s", role: .hostile, position: SIMD3(800, -50, 0), heading: .pi, speed: 180)
        let result = fight([friendly, neutral, straight], seconds: 3)
        #expect(result.events.isEmpty, "events \(result.events)")
        #expect(result.weapons.activeRounds == 0 && result.weapons.missilesInFlight == 0)
    }

    @Test func destroyedShooterNeverFires() {
        let wreck = AITarget(id: "w", role: .hostile, position: SIMD3(800, 0, 0), heading: .pi, speed: 180,
                             behavior: .dogfight(DogfightSettings()), health: 0)
        let result = fight([wreck], seconds: 3)
        #expect(result.events.isEmpty)
        #expect(result.weapons.activeRounds == 0 && result.weapons.missilesInFlight == 0)
    }

    @Test func hostileMissilesAreLimitedByStockAndCooldown() {
        // 3 km out: inside missile range, outside gun range. The shooter is held still.
        let shooter = AITarget(id: "m", role: .hostile, position: SIMD3(3_000, 0, 0), heading: .pi, speed: 180,
                               behavior: .dogfight(DogfightSettings()))
        let result = fight([shooter], seconds: 40, stepTargets: false)
        let launches = result.events.filter { $0 == .missileLaunched(sourceID: "m") }.count
        let hits = result.events.filter { $0 == .missileHit(sourceID: "m") }.count
        #expect(launches == HostileWeapons.missileStock, "events \(result.events)")
        #expect(hits == launches)
        #expect(!result.events.contains(.cannonHit(sourceID: "m")))
        #expect(result.weapons.missilesRemaining(for: "m") == 0)
    }

    @Test func hostileMissileIsDecoyedByAFlare() {
        let shooter = AITarget(id: "m", role: .hostile, position: SIMD3(3_000, 0, 0), heading: .pi, speed: 180,
                               behavior: .dogfight(DogfightSettings()))
        let flare = Decoy(kind: .flare, position: SIMD3(300, 0, 0), velocity: .zero)
        let result = fight([shooter], seconds: 10, decoys: [flare], stepTargets: false)
        #expect(result.events.contains(.missileLaunched(sourceID: "m")))
        #expect(result.events.contains(.missileDecoyed(sourceID: "m", decoy: .flare)), "events \(result.events)")
        #expect(!result.events.contains(.missileHit(sourceID: "m")))
    }
}
