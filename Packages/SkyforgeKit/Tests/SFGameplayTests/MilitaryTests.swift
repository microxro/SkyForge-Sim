import Testing
import Foundation
import SFMath
@testable import SFGameplay

@Suite struct MilitaryTests {
    let own = Ownship(position: SIMD3(0, 0, -3_000), velocity: SIMD3(200, 0, 0), forward: SIMD3(1, 0, 0))
    let dt = 1.0 / 120

    @Test func aiAircraftFlyTheirBehaviours() {
        var straight = AITarget(id: "s", role: .hostile, position: .zero, heading: .pi / 2, speed: 100)
        for _ in 0..<120 { straight.step(dt: dt) }
        #expect(abs(straight.position.y - 100) < 1e-6 && abs(straight.position.x) < 1e-6)

        var route = AITarget(id: "r", role: .friendly, position: .zero, heading: 0, speed: 100,
                             behavior: .route(points: [SIMD3(0, 2_000, 0), SIMD3(2_000, 2_000, 0)], loop: false))
        for _ in 0..<(120 * 60) { route.step(dt: dt) }
        #expect(route.routeIndex == 1 && route.position.x > 1_000, "\(route.position) idx \(route.routeIndex)")

        // An evader 2 km in front of the threat turns off its heading; one 20 km away does not.
        var near = AITarget(id: "e", role: .hostile, position: SIMD3(2_000, 0, -3_000), heading: 0, speed: 150, behavior: .evade(maxTurnRate: 0.14))
        var far = AITarget(id: "f", role: .hostile, position: SIMD3(20_000, 0, -3_000), heading: 0, speed: 150, behavior: .evade(maxTurnRate: 0.14))
        for _ in 0..<240 { near.step(dt: dt, threat: SIMD3(0, 0, -3_000)); far.step(dt: dt, threat: SIMD3(0, 0, -3_000)) }
        #expect(abs(near.heading) > 0.1 && far.heading == 0)
    }

    @Test func cannonDestroysAStationaryDrone() {
        var weapons = WeaponSystem(kinds: [.cannon])
        var targets = [AITarget(id: "d", role: .hostile, position: SIMD3(600, 0, -3_000), heading: 0, speed: 0, health: 6)]
        var events: [WeaponEvent] = []
        for _ in 0..<(120 * 3) {
            events += weapons.update(dt: dt, ownship: own, input: WeaponInput(fireGun: true), targets: &targets)
        }
        #expect(targets[0].destroyed)
        #expect(events.contains(.destroyed(targetID: "d", weapon: .cannon)))
        #expect(weapons.cannonRounds < 500)
    }

    @Test func noAmmoNoFire() {
        var weapons = WeaponSystem(kinds: [.cannon], cannonRounds: 0)
        var targets = [AITarget(id: "d", role: .hostile, position: SIMD3(300, 0, -3_000), heading: 0, speed: 0)]
        for _ in 0..<240 { _ = weapons.update(dt: dt, ownship: own, input: WeaponInput(fireGun: true), targets: &targets) }
        #expect(!targets[0].destroyed && weapons.activeProjectiles == 0)
    }

    @Test func missileNeedsLockThenKillsCrossingTarget() {
        var weapons = WeaponSystem(kinds: [.cannon, .heatMissile])
        var targets = [AITarget(id: "b", role: .hostile, position: SIMD3(4_000, 300, -3_000), heading: .pi / 2, speed: 150)]
        // Pressing launch before the seeker has locked does nothing.
        _ = weapons.update(dt: dt, ownship: own, input: WeaponInput(launchMissile: true), targets: &targets)
        #expect(weapons.missilesRemaining == 4)
        var events: [WeaponEvent] = []
        for _ in 0..<(120 * 2) {
            events += weapons.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets)
            targets[0].step(dt: dt)
        }
        #expect(weapons.lock == .locked(targetID: "b") && events.contains(.lockAcquired(targetID: "b")))
        var launched = false
        var o = own
        for _ in 0..<(120 * 30) {
            events += weapons.update(dt: dt, ownship: o, input: WeaponInput(launchMissile: !launched), targets: &targets)
            launched = true
            targets[0].step(dt: dt)
            o.position += o.velocity * dt
            if targets[0].destroyed { break }
        }
        #expect(events.contains(.missileLaunched) && weapons.missilesRemaining == 3)
        #expect(targets[0].destroyed, "missile missed; events \(events)")
    }

    @Test func seekerIgnoresTargetsOutsideTheCone() {
        var weapons = WeaponSystem(kinds: [.heatMissile])
        var targets = [AITarget(id: "side", role: .hostile, position: SIMD3(0, 3_000, -3_000), heading: 0, speed: 100)]
        for _ in 0..<(120 * 4) { _ = weapons.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets) }
        #expect(weapons.lock == .none)
        // Friendly aircraft are never selected.
        var friendly = [AITarget(id: "wing", role: .friendly, position: SIMD3(1_000, 0, -3_000), heading: 0, speed: 100)]
        _ = weapons.update(dt: dt, ownship: own, input: WeaponInput(), targets: &friendly)
        #expect(weapons.selectedTarget == nil && weapons.lock == .none)
    }

    @Test func targetCycleChoosesNearestFirstThenNext() {
        var weapons = WeaponSystem(kinds: [.heatMissile])
        var targets = [AITarget(id: "far", role: .hostile, position: SIMD3(6_000, 0, -3_000), heading: 0, speed: 0),
                       AITarget(id: "near", role: .hostile, position: SIMD3(2_000, 500, -3_000), heading: 0, speed: 0)]
        _ = weapons.update(dt: dt, ownship: own, input: WeaponInput(cycleTarget: true), targets: &targets)
        #expect(weapons.selectedTarget == "near")
        _ = weapons.update(dt: dt, ownship: own, input: WeaponInput(cycleTarget: true), targets: &targets)   // held: no second cycle
        #expect(weapons.selectedTarget == "near")
        _ = weapons.update(dt: dt, ownship: own, input: WeaponInput(), targets: &targets)
        _ = weapons.update(dt: dt, ownship: own, input: WeaponInput(cycleTarget: true), targets: &targets)
        #expect(weapons.selectedTarget == "far")
    }

    @Test func weaponsAreDeterministic() {
        func run() -> Int {
            var w = WeaponSystem(kinds: [.cannon], seed: 42)
            var t = [AITarget(id: "d", role: .hostile, position: SIMD3(900, 0, -3_000), heading: 0, speed: 0, health: 1_000)]
            for _ in 0..<240 { _ = w.update(dt: dt, ownship: own, input: WeaponInput(fireGun: true), targets: &t) }
            return Int(t[0].health)
        }
        #expect(run() == run())
    }

    @Test func formationSlotsMirrorAndRotate() {
        let right = FormationSlot.echelonRight.offset(spacing: 50), left = FormationSlot.echelonLeft.offset(spacing: 50)
        #expect(right.x == left.x && right.y == -left.y && right.x < 0)
        // Leader heading east: behind is west, right is south.
        let p = FormationGeometry.slotPosition(leaderPosition: .zero, heading: .pi / 2, slot: .echelonRight, spacing: 50)
        #expect(abs(p.x + 50) < 1e-9 && abs(p.y + 50) < 1e-9)
    }
}
