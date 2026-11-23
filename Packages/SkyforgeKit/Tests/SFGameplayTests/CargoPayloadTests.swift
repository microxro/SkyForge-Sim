// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFGameplay
@testable import SFFlightModel

@Suite struct CargoPayloadTests {
    private let world = FlatWorld()

    @Test func theCargoRunLoadsTheAircraftBeforeTakeoff() {
        let base = AircraftCatalog.sfCruiser.config.mass
        let s = GameplaySession(world: world, aircraft: AircraftCatalog.sfCruiser, mission: MissionCatalog.cargoRun)
        #expect(s.aircraft.config.mass > base + 170, "the 180 kg payload was not applied to the flight model")
    }

    @Test func aMissionWithoutPayloadFliesTheEmptyAircraft() {
        let base = AircraftCatalog.sfCruiser.config.mass
        let s = GameplaySession(world: world, aircraft: AircraftCatalog.sfCruiser, mission: nil)
        #expect(abs(s.aircraft.config.mass - base) < 0.001)
    }

    @Test func theCargoLoadStaysInsideTheCGEnvelope() {
        let wb = WeightAndBalance(emptyMass: AircraftCatalog.sfCruiser.config.mass, stations: MissionCatalog.cargoRun.payload)
        #expect(wb.status == .withinEnvelope, "cargo run CG is outside the envelope")
    }

    @Test func theCargoRunUsesTheGrassSurface() {
        #expect(MissionCatalog.cargoRun.surface == .grass)
        let s = GameplaySession(world: world, aircraft: AircraftCatalog.sfCruiser, mission: MissionCatalog.cargoRun)
        #expect(s.environment.surface == .grass)
    }
}
