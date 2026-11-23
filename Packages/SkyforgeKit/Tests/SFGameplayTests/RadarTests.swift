import Testing
import Foundation
import SFMath
@testable import SFGameplay

@Suite struct RadarTests {
    let own = Ownship(position: SIMD3(0, 0, -3_000), velocity: SIMD3(200, 0, 0), forward: SIMD3(1, 0, 0))
    let dt = 0.05

    func target(_ id: String, x: Double, y: Double = 0, z: Double = -3_000, heading: Double = 0, speed: Double = 0) -> AITarget {
        AITarget(id: id, role: .hostile, position: SIMD3(x, y, z), heading: heading, speed: speed)
    }

    /// A radar stepped through `edges` rising edges of cycleMode.
    func radarAfter(edges: Int) -> RadarSet {
        var radar = RadarSet()
        for _ in 0..<edges {
            _ = radar.update(dt: dt, ownship: own, targets: [], input: RadarInput(cycleMode: true))
            _ = radar.update(dt: dt, ownship: own, targets: [], input: RadarInput(cycleMode: false))
        }
        return radar
    }

    func trackRadar() -> RadarSet { radarAfter(edges: 3) }
    func searchRadar() -> RadarSet { radarAfter(edges: 2) }

    /// Presses lockNext once (rising edge then release).
    func pressLock(_ radar: inout RadarSet, targets: [AITarget], chaff: [SIMD3<Double>] = []) -> [RadarEvent] {
        var events = radar.update(dt: dt, ownship: own, targets: targets, input: RadarInput(lockNext: true), chaffClouds: chaff)
        events += radar.update(dt: dt, ownship: own, targets: targets, input: RadarInput(lockNext: false), chaffClouds: chaff)
        return events
    }

    /// Locks `targets` (dead ahead) and runs long enough for the lock to complete.
    func lockedRadar(_ targets: [AITarget]) -> RadarSet {
        var radar = trackRadar()
        _ = pressLock(&radar, targets: targets)
        for _ in 0..<45 { _ = radar.update(dt: dt, ownship: own, targets: targets, input: RadarInput()) }
        return radar
    }

    @Test func modeCyclingCoversTheRing() {
        var radar = RadarSet()
        #expect(radar.mode == .off)
        var seen: [RadarMode] = []
        for _ in 0..<4 {
            let e = radar.update(dt: dt, ownship: own, targets: [], input: RadarInput(cycleMode: true))
            #expect(e.contains(.modeChanged(radar.mode)))
            seen.append(radar.mode)
            _ = radar.update(dt: dt, ownship: own, targets: [], input: RadarInput())
        }
        #expect(seen == [.standby, .search, .track, .off])
        #expect(RadarMode.allCases.map { $0.displayName } == ["OFF", "STBY", "SRCH", "TRK"])
    }

    @Test func heldCycleStepsOnlyOnce() {
        var radar = RadarSet()
        var changes = 0
        for _ in 0..<20 {
            let e = radar.update(dt: dt, ownship: own, targets: [], input: RadarInput(cycleMode: true))
            for event in e {
                if case .modeChanged = event { changes += 1 }
            }
        }
        #expect(changes == 1)
        #expect(radar.mode == .standby)
    }

