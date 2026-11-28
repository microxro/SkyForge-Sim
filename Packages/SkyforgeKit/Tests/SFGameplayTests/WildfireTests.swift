// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFGameplay

@Suite struct WildfireTests {
    @Test func ignitingOneCellAddsQuarterHectare() {
        var f = Wildfire()
        f.ignite(east: 25, north: 25)
        #expect(f.burningCount == 1)
        #expect(f.everBurned == 1)
        #expect(abs(f.burnedHectares - 0.25) < 1e-9)
    }

    @Test func fireSpreadsWithoutWind() {
        var f = Wildfire()
        f.ignite(east: 25, north: 25)
        for _ in 0..<100 { f.step(dt: 1) }
        #expect(f.burningCount > 1)
        #expect(f.everBurned >= f.burningCount)
    }

    @Test func fireBurnsOutWhenItsFuelIsGone() {
        var f = Wildfire()
        f.ignite(east: 25, north: 25)
        var steps = 0
        while !f.isOut && steps < 2_000 {
            f.step(dt: 60)
            steps += 1
        }
        // Without water the fire runs through its fuel patch and goes out, instead of burning forever.
        #expect(f.isOut)
        #expect(f.everBurned <= (2 * Wildfire.fuelRadiusCells + 1) * (2 * Wildfire.fuelRadiusCells + 1))
    }

    @Test func fireDoesNotSpreadBeyondFuel() {
        var f = Wildfire()
        // Ignite well outside the fuel patch: the one cell burns, but nothing spreads from it.
        f.ignite(east: 5_000, north: 5_000)
        for _ in 0..<100 { f.step(dt: 1) }
        #expect(f.everBurned == 1)
    }

    @Test func fireRunsDownwind() {
        var f = Wildfire(windEast: 8, windNorth: 0)
        f.ignite(east: 25, north: 25)
        for _ in 0..<60 { f.step(dt: 1) }
        let east = f.heat.keys.filter { $0.i > 0 }.count
        let west = f.heat.keys.filter { $0.i < 0 }.count
        #expect(east > west)
        #expect(east > 0)
    }

    @Test func dropOnFireExtinguishesSmallCell() {
        var f = Wildfire()
        f.ignite(east: 25, north: 25)
        // 800 kg onto one cell takes its full unit of heat out.
        let out = f.drop(WildfireDrop(east: 25, north: 25, radius: 30, waterKg: 800))
        #expect(out.cellsWetted == 1)
        #expect(out.burningWetted == 1)
        #expect(abs(out.accuracy - 1) < 1e-9)
        #expect(f.isOut)
    }

    @Test func dropThatMissesLeavesFireBurning() {
        var f = Wildfire()
        f.ignite(east: 25, north: 25)
        let out = f.drop(WildfireDrop(east: 1_000, north: 1_000, radius: 30, waterKg: 800))
        #expect(out.burningWetted == 0)
        #expect(out.accuracy == 0)
        #expect(out.waterUsedKg == 800)
        #expect(f.burningCount == 1)
        #expect(!f.isOut)
    }

    @Test func invalidInputsAreIgnored() {
        var f = Wildfire(windEast: .nan, windNorth: .infinity)
        #expect(f.windEast == 0)
        #expect(f.windNorth == 0)
        f.ignite(east: 25, north: 25)
        f.step(dt: 0)
        f.step(dt: 120)
        #expect(f.elapsed == 0)
        let out = f.drop(WildfireDrop(east: 25, north: 25, radius: 30, waterKg: 0))
        #expect(out.waterUsedKg == 0)
        #expect(out.cellsWetted == 0)
        #expect(f.burningCount == 1)
    }

    @Test func simulationIsDeterministic() {
        func run() -> Wildfire {
            var f = Wildfire(windEast: 4, windNorth: -3)
            f.ignite(east: 25, north: 25)
            for _ in 0..<80 { f.step(dt: 1) }
            _ = f.drop(WildfireDrop(east: 90, north: 60, radius: 80, waterKg: 1_500))
            for _ in 0..<40 { f.step(dt: 1) }
            return f
        }
        #expect(run() == run())
    }
}
