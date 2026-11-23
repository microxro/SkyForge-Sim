import Testing
import Foundation
import SFMath
import SFFlightModel
@testable import SFGameplay

@Suite struct WaterSpinWiringTests {
    let world = FlatWorld()

    @Test func carryingWaterAddsMassAndScalesInertia() {
        let base = AircraftConfig.sf1Trainer
        let none = GameplaySession.configCarryingWater(base, water: 0)
        #expect(none.mass == base.mass)
        #expect(none.inertia == base.inertia)

        let loaded = GameplaySession.configCarryingWater(base, water: 500)
        #expect(loaded.mass == base.mass + 500)
        #expect(abs(loaded.inertia.x / base.inertia.x - loaded.mass / base.mass) < 1e-12)
    }

    @Test func negativeOrNonFiniteWaterIsIgnored() {
        let base = AircraftConfig.sf1Trainer
        #expect(GameplaySession.configCarryingWater(base, water: -200).mass == base.mass)
        #expect(GameplaySession.configCarryingWater(base, water: .nan).mass == base.mass)
    }

    @Test func aFreshSessionHasAnEmptyTankAndNoSpin() {
        let s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer)
        #expect(s.scoop.load == 0)
        #expect(!s.spin.inSpin)
    }

    @Test func doorOpenOnPavedRunwayTakesNoWater() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer)
        var c = PilotControls()
        c.water.doorOpen = true
        for _ in 0..<(3 * 120) { s.step(c) }
        #expect(s.scoop.load == 0, "the scoop only works on the water")
        #expect(s.model.config.mass == AircraftCatalog.sf1Trainer.config.mass)
    }

    @Test func releaseOnAnEmptyTankIsHarmless() {
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer)
        var c = PilotControls()
        c.water.release = true
        for _ in 0..<120 { s.step(c) }
        #expect(s.scoop.load == 0)
        #expect(!s.crashed)
    }
}