    @Test func offAndStandbyShowNothing() {
        var radar = RadarSet()
        let t = [target("a", x: 5_000)]
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        #expect(radar.contacts.isEmpty)
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput(cycleMode: true))
        #expect(radar.mode == .standby)
        #expect(radar.contacts.isEmpty)
    }

    @Test func aheadIsAContactBehindIsNot() {
        var radar = searchRadar()
        let t = [target("ahead", x: 5_000), target("behind", x: -5_000)]
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        #expect(radar.contacts.map { $0.id } == ["ahead"])
        #expect(abs(radar.contacts[0].bearing) < 1e-9)
        #expect(abs(radar.contacts[0].elevation) < 1e-9)
        #expect(abs(radar.contacts[0].range - 5_000) < 1e-6)
        #expect(abs(radar.contacts[0].altitude - 3_000) < 1e-9)
    }

    @Test func outsideTheScanVolumeIsHidden() {
        var radar = searchRadar()
        // 70 degrees right, and 30 degrees up: both outside the scan limits.
        let wide = target("wide", x: 1_000 * cos(70 * Double.pi / 180), y: 1_000 * sin(70 * Double.pi / 180))
        let high = target("high", x: 1_000 * cos(30 * Double.pi / 180), z: -3_000 - 1_000 * sin(30 * Double.pi / 180))
        _ = radar.update(dt: dt, ownship: own, targets: [wide, high], input: RadarInput())
        #expect(radar.contacts.isEmpty)
    }

    @Test func contactsSortedByRangeAndCapped() {
        var radar = searchRadar()
        let order = [7, 2, 9, 4, 1, 10, 3, 8, 5, 6]
        let t = order.map { target("t\($0)", x: Double($0) * 1_000) }
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        #expect(radar.contacts.count == RadarSet.maxContacts)
        #expect(radar.contacts.map { $0.id } == (1...8).map { "t\($0)" })
    }

    @Test func bearingSignAndMagnitude() {
        var radar = searchRadar()
        let t = [target("r", x: 1_000, y: 100), target("l", x: 1_000, y: -100)]
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        let r = radar.contacts.first { $0.id == "r" }
        let l = radar.contacts.first { $0.id == "l" }
        #expect(r != nil && l != nil)
        #expect(abs((r?.bearing ?? 0) - 0.0997) < 0.001)
        #expect((l?.bearing ?? 0) < 0)
    }

    @Test func elevationAboveTheNoseIsPositive() {
        var radar = searchRadar()
        _ = radar.update(dt: dt, ownship: own, targets: [target("up", x: 1_000, z: -3_100)], input: RadarInput())
        #expect((radar.contacts.first?.elevation ?? 0) > 0.09)
    }

    @Test func closureRateSign() {
        var radar = searchRadar()
        // Heading pi flies south, toward the aircraft. Own speed adds to it.
        let inbound = target("in", x: 5_000, heading: .pi, speed: 100)
        let outbound = target("out", x: 8_000, heading: 0, speed: 300)
        _ = radar.update(dt: dt, ownship: own, targets: [inbound, outbound], input: RadarInput())
        let i = radar.contacts.first { $0.id == "in" }
        let o = radar.contacts.first { $0.id == "out" }
        #expect(abs((i?.closureRate ?? 0) - 300) < 1e-6)
        #expect((o?.closureRate ?? 0) < 0)
    }

    @Test func destroyedTargetsAreNotContacts() {
        var radar = searchRadar()
        var dead = target("dead", x: 4_000)
        dead.health = 0
        _ = radar.update(dt: dt, ownship: own, targets: [dead], input: RadarInput())
        #expect(radar.contacts.isEmpty)
    }

    @Test func maxRangeBoundary() {
        var radar = searchRadar()
        let t = [target("edge", x: RadarSet.maxRange), target("over", x: RadarSet.maxRange + 1)]
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        #expect(radar.contacts.map { $0.id } == ["edge"])
        #expect(abs(radar.contacts[0].trackQuality - 0.5) < 1e-9)
    }

    @Test func degenerateTargetsAreIgnored() {
        var radar = searchRadar()
        let t = [target("onTop", x: 0), target("nan", x: .nan)]
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        #expect(radar.contacts.isEmpty)
    }

    @Test func deadAheadTargetLocksAfterLockTime() {
        var radar = trackRadar()
        let t = [target("a", x: 10_000)]
        var events = pressLock(&radar, targets: t)
        if case .acquiring = radar.lock {} else { Issue.record("expected acquiring, got \(radar.lock)") }
        #expect(radar.lockedTargetID == nil)
        for _ in 0..<45 {
            events += radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        }
        #expect(events.contains(.lockAcquired("a")))
        #expect(radar.lock == .locked(targetID: "a"))
        #expect(radar.lockedTargetID == "a")
        #expect(radar.contacts.first?.locked == true)
    }

    @Test func lockNeedsTheTrackConeAndTime() {
        var radar = trackRadar()
        // 20 degrees off the nose: a contact, but outside the 10 degree track cone.
        let off = target("off", x: 10_000 * cos(20 * Double.pi / 180), y: 10_000 * sin(20 * Double.pi / 180))
        _ = pressLock(&radar, targets: [off])
        #expect(radar.lock == .none)
        #expect(radar.contacts.count == 1)

        var radar2 = trackRadar()
        let a = target("a", x: 10_000)
        _ = pressLock(&radar2, targets: [a])
        for _ in 0..<20 { _ = radar2.update(dt: dt, ownship: own, targets: [a], input: RadarInput()) }
        #expect(radar2.lockedTargetID == nil)   // 1 s of a 2 s acquisition
    }

    @Test func lockOnlyInTrackMode() {
        var radar = searchRadar()
        _ = pressLock(&radar, targets: [target("a", x: 10_000)])
        #expect(radar.lock == .none)
    }

    @Test func lockBreaksWhenTargetLeavesTheCone() {
        var t = [target("a", x: 10_000)]
        var radar = lockedRadar(t)
        #expect(radar.lockedTargetID == "a")
        t[0].position = SIMD3(10_000, 3_000, -3_000)   // about 16.7 degrees off the nose
        let e = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        #expect(e.contains(.lockLost("a")))
        #expect(radar.lock == .none)
    }

    @Test func lockBreaksWhenTargetIsDestroyed() {
        var t = [target("a", x: 10_000)]
        var radar = lockedRadar(t)
        #expect(radar.lockedTargetID == "a")
        t[0].health = 0
        let e = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        #expect(e.contains(.lockLost("a")))
        #expect(radar.lock == .none)
    }

    @Test func lockNextAgainReleasesALock() {
        let t = [target("a", x: 10_000)]
        var radar = lockedRadar(t)
        #expect(radar.lockedTargetID == "a")
        let e = pressLock(&radar, targets: t)
        #expect(e.contains(.lockLost("a")))
        #expect(radar.lock == .none)
    }

    @Test func nearestUnblockedContactInTheConeIsPicked() {
        var radar = trackRadar()
        let near = target("near", x: 4_000, y: 1_500)      // about 20 degrees: outside the cone
        let mid = target("mid", x: 8_000)
        let far = target("far", x: 12_000)
        _ = pressLock(&radar, targets: [far, near, mid])
        if case .acquiring(let id, _) = radar.lock {
            #expect(id == "mid")
        } else {
            Issue.record("expected acquiring, got \(radar.lock)")
        }
    }

    @Test func chaffBlocksAContactAndPreventsLock() {
        var radar = trackRadar()
        let t = [target("a", x: 10_000)]
        let chaff: [SIMD3<Double>] = [SIMD3(5_000, 0, -3_000)]
        _ = pressLock(&radar, targets: t, chaff: chaff)
        #expect(radar.lock == .none)
        let expected = (1 - 0.5 * 10_000 / RadarSet.maxRange) * 0.5
        #expect(abs(radar.contacts[0].trackQuality - expected) < 1e-9)
        for _ in 0..<60 { _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput(), chaffClouds: chaff) }
        #expect(radar.lock == .none)
    }

    @Test func chaffBehindTheTargetOrOffTheLineDoesNotBlock() {
        var radar = trackRadar()
        let t = [target("a", x: 10_000)]
        let chaff: [SIMD3<Double>] = [SIMD3(12_000, 0, -3_000), SIMD3(5_000, 1_000, -3_000)]
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput(), chaffClouds: chaff)
        let expected = 1 - 0.5 * 10_000 / RadarSet.maxRange
        #expect(abs(radar.contacts[0].trackQuality - expected) < 1e-9)
    }

    @Test func chaffBreaksAnExistingLockAfterTheGracePeriod() {
        let t = [target("a", x: 10_000)]
        var radar = lockedRadar(t)
        #expect(radar.lockedTargetID == "a")
        let chaff: [SIMD3<Double>] = [SIMD3(5_000, 0, -3_000)]
        var events: [RadarEvent] = []
        for _ in 0..<5 {   // 0.25 s: still held
            events += radar.update(dt: dt, ownship: own, targets: t, input: RadarInput(), chaffClouds: chaff)
        }
        #expect(radar.lockedTargetID == "a")
        #expect(events.isEmpty)
        // A brief clear resets the timer.
        _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput())
        for _ in 0..<5 { _ = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput(), chaffClouds: chaff) }
        #expect(radar.lockedTargetID == "a")
        for _ in 0..<10 {
            events += radar.update(dt: dt, ownship: own, targets: t, input: RadarInput(), chaffClouds: chaff)
        }
        #expect(events.contains(.lockLost("a")))
        #expect(radar.lock == .none)
    }

    @Test func leavingTrackModeDropsTheLock() {
        let t = [target("a", x: 10_000)]
        var radar = lockedRadar(t)
        #expect(radar.lockedTargetID == "a")
        let e = radar.update(dt: dt, ownship: own, targets: t, input: RadarInput(cycleMode: true))
        #expect(radar.mode == .off)
        #expect(e == [.modeChanged(.off), .lockLost("a")])
        #expect(radar.lock == .none)
        #expect(radar.contacts.isEmpty)
    }

    @Test func nonPositiveOrNaNDtDoesNotAdvanceAcquisition() {
        var radar = trackRadar()
        let t = [target("a", x: 10_000)]
        _ = pressLock(&radar, targets: t)
        for _ in 0..<100 { _ = radar.update(dt: 0, ownship: own, targets: t, input: RadarInput()) }
        _ = radar.update(dt: -1, ownship: own, targets: t, input: RadarInput())
        _ = radar.update(dt: .nan, ownship: own, targets: t, input: RadarInput())
        #expect(radar.lockedTargetID == nil)
    }
}
