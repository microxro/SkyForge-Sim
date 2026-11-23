// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFCareer

private let sfc = "org.skyforge.sfc"

private func flight(_ aircraft: String = sfc, hours: Double, landed: Bool = true, sinkFPM: Double? = 150,
                    crashed: Bool = false, endedAt: Int = 1_000) -> FlightReport {
    FlightReport(kind: .freeFlight, aircraftID: aircraft, departureICAO: "KMRY", arrivalICAO: "KMRY",
                 durationS: hours * 3_600, distanceM: 100_000, landed: landed, crashed: crashed,
                 touchdownSinkFPM: sinkFPM, endedAt: endedAt)
}

private func isGrounded(_ status: DispatchStatus) -> Bool {
    if case .grounded = status { return true }
    return false
}

/// A career that owns the SFC and has enough credits to service it.
private func ownedCareer() -> CareerState {
    var state = CareerState()
    state.credits = 1_000_000
    state.ownedAircraft.insert(sfc)
    return state
}

@Suite struct MaintenanceCostTests {
    @Test func servicingScalesWithReferencePrice() {
        // SF-C Cruiser: 45,000 cr. Engine overhaul is 22% of that.
        #expect(ServiceAction.overhaul.cost(for: .engine, referencePrice: 45_000) == 9_900)
        #expect(ServiceAction.inspection.cost(for: .engine, referencePrice: 45_000) == 792)
        #expect(ServiceAction.repair.cost(for: .engine, referencePrice: 45_000) == 4_950)
    }

    @Test func starterAircraftUsesReferencePrice() throws {
        let spec = try #require(Economy.spec(MaintenanceRules.starterAircraftID))
        #expect(MaintenanceRules.referencePrice(for: spec) == MaintenanceRules.starterReferencePrice)
    }
}

@Suite struct MaintenanceFlightTests {
    @Test func flightsWearComponentsByRule() {
        var state = ownedCareer()
        CareerEngine.apply(flight(hours: 2), to: &state)
        let m = state.maintenanceState(for: sfc)
        #expect(abs(m.wear(.engine).wear - 2.0 / 1_500) < 1e-9)
        #expect(abs(m.wear(.airframe).wear - 2.0 / 4_000) < 1e-9)
        #expect(m.wear(.engine).hoursSinceService == 2)
        #expect(abs(m.totalHours - 2) < 1e-9)
        // One landing: brakes and tires take a landing's worth of wear.
        #expect(abs(m.wear(.brakes).wear - 1.0 / 350) < 1e-9)
        #expect(abs(m.wear(.tires).wear - 1.0 / 250) < 1e-9)
    }

    @Test func hardLandingAddsAirframeWear() {
        var state = ownedCareer()
        CareerEngine.apply(flight(hours: 1, sinkFPM: 700), to: &state)
        let airframe = state.maintenanceState(for: sfc).wear(.airframe).wear
        #expect(abs(airframe - (1.0 / 4_000 + FailureModel.hardLandingWear)) < 1e-9)
    }

    @Test func unownedAircraftGetsNoMaintenanceState() {
        var state = ownedCareer()
        CareerEngine.apply(flight("org.skyforge.sfa", hours: 1), to: &state)
        #expect(state.maintenance["org.skyforge.sfa"] == nil)
    }

    @Test func overdueTiresGroundTheAircraft() {
        var state = ownedCareer()
        // Tires are due at 80 hours and grounded at 96. Flights are capped at 24 hours each.
        for i in 0..<5 { CareerEngine.apply(flight(hours: 20, endedAt: 1_000 + i), to: &state) }
        #expect(state.dispatchStatus(for: sfc) == .grounded([.tires]))
    }

    @Test func wornAircraftFailsInFlightAndGrounds() {
        var state = ownedCareer()
        var worn = AircraftMaintenance()
        for c in AircraftComponent.allCases { worn.set(c, ComponentWear(wear: 0.95)) }
        state.maintenance[sfc] = worn

        var failures: [AircraftComponent] = []
        var i = 0
        while i < 30, !isGrounded(state.dispatchStatus(for: sfc)) {
            failures += CareerEngine.apply(flight(hours: 1, endedAt: 2_000 + i), to: &state).maintenanceFailures
            i += 1
        }
        #expect(!failures.isEmpty)
        #expect(isGrounded(state.dispatchStatus(for: sfc)))
        #expect(state.maintenanceState(for: sfc).history.filter { $0.kind == .failure }.count == failures.count)
    }

    @Test func sameFlightRollsTheSameWay() {
        var a = ownedCareer()
        var b = ownedCareer()
        var worn = AircraftMaintenance()
        for c in AircraftComponent.allCases { worn.set(c, ComponentWear(wear: 0.95)) }
        a.maintenance[sfc] = worn
        b.maintenance[sfc] = worn
        let fa = CareerEngine.apply(flight(hours: 1, endedAt: 42), to: &a).maintenanceFailures
        let fb = CareerEngine.apply(flight(hours: 1, endedAt: 42), to: &b).maintenanceFailures
        #expect(fa == fb)
    }
}

