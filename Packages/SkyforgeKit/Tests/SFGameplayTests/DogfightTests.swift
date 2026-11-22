import Testing
import Foundation
@testable import SFGameplay

@Suite struct DogfightTests {
    let settings = DogfightSettings()
    let dt = 0.05

    func fighter(_ position: SIMD3<Double> = SIMD3(0, 0, -3_000), heading: Double = 0, speed: Double = 180) -> AITarget {
        AITarget(id: "bandit", role: .hostile, position: position, heading: heading, speed: speed)
    }

    func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * Double.pi)
        if x > Double.pi { x -= 2 * Double.pi }
        if x < -Double.pi { x += 2 * Double.pi }
        return x
    }

    func norm(_ v: SIMD3<Double>) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }

    /// Angle between the fighter's nose and the line of sight to `p`.
    func offNose(_ f: AITarget, _ p: SIMD3<Double>) -> Double {
        let c = cos(f.flightPath)
        let nose = SIMD3<Double>(cos(f.heading) * c, sin(f.heading) * c, -sin(f.flightPath))
        let d = p - f.position
        let n = norm(d)
        guard n > 1e-9 else { return 0 }
        return acos(max(-1, min(1, (d.x * nose.x + d.y * nose.y + d.z * nose.z) / n)))
    }

    func isFinite(_ c: DogfightCommand) -> Bool {
        c.heading.isFinite && c.flightPath.isFinite && c.speed.isFinite
    }

    // MARK: Lead point

    @Test func leadPointOfAStationaryTargetIsTheTarget() {
        let t = SIMD3<Double>(2_000, 500, -3_000)
        #expect(Dogfight.leadPoint(shooterPosition: SIMD3(0, 0, -3_000), shooterSpeed: 300, target: t, targetVelocity: .zero) == t)
    }

    @Test func leadPointLiesAheadOfAMovingTarget() {
        let t = SIMD3<Double>(2_000, 0, 0), v = SIMD3<Double>(0, 100, 0)
        let p = Dogfight.leadPoint(shooterPosition: .zero, shooterSpeed: 300, target: t, targetVelocity: v)
        // Ahead along the velocity, and nowhere else.
        #expect(p.y > 0 && abs(p.x - 2_000) < 1e-9 && abs(p.z) < 1e-9, "\(p)")
        // The shot and the target arrive together: |p| = s t, with t = p.y / 100 (about 7.07 s).
        let time = p.y / 100
        #expect(abs(norm(p) - 300 * time) < 1e-6 && abs(time - 2_000 / (80_000.0).squareRoot()) < 1e-9)
    }

    @Test func leadPointWithoutASpeedOrSolutionIsTheTarget() {
        let t = SIMD3<Double>(1_000, 0, 0), v = SIMD3<Double>(0, 150, 0)
        #expect(Dogfight.leadPoint(shooterPosition: .zero, shooterSpeed: 0, target: t, targetVelocity: v) == t)
        #expect(Dogfight.leadPoint(shooterPosition: .zero, shooterSpeed: -10, target: t, targetVelocity: v) == t)
        #expect(Dogfight.leadPoint(shooterPosition: .zero, shooterSpeed: .nan, target: t, targetVelocity: v) == t)
        // A target running away faster than the shot cannot be caught.
        #expect(Dogfight.leadPoint(shooterPosition: .zero, shooterSpeed: 100, target: t, targetVelocity: SIMD3(200, 0, 0)) == t)
        // Zero distance: already there.
        #expect(Dogfight.leadPoint(shooterPosition: t, shooterSpeed: 300, target: t, targetVelocity: v) == t)
    }

    // MARK: Steering

    @Test func turnsTowardATargetAheadAndRightAtTheTurnRateLimit() {
        let own = fighter()
        let target = SIMD3<Double>(2_000, 1_000, -3_000)    // bearing atan2(1000, 2000), about 0.46 rad
        let c = Dogfight.steer(own: own, target: target, targetVelocity: .zero, settings: settings, dt: dt)
        #expect(c.heading > 0, "turned the wrong way: \(c.heading)")
        #expect(c.heading <= settings.maxTurnRate * dt + 1e-12)
        #expect(abs(c.heading - settings.maxTurnRate * dt) < 1e-12)  // far from the bearing: full rate
        #expect(abs(c.flightPath) < 1e-12)                           // level target: no climb
    }

    @Test func climbsTowardATargetDirectlyAboveAtTheClimbRateLimit() {
        let own = fighter(heading: 0.3)
        let above = Dogfight.steer(own: own, target: SIMD3(0, 0, -5_000), targetVelocity: .zero, settings: settings, dt: dt)
        #expect(above.flightPath > 0)
        #expect(abs(above.flightPath - settings.maxClimbRate * dt) < 1e-12)
        #expect(abs(above.heading - 0.3) < 1e-12)                    // no horizontal offset: keep the heading
        let below = Dogfight.steer(own: own, target: SIMD3(0, 0, -1_000), targetVelocity: .zero, settings: settings, dt: dt)
        #expect(abs(below.flightPath + settings.maxClimbRate * dt) < 1e-12)
        // A huge step still never commands past the steepest flight path.
        let big = Dogfight.steer(own: own, target: SIMD3(0, 0, -5_000), targetVelocity: .zero, settings: settings, dt: 100)
        #expect(abs(big.flightPath - Dogfight.maxFlightPathAngle) < 1e-12)
    }

    /// Worked by hand: the target is 5 km abeam (bearing pi/2), so the fighter starts in lead and turns at
    /// 0.2 rad/s on a 900 m radius. It points at the target after about 9 s (about 1.79 rad, since it drifts
    /// 900 m north while turning), then flies straight in. At 20 s it is still about 2 km short, in attack,
    /// with the target dead ahead, so the error is near zero, well inside 0.1 rad. No overshoot is possible.
    @Test func repeatedStepsConvergeOnAStationaryTarget() {
        var f = fighter()
        let target = SIMD3<Double>(0, 5_000, -3_000)
        var phases: Set<DogfightPhase> = []
        for _ in 0..<400 {
            let c = Dogfight.steer(own: f, target: target, targetVelocity: .zero, settings: settings, dt: dt)
            phases.insert(c.phase)
            f.heading = c.heading; f.flightPath = c.flightPath; f.speed = c.speed
            f.position += f.velocity * dt
        }
        let bearing = atan2(target.y - f.position.y, target.x - f.position.x)
        #expect(abs(wrap(bearing - f.heading)) < 0.1, "heading \(f.heading) bearing \(bearing)")
        #expect(norm(target - f.position) < 3_000 && norm(target - f.position) > 1_500, "\(f.position)")
        #expect(!phases.contains(.overshoot) && phases.contains(.lead) && phases.contains(.attack))
    }

    @Test func phaseFollowsTheGeometry() {
        let own = fighter()
        let behind = Dogfight.steer(own: own, target: SIMD3(-1_000, 0, -3_000), targetVelocity: SIMD3(180, 0, 0),
                                    settings: settings, dt: dt)
        #expect(behind.phase == .overshoot && abs(behind.speed - 1.25 * settings.cruiseSpeed) < 1e-9)
        // The reversal is a hard turn: the full turn-rate limit.
        #expect(abs(abs(behind.heading) - settings.maxTurnRate * dt) < 1e-12)
        // Behind and to the right: it reverses to the right, toward the target's side.
        let behindRight = Dogfight.steer(own: own, target: SIMD3(-700, 700, -3_000), targetVelocity: SIMD3(180, 0, 0),
                                         settings: settings, dt: dt)
        #expect(behindRight.phase == .overshoot && behindRight.heading > 0)

        let ahead = Dogfight.steer(own: own, target: SIMD3(2_000, 0, -3_000), targetVelocity: .zero, settings: settings, dt: dt)
        #expect(ahead.phase == .attack && ahead.speed == settings.cruiseSpeed)
        // Far and off the nose: lead. Far behind is not an overshoot.
        let abeam = Dogfight.steer(own: own, target: SIMD3(0, 10_000, -3_000), targetVelocity: .zero, settings: settings, dt: dt)
        #expect(abeam.phase == .lead && abeam.speed == settings.cruiseSpeed)
        let farBehind = Dogfight.steer(own: own, target: SIMD3(-5_000, 0, -3_000), targetVelocity: .zero, settings: settings, dt: dt)
        #expect(farBehind.phase == .lead)
        // Far but on the nose: attack.
        let farAhead = Dogfight.steer(own: own, target: SIMD3(10_000, 1_000, -3_000), targetVelocity: .zero, settings: settings, dt: dt)
        #expect(farAhead.phase == .attack)
    }

    /// A head-on pass: the fighter merges, overshoots, reverses through the tail and ends up behind the
    /// target with it on the nose, never turning faster than its limit.
    @Test func headOnMergeOvershootsThenRecovers() {
        var f = fighter()
        var bogey = AITarget(id: "player", role: .friendly, position: SIMD3(3_000, 0, -3_000), heading: .pi, speed: 180)
        var phases: [DogfightPhase] = []
        for _ in 0..<(20 * 90) {
            let c = Dogfight.steer(own: f, target: bogey.position, targetVelocity: bogey.velocity, settings: settings, dt: dt)
            #expect(abs(wrap(c.heading - f.heading)) <= settings.maxTurnRate * dt + 1e-12)
            if phases.last != c.phase { phases.append(c.phase) }
            f.heading = c.heading; f.flightPath = c.flightPath; f.speed = c.speed
            f.position += f.velocity * dt
            bogey.step(dt: dt)
        }
        #expect(phases.first == .attack && phases.contains(.overshoot), "\(phases)")
        #expect(offNose(f, bogey.position) < 60.0 * Double.pi / 180, "\(phases) off \(offNose(f, bogey.position))")
    }

    @Test func steeringIsDeterministic() {
        let own = fighter(SIMD3(100, -200, -2_500), heading: 1.0)
        let a = Dogfight.steer(own: own, target: SIMD3(800, 900, -2_900), targetVelocity: SIMD3(-50, 120, 3), settings: settings, dt: dt)
        let b = Dogfight.steer(own: own, target: SIMD3(800, 900, -2_900), targetVelocity: SIMD3(-50, 120, 3), settings: settings, dt: dt)
        #expect(a == b)
    }

    // MARK: Firing solutions

    @Test func gunSolutionNeedsRangeAndNose() {
        let own = fighter()
        #expect(Dogfight.gunSolution(own: own, target: SIMD3(500, 0, -3_000), targetVelocity: .zero, settings: settings))
        // A target flying the same way stays dead ahead at the lead point.
        #expect(Dogfight.gunSolution(own: own, target: SIMD3(500, 0, -3_000), targetVelocity: SIMD3(150, 0, 0), settings: settings))
        #expect(!Dogfight.gunSolution(own: own, target: SIMD3(2_000, 0, -3_000), targetVelocity: .zero, settings: settings))
        // In range but about 31 degrees off the nose.
        #expect(!Dogfight.gunSolution(own: own, target: SIMD3(500, 300, -3_000), targetVelocity: .zero, settings: settings))
        // A crossing target 500 m ahead needs lead: about 7 degrees at 1180 m/s round speed, outside 5.
        #expect(!Dogfight.gunSolution(own: own, target: SIMD3(500, 0, -3_000), targetVelocity: SIMD3(0, 150, 0), settings: settings))
        var dead = own
        dead.health = 0
        #expect(!Dogfight.gunSolution(own: dead, target: SIMD3(500, 0, -3_000), targetVelocity: .zero, settings: settings))
    }

    @Test func missileSolutionNeedsRangeAndCone() {
        let own = fighter()
        #expect(Dogfight.missileSolution(own: own, target: SIMD3(4_000, 0, -3_000), targetVelocity: .zero, settings: settings))
        #expect(!Dogfight.missileSolution(own: own, target: SIMD3(8_000, 0, -3_000), targetVelocity: .zero, settings: settings))
        #expect(!Dogfight.missileSolution(own: own, target: SIMD3(0, 4_000, -3_000), targetVelocity: .zero, settings: settings))
    }

    // MARK: Robustness

    @Test func badInputsGiveFiniteCommands() {
        let nan = Double.nan, inf = Double.infinity
        let targets: [SIMD3<Double>] = [SIMD3(nan, nan, nan), SIMD3(inf, 0, -3_000), SIMD3(-inf, inf, -inf),
                                        SIMD3(0, 0, -3_000), SIMD3(1e308, -1e308, 1e308), SIMD3(2_000, 0, -3_000)]
        let velocities: [SIMD3<Double>] = [.zero, SIMD3(nan, 0, 0), SIMD3(inf, inf, 0)]
        let steps: [Double] = [0, 1e-9, dt, 100, -1, nan, inf]
        var owns = [fighter(), fighter(speed: 0)]
        var broken = fighter(heading: nan)
        broken.flightPath = inf
        broken.speed = nan
        owns.append(broken)
        for own in owns {
            for t in targets {
                for v in velocities {
                    for step in steps {
                        let c = Dogfight.steer(own: own, target: t, targetVelocity: v, settings: settings, dt: step)
                        #expect(isFinite(c), "own \(own.heading) target \(t) v \(v) dt \(step): \(c)")
                        #expect(c.heading >= -Double.pi && c.heading <= Double.pi)
                        #expect(abs(c.flightPath) <= Double.pi / 2)
                    }
                    _ = Dogfight.gunSolution(own: own, target: t, targetVelocity: v, settings: settings)
                    #expect(!Dogfight.missileSolution(own: own, target: SIMD3(nan, 0, 0), targetVelocity: v, settings: settings))
                }
            }
        }
        // Zero dt changes nothing; a tiny dt moves a tiny, bounded amount toward the target.
        let own = fighter(heading: 0.4)
        let zero = Dogfight.steer(own: own, target: SIMD3(0, 3_000, -2_000), targetVelocity: .zero, settings: settings, dt: 0)
        #expect(zero.heading == 0.4 && zero.flightPath == 0)
        let tiny = Dogfight.steer(own: own, target: SIMD3(0, 3_000, -2_000), targetVelocity: .zero, settings: settings, dt: 1e-6)
        #expect(tiny.heading > 0.4 && tiny.heading - 0.4 <= settings.maxTurnRate * 1e-6 + 1e-15)
        // Bad settings fall back to no turn and no speed rather than NaN.
        let badSettings = DogfightSettings(maxTurnRate: nan, maxClimbRate: -1, cruiseSpeed: inf)
        let c = Dogfight.steer(own: own, target: SIMD3(2_000, 2_000, -2_000), targetVelocity: .zero, settings: badSettings, dt: dt)
        #expect(isFinite(c) && c.heading == 0.4 && c.flightPath == 0 && c.speed == 0)
    }

    @Test func headingNeverJumpsMoreThanPiOrTheTurnLimit() {
        let headings: [Double] = [-Double.pi, -3, -1.5, 0, 1.5, 3, Double.pi, 7, -9]
        let offsets: [SIMD3<Double>] = [SIMD3(2_000, 0, 0), SIMD3(-2_000, 0, 0), SIMD3(0, 2_000, 0), SIMD3(0, -2_000, 0),
                                        SIMD3(-800, 1, 0), SIMD3(-800, -1, 0), SIMD3(-20_000, 0, 0), SIMD3(0, 0, -2_000)]
        for h in headings {
            for o in offsets {
                for step in [0.0, 1e-6, 0.05, 1, 100] {
                    let own = fighter(heading: h)
                    let c = Dogfight.steer(own: own, target: own.position + o, targetVelocity: SIMD3(0, 120, 0),
                                           settings: settings, dt: step)
                    let change = abs(wrap(c.heading - wrap(h)))
                    #expect(change <= Double.pi + 1e-12, "h \(h) offset \(o) dt \(step)")
                    #expect(change <= settings.maxTurnRate * step + 1e-12, "h \(h) offset \(o) dt \(step)")
                }
            }
        }
    }
}
