import Testing
import Foundation
import SFMath
@testable import SFGameplay

@Suite struct CountermeasuresTests {
    let own = Ownship(position: SIMD3(0, 0, -3_000), velocity: SIMD3(200, 0, 0), forward: SIMD3(1, 0, 0))
    let dt = 1.0 / 120

    private func flare(at p: SIMD3<Double>) -> Decoy { Decoy(kind: .flare, position: p, velocity: .zero) }
    private func chaffCloud(at p: SIMD3<Double>) -> Decoy { Decoy(kind: .chaff, position: p, velocity: .zero) }

    @Test func pressReleasesAFlare() {
        var cm = CountermeasureSystem()
        let events = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true))
        #expect(cm.flares == CountermeasureSystem.defaultFlares - 1)
        #expect(cm.decoys.count == 1 && cm.decoys[0].kind == .flare)
        #expect(events == [.deployed(.flare)])
        // Starts behind the aircraft and at half its speed.
        #expect(cm.decoys[0].position.x < own.position.x)
        #expect(abs(cm.decoys[0].velocity.x - 100) < 1.0)
    }

    @Test func holdingReleasesOnlyOnce() {
        var cm = CountermeasureSystem()
        var deployed = 0
        for _ in 0..<60 {
            let ev = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true, chaff: true))
            deployed += ev.count
        }
        #expect(deployed == 2)
        #expect(cm.flares == CountermeasureSystem.defaultFlares - 1)
        #expect(cm.chaff == CountermeasureSystem.defaultChaff - 1)
        // Release and press again: a second edge.
        _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput())
        _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true))
        #expect(cm.flares == CountermeasureSystem.defaultFlares - 2)
    }

    @Test func zeroStockEmitsExhausted() {
        var cm = CountermeasureSystem(flares: 0, chaff: 0)
        let a = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true))
        #expect(a == [.exhausted(.flare)])
        let b = cm.update(dt: dt, ownship: own, input: CountermeasureInput(chaff: true))
        #expect(b == [.exhausted(.chaff)])
        #expect(cm.flares == 0 && cm.chaff == 0 && cm.decoys.isEmpty)
    }

    @Test func lastFlareThenExhausted() {
        var cm = CountermeasureSystem(flares: 1, chaff: 0)
        let firstEvents = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true))
        #expect(firstEvents == [.deployed(.flare)])
        _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput())
        let secondEvents = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true))
        #expect(secondEvents == [.exhausted(.flare)])
        #expect(cm.flares == 0 && cm.decoys.count == 1)
    }

    @Test func flareFallsUnderGravity() {
        var cm = CountermeasureSystem()
        _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true))
        let start = cm.decoys[0]
        for _ in 0..<120 { _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true)) }
        let end = cm.decoys[0]
        #expect(end.velocity.z > start.velocity.z)
        #expect(end.position.z > start.position.z)
    }

    @Test func decoysExpire() {
        var cm = CountermeasureSystem()
        _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true, chaff: true))
        #expect(cm.decoys.count == 2)
        _ = cm.update(dt: 3.0, ownship: own, input: CountermeasureInput())
        #expect(cm.decoys.count == 2)
        _ = cm.update(dt: 1.5, ownship: own, input: CountermeasureInput())   // 4.5 s: flare gone
        #expect(cm.decoys.count == 1 && cm.decoys[0].kind == .chaff)
        _ = cm.update(dt: 2.0, ownship: own, input: CountermeasureInput())   // 6.5 s: chaff gone
        #expect(cm.decoys.isEmpty)
        #expect(Decoy(kind: .flare, position: .zero, velocity: .zero).life == 4)
        #expect(Decoy(kind: .chaff, position: .zero, velocity: .zero).life == 6)
        #expect(Decoy(kind: .chaff, position: .zero, velocity: .zero, age: 6).expired)
    }

    @Test func chaffCloudsOnlyReturnsChaff() {
        var cm = CountermeasureSystem()
        _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true, chaff: true))
        let clouds = cm.chaffClouds
        #expect(clouds.count == 1)
        #expect(clouds[0] == cm.decoys.first(where: { $0.kind == .chaff })!.position)
    }

    @Test func badDtDoesNotCrashOrAge() {
        var cm = CountermeasureSystem()
        _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: true))
        let before = cm.decoys
        _ = cm.update(dt: .nan, ownship: own, input: CountermeasureInput(flare: true))
        _ = cm.update(dt: -1, ownship: own, input: CountermeasureInput(flare: true))
        _ = cm.update(dt: .infinity, ownship: own, input: CountermeasureInput(flare: true))
        #expect(cm.decoys == before)
    }

    // MARK: flare capture

    let seeker = SIMD3<Double>(0, 0, -3_000)
    let fwd = SIMD3<Double>(1, 0, 0)
    let target = SIMD3<Double>(3_000, 0, -3_000)
    let half = 0.3

    @Test func flareAheadCapturesOnLowRoll() {
        let ds = [flare(at: SIMD3(1_000, 0, -3_000))]
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: ds, roll: 0.1, seekerHalfAngle: half) == 0)
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: ds, roll: 0.9, seekerHalfAngle: half) == nil)
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: ds, roll: 0.6, seekerHalfAngle: half) == nil)
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: ds, roll: 0, seekerHalfAngle: half) == 0)
    }

    @Test func flareBehindSeekerDoesNotCapture() {
        let ds = [flare(at: SIMD3(-1_000, 0, -3_000))]
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: ds, roll: 0, seekerHalfAngle: half) == nil)
    }

    @Test func flareFartherThanTargetDoesNotCapture() {
        let ds = [flare(at: SIMD3(3_500, 0, -3_000))]
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: ds, roll: 0, seekerHalfAngle: half) == nil)
    }

    @Test func flareBeyondRangeDoesNotCapture() {
        let farTarget = SIMD3<Double>(20_000, 0, -3_000)
        let ds = [flare(at: SIMD3(5_000, 0, -3_000))]
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: farTarget, decoys: ds, roll: 0, seekerHalfAngle: half) == nil)
    }

    @Test func nearestEligibleFlareWinsAndEdgeCasesAreSafe() {
        let ds = [flare(at: SIMD3(2_000, 0, -3_000)), flare(at: SIMD3(500, 0, -3_000)),
                  chaffCloud(at: SIMD3(100, 0, -3_000))]
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: ds, roll: 0.2, seekerHalfAngle: half) == 1)
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: [], roll: 0, seekerHalfAngle: half) == nil)
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: .zero, target: target, decoys: ds, roll: 0, seekerHalfAngle: half) == nil)
        let atSeeker = [flare(at: seeker)]
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: atSeeker, roll: 0, seekerHalfAngle: half) == nil)
        // A flare outside the cone is skipped.
        let side = [flare(at: SIMD3(500, 800, -3_000))]
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: side, roll: 0, seekerHalfAngle: half) == nil)
        // An expired flare is skipped.
        var old = flare(at: SIMD3(500, 0, -3_000))
        old.age = 5
        #expect(CountermeasureSystem.flareCapture(seeker: seeker, seekerForward: fwd, target: target, decoys: [old], roll: 0, seekerHalfAngle: half) == nil)
    }

    // MARK: chaff

    @Test func chaffBlocksOnTheLineOfSight() {
        let radar = SIMD3<Double>(0, 0, -3_000)
        let tgt = SIMD3<Double>(10_000, 0, -3_000)
        let beam = 0.1
        #expect(CountermeasureSystem.chaffBlocks(radar: radar, target: tgt, decoys: [chaffCloud(at: SIMD3(4_000, 100, -3_000))], beamHalfAngle: beam))
        #expect(!CountermeasureSystem.chaffBlocks(radar: radar, target: tgt, decoys: [chaffCloud(at: SIMD3(4_000, 3_000, -3_000))], beamHalfAngle: beam))
        #expect(!CountermeasureSystem.chaffBlocks(radar: radar, target: tgt, decoys: [chaffCloud(at: SIMD3(-4_000, 0, -3_000))], beamHalfAngle: beam))
        // Beyond the target, a flare, an expired cloud, and an empty list do not block.
        #expect(!CountermeasureSystem.chaffBlocks(radar: radar, target: tgt, decoys: [chaffCloud(at: SIMD3(12_000, 0, -3_000))], beamHalfAngle: beam))
        #expect(!CountermeasureSystem.chaffBlocks(radar: radar, target: tgt, decoys: [flare(at: SIMD3(4_000, 0, -3_000))], beamHalfAngle: beam))
        var old = chaffCloud(at: SIMD3(4_000, 0, -3_000))
        old.age = 7
        #expect(!CountermeasureSystem.chaffBlocks(radar: radar, target: tgt, decoys: [old], beamHalfAngle: beam))
        #expect(!CountermeasureSystem.chaffBlocks(radar: radar, target: tgt, decoys: [], beamHalfAngle: beam))
        #expect(!CountermeasureSystem.chaffBlocks(radar: radar, target: radar, decoys: [chaffCloud(at: radar)], beamHalfAngle: beam))
    }

    @Test func runsAreDeterministic() {
        func run() -> (Int, Int, [Decoy]) {
            var cm = CountermeasureSystem()
            for i in 0..<300 {
                _ = cm.update(dt: dt, ownship: own, input: CountermeasureInput(flare: i % 50 < 10, chaff: i % 70 < 5))
            }
            return (cm.flares, cm.chaff, cm.decoys)
        }
        let a = run()
        let b = run()
        #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2)
    }
}