@Suite struct MaintenanceServiceTests {
    @Test func inspectionClearsGroundingAndCharges() throws {
        var state = ownedCareer()
        for i in 0..<5 { CareerEngine.apply(flight(hours: 20, endedAt: 1_000 + i), to: &state) }
        let before = state.credits
        let cost = try state.service(aircraftID: sfc, component: .tires, action: .inspection)
        // Tires overhaul is 1% of 45,000 = 450; inspection is 8% of that = 36.
        #expect(cost == 36)
        #expect(state.credits == before - 36)
        #expect(!isGrounded(state.dispatchStatus(for: sfc)))
    }

    @Test func overhaulResetsWearAndChargesOverhaulPrice() throws {
        var state = ownedCareer()
        CareerEngine.apply(flight(hours: 50), to: &state)
        let before = state.credits
        try state.service(aircraftID: sfc, component: .engine, action: .overhaul)
        #expect(state.credits == before - 9_900)
        let engine = state.maintenanceState(for: sfc).wear(.engine)
        #expect(engine.wear == 0)
        #expect(engine.hoursSinceService == 0)
        #expect(state.maintenanceState(for: sfc).history.last?.kind == .service(.overhaul))
    }

    @Test func repairClearsDefectAndReducesWear() throws {
        var state = ownedCareer()
        var worn = AircraftMaintenance()
        worn.set(.engine, ComponentWear(wear: 0.9, defect: true))
        state.maintenance[sfc] = worn
        try state.service(aircraftID: sfc, component: .engine, action: .repair)
        let engine = state.maintenanceState(for: sfc).wear(.engine)
        #expect(engine.defect == false)
        #expect(abs(engine.wear - (0.9 - ServiceAction.repairWearRelief)) < 1e-9)
    }

    @Test func servicingUnownedAircraftThrows() {
        var state = ownedCareer()
        #expect(throws: MaintenanceError.self) {
            try state.service(aircraftID: "org.skyforge.sfa", component: .engine, action: .inspection)
        }
    }

    @Test func insufficientFundsLeavesStateUnchanged() {
        var state = ownedCareer()
        state.credits = 100
        let before = state.maintenance
        #expect(throws: MaintenanceError.self) {
            try state.service(aircraftID: sfc, component: .engine, action: .overhaul)
        }
        #expect(state.maintenance == before)
        #expect(state.credits == 100)
    }
}

@Suite struct MaintenanceSaleTests {
    @Test func sellReturnsResaleValueAndRemovesAircraft() throws {
        var state = ownedCareer()
        let before = state.credits
        let value = try state.sell(aircraftID: sfc)
        #expect(value == 45_000)   // no hours, no wear: full reference price
        #expect(state.credits == before + 45_000)
        #expect(!state.ownedAircraft.contains(sfc))
        #expect(state.maintenance[sfc] == nil)
    }

    @Test func starterAircraftCannotBeSold() {
        var state = CareerState()
        #expect(throws: MaintenanceError.self) { try state.sell(aircraftID: MaintenanceRules.starterAircraftID) }
    }

    @Test func resaleFallsWithHoursAndDefects() {
        var state = ownedCareer()
        let fresh = state.resaleValue(for: sfc) ?? 0
        CareerEngine.apply(flight(hours: 20), to: &state)
        let flown = state.resaleValue(for: sfc) ?? 0
        #expect(flown < fresh)
        var defective = ownedCareer()
        var m = AircraftMaintenance()
        m.set(.engine, ComponentWear(defect: true))
        defective.maintenance[sfc] = m
        #expect((defective.resaleValue(for: sfc) ?? 0) < fresh)
    }
}

@Suite struct MaintenanceSaveTests {
    @Test func maintenanceRoundTripsThroughJSON() throws {
        var state = ownedCareer()
        CareerEngine.apply(flight(hours: 3), to: &state)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CareerState.self, from: data)
        #expect(decoded.maintenance == state.maintenance)
    }

    @Test func sanitizeDropsUnownedAndClampsBadNumbers() {
        var state = ownedCareer()
        state.maintenance["org.skyforge.sf2"] = AircraftMaintenance()
        var m = AircraftMaintenance()
        m.set(.engine, ComponentWear(wear: .nan, hoursSinceService: .infinity))
        state.maintenance[sfc] = m
        state.sanitize()
        #expect(state.maintenance["org.skyforge.sf2"] == nil)
        let engine = state.maintenanceState(for: sfc).wear(.engine)
        #expect(engine.wear == 0)
        #expect(engine.hoursSinceService == 0)
    }
}
