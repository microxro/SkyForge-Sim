import Testing
import Foundation
@testable import SFGameplay

@Suite struct DamageTests {
    @Test func newAircraftIsIntact() {
        let d = AircraftDamage()
        #expect(d.airframe == 1 && d.engine == 1 && d.controls == 1)
        #expect(!d.destroyed && !d.engineOut)
        #expect(d.thrustFactor == 1 && d.controlFactor == 1)
        #expect(d.lastSource == nil)
    }

    @Test func fiftyCannonHitsDestroyExactlyOnce() {
        var d = AircraftDamage()
        var trues = 0
        for i in 1...50 {
            let killed = d.apply(source: .cannon, zone: .airframe, amount: AircraftDamage.cannonRoundDamage)
            if killed { trues += 1 }
            if i < 50 { #expect(!killed && !d.destroyed, "hit \(i)") }
        }
        #expect(trues == 1 && d.destroyed && d.airframe == 0)
    }

    @Test func missileHalvesThenDestroys() {
        var d = AircraftDamage()
        let firstHit = d.apply(source: .missile, zone: .airframe, amount: AircraftDamage.missileWarheadDamage)
        #expect(!firstHit)
        #expect(d.airframe == 0.5 && !d.destroyed)
        let secondHit = d.apply(source: .missile, zone: .airframe, amount: AircraftDamage.missileWarheadDamage)
        #expect(secondHit)
        #expect(d.destroyed)
    }

    @Test func invalidAmountsAreIgnored() {
        var d = AircraftDamage()
        let before = d
        let amounts: [Double] = [-1.0, -0.001, Double.nan, Double.infinity, -Double.infinity]
        for amount in amounts {
            let rejected = d.apply(source: .collision, zone: .airframe, amount: amount)
            #expect(!rejected)
            #expect(d == before)
        }
    }

    @Test func hitAfterDestructionChangesNothing() {
        var d = AircraftDamage()
        let collisionHit = d.apply(source: .collision, zone: .airframe, amount: AircraftDamage.collisionDamage)
        #expect(collisionHit)
        let wreck = d
        let ignoredHit = d.apply(source: .cannon, zone: .engine, amount: 0.5)
        #expect(!ignoredHit)
        #expect(d == wreck)
        #expect(d.lastSource == .collision)
    }

    @Test func engineHitsKillThrustWithoutDestroying() {
        var d = AircraftDamage()
        var hits = 0
        while !d.engineOut && hits < 100 {
            let engineHit = d.apply(source: .cannon, zone: .engine, amount: AircraftDamage.cannonRoundDamage)
            #expect(!engineHit)
            hits += 1
        }
        #expect(d.engineOut && d.thrustFactor == 0)
        #expect(d.airframe > 0 && !d.destroyed)
        #expect(hits < 100)
    }

    @Test func controlFactorHasAFloor() {
        var d = AircraftDamage()
        for _ in 0..<10 { _ = d.apply(source: .cannon, zone: .controls, amount: 0.05) }
        #expect(d.controls == 0)
        #expect(d.controlFactor == 0.2)
        #expect(d.airframe > 0)
    }

    @Test func valuesStayInUnitRange() {
        for zone in DamageZone.allCases {
            var d = AircraftDamage()
            _ = d.apply(source: .collision, zone: zone, amount: Double.greatestFiniteMagnitude)
            let values: [Double] = [d.airframe, d.engine, d.controls]
            for v in values { #expect(v >= 0 && v <= 1) }
            #expect(d.thrustFactor >= 0 && d.thrustFactor <= 1)
            #expect(d.controlFactor >= 0.2 && d.controlFactor <= 1)
        }
    }

    @Test func lastSourceTracksLatestAppliedHit() {
        var d = AircraftDamage()
        _ = d.apply(source: .cannon, zone: .airframe, amount: 0.01)
        #expect(d.lastSource == .cannon)
        _ = d.apply(source: .missile, zone: .engine, amount: 0.01)
        #expect(d.lastSource == .missile)
        _ = d.apply(source: .collision, zone: .airframe, amount: -1)
        #expect(d.lastSource == .missile)
    }

    @Test func combatTallyDefaultsAndRoundTrips() throws {
        var t = CombatTally()
        #expect(t.hitsTaken == 0 && t.damageTaken == 0 && t.countermeasuresUsed == 0)
        #expect(t.missilesFired == 0 && t.missilesHit == 0)
        t.hitsTaken = 3
        t.damageTaken = 0.75
        t.countermeasuresUsed = 2
        t.missilesFired = 4
        t.missilesHit = 1
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(CombatTally.self, from: data)
        #expect(back == t)
    }
}
