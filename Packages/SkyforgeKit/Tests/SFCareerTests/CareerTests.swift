// SKYFORGE — Apache-2.0
import Testing
@testable import SFCareer

private func isGrounded(_ status: DispatchStatus) -> Bool {
    if case .grounded = status { return true }
    return false
}

@Suite struct WalletTests {
    @Test func spendRecordsLedgerAndRejectsOverdraft() throws {
        var wallet = Wallet(balance: Credits(1_000))
        try wallet.spend(Credits(400), day: 1, reason: "fuel")
        #expect(wallet.balance == Credits(600))
        #expect(wallet.ledger.count == 1)
        #expect(wallet.ledger[0].amount == Credits(-400))
        #expect(throws: CareerError.self) {
            try wallet.spend(Credits(700), day: 1, reason: "too much")
        }
        #expect(wallet.balance == Credits(600))
    }

    @Test func negativeAmountsAreRejected() {
        var wallet = Wallet()
        #expect(throws: CareerError.self) { try wallet.earn(Credits(-5), day: 0, reason: "bad") }
        #expect(throws: CareerError.self) { try wallet.spend(Credits(-5), day: 0, reason: "bad") }
    }
}

@Suite struct FailureModelTests {
    @Test func noFailureChanceBelowThreshold() {
        #expect(FailureModel.chancePerFlightHour(wear: 0.5) == 0)
        #expect(FailureModel.chancePerFlightHour(wear: 0.8) == 0)
    }

    @Test func failureChanceRisesAndIsCapped() {
        #expect(abs(FailureModel.chancePerFlightHour(wear: 1.0) - 0.05) < 1e-12)
        #expect(FailureModel.chancePerFlightHour(wear: 1.5) == 0.05)
    }
}

@Suite struct FleetPurchaseTests {
    @Test func usedAircraftChargesDiscountedPrice() throws {
        var fleet = Fleet(wallet: Wallet(balance: Credits(200_000)))
        let id = try fleet.purchase(.sf1Trainer, condition: .used(wear: 0.5))
        // 180,000 * (1 - 0.6 * 0.5) = 126,000
        #expect(fleet.wallet.balance == Credits(74_000))
        #expect(fleet.aircraft(id: id)?.purchasePrice == Credits(126_000))
        #expect(fleet.aircraft(id: id)?.components[.engine]?.wear == 0.5)
    }

    @Test func failedPurchaseLeavesFleetUnchanged() {
        var fleet = Fleet(wallet: Wallet(balance: Credits(1_000)))
        #expect(throws: CareerError.self) { try fleet.purchase(.sf1Trainer) }
        #expect(fleet.aircraft.isEmpty)
        #expect(fleet.wallet.balance == Credits(1_000))
    }

    @Test func invalidUsedConditionIsRejected() {
        var fleet = Fleet()
        #expect(throws: CareerError.self) { try fleet.purchase(.sf1Trainer, condition: .used(wear: 0.95)) }
        #expect(fleet.aircraft.isEmpty)
    }

    @Test func sellReturnsResaleValueAndRemovesAircraft() throws {
        var fleet = Fleet()
        let id = try fleet.purchase(.sf1Trainer)
        var rng = SeededGenerator(seed: 3)
        try fleet.recordFlight(id: id, usage: FlightUsage(hours: 400, landings: 200), using: &rng)
        let resale = try #require(fleet.aircraft(id: id)?.resaleValue)
        let before = fleet.wallet.balance
        try fleet.sell(id: id)
        #expect(fleet.wallet.balance == before + resale)
        #expect(fleet.aircraft(id: id) == nil)
        #expect(resale < AircraftModel.sf1Trainer.newPrice)
    }
}

@Suite struct FleetFlightTests {
    @Test func flightAccruesWearPerComponentRule() throws {
        var fleet = Fleet()
        let id = try fleet.purchase(.sf1Trainer)
        var rng = SeededGenerator(seed: 1)
        let failed = try fleet.recordFlight(id: id, usage: FlightUsage(hours: 2, landings: 4), using: &rng)
        let aircraft = try #require(fleet.aircraft(id: id))
        #expect(failed.isEmpty)
        #expect(aircraft.totalHours == 2)
        #expect(aircraft.totalLandings == 4)
        #expect(abs((aircraft.components[.engine]?.wear ?? -1) - 2.0 / 1_500) < 1e-9)
        #expect(abs((aircraft.components[.brakes]?.wear ?? -1) - 4.0 / 350) < 1e-9)
        #expect(aircraft.components[.engine]?.hoursSinceService == 2)
    }

    @Test func overdueTiresGroundTheAircraft() throws {
        var fleet = Fleet()
        let id = try fleet.purchase(.sf1Trainer)
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            if let aircraft = fleet.aircraft(id: id), isGrounded(aircraft.dispatchStatus) { break }
            try fleet.recordFlight(id: id, usage: FlightUsage(hours: 1, landings: 1), using: &rng)
        }
        let status = try #require(fleet.aircraft(id: id)?.dispatchStatus)
        #expect(status == .grounded([.tires]))
        #expect(throws: CareerError.self) {
            try fleet.recordFlight(id: id, usage: FlightUsage(hours: 1, landings: 1), using: &rng)
        }
    }

    @Test func wornAircraftFailsInFlightAndGrounds() throws {
        var fleet = Fleet()
        let id = try fleet.purchase(.sf1Trainer, condition: .used(wear: 0.95))
        var rng = SeededGenerator(seed: 42)
        var failures: [AircraftComponent] = []
        for _ in 0..<30 {
            if let aircraft = fleet.aircraft(id: id), isGrounded(aircraft.dispatchStatus) { break }
            let failed = try fleet.recordFlight(id: id, usage: FlightUsage(hours: 1, landings: 1), using: &rng)
            failures.append(contentsOf: failed)
        }
        #expect(!failures.isEmpty)
        let aircraft = try #require(fleet.aircraft(id: id))
        #expect(isGrounded(aircraft.dispatchStatus))
        #expect(aircraft.maintenanceLog.filter { $0.kind == .failure }.count == failures.count)
    }

    @Test func newAircraftNeverFailsInFlight() throws {
        var fleet = Fleet()
        let id = try fleet.purchase(.sf1Trainer)
        var rng = SeededGenerator(seed: 99)
        for _ in 0..<50 {
            let failed = try fleet.recordFlight(id: id, usage: FlightUsage(hours: 1, landings: 0), using: &rng)
            #expect(failed.isEmpty)
        }
    }
}

@Suite struct MaintenanceTests {
    @Test func inspectionResetsIntervalAndClearsGrounding() throws {
        var fleet = Fleet()
        let id = try fleet.purchase(.sf1Trainer)
        var rng = SeededGenerator(seed: 5)
        try fleet.recordFlight(id: id, usage: FlightUsage(hours: 100, landings: 0), using: &rng)
        #expect(isGrounded(try #require(fleet.aircraft(id: id)).dispatchStatus))   // tires at 100h, limit 96h

        let before = fleet.wallet.balance
        try fleet.service(id: id, component: .tires, action: .inspection)
        // Tires overhaul is 1% of 180,000 = 1,800; inspection is 8% of that = 144.
        #expect(fleet.wallet.balance == before - Credits(144))
        let status = try #require(fleet.aircraft(id: id)).dispatchStatus
        #expect(!isGrounded(status))
    }

    @Test func overhaulResetsWearAndChargesOverhaulPrice() throws {
        var fleet = Fleet()
        let id = try fleet.purchase(.sf1Trainer)
        var rng = SeededGenerator(seed: 11)
        try fleet.recordFlight(id: id, usage: FlightUsage(hours: 50, landings: 0), using: &rng)
        let before = fleet.wallet.balance
        try fleet.service(id: id, component: .engine, action: .overhaul)
        // Engine overhaul is 22% of 180,000 = 39,600.
        #expect(fleet.wallet.balance == before - Credits(39_600))
        let engine = try #require(fleet.aircraft(id: id)?.components[.engine])
        #expect(engine.wear == 0)
        #expect(engine.hoursSinceService == 0)
        #expect(fleet.aircraft(id: id)?.maintenanceLog.last?.kind == .service(.overhaul))
    }

    @Test func repairClearsDefectAndReducesWear() throws {
        var fleet = Fleet()
        let id = try fleet.purchase(.sf1Trainer, condition: .used(wear: 0.95))
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<30 {
            if let aircraft = fleet.aircraft(id: id), isGrounded(aircraft.dispatchStatus) { break }
            try fleet.recordFlight(id: id, usage: FlightUsage(hours: 1, landings: 1), using: &rng)
        }
        let failed = try #require(fleet.aircraft(id: id)).components.filter { $0.value.defect }.keys
        let component = try #require(failed.first)
        let wearBefore = try #require(fleet.aircraft(id: id)).components[component]?.wear ?? 0
        try fleet.service(id: id, component: component, action: .repair)
        let after = try #require(fleet.aircraft(id: id)).components[component]
        #expect(after?.defect == false)
        #expect(abs((after?.wear ?? 0) - max(0, wearBefore - ServiceAction.repairWearRelief)) < 1e-9)
    }

    @Test func serviceCostsRoundFromNewPrice() {
        let model = AircraftModel.sf1Trainer
        #expect(ServiceAction.overhaul.cost(for: .engine, on: model) == Credits(39_600))
        #expect(ServiceAction.inspection.cost(for: .engine, on: model) == Credits(3_168))
        #expect(ServiceAction.repair.cost(for: .engine, on: model) == Credits(19_800))
    }
}

@Suite struct StorageTests {
    @Test func dailyRentIsChargedAndAdvancesDay() throws {
        var fleet = Fleet(wallet: Wallet(balance: Credits(300_000)))
        _ = try fleet.purchase(.sf1Trainer)
        #expect(fleet.wallet.balance == Credits(120_000))
        fleet.advanceDays(3)
        #expect(fleet.day == 3)
        #expect(fleet.wallet.balance == Credits(120_000 - 75))
    }

    @Test func unaffordableRentDowngradesToTieDown() throws {
        var fleet = Fleet(wallet: Wallet(balance: Credits(180_000)))
        let id = try fleet.purchase(.sf1Trainer, storage: .hangar(.largeHangar))
        #expect(fleet.wallet.balance == Credits(0))
        fleet.advanceDays(1)
        #expect(fleet.aircraft(id: id)?.storage == .tieDown)
        #expect(fleet.aircraft(id: id)?.maintenanceLog.last?.kind == .storage(.tieDown))
    }

    @Test func movingStorageChargesFiveDaysOfNewRent() throws {
        var fleet = Fleet(wallet: Wallet(balance: Credits(300_000)))
        let id = try fleet.purchase(.sf1Trainer)
        try fleet.changeStorage(id: id, to: .hangar(.tHangar))
        // 5 days of T-hangar rent at 120 = 600.
        #expect(fleet.wallet.balance == Credits(120_000 - 600))
        #expect(fleet.aircraft(id: id)?.storage == .hangar(.tHangar))
    }

    @Test func tieDownWeatherWearsAirframeHangarDoesNot() throws {
        var fleet = Fleet(wallet: Wallet(balance: Credits(1_000_000)))
        let outside = try fleet.purchase(.sf1Trainer, storage: .tieDown)
        let sheltered = try fleet.purchase(.sf1Trainer, storage: .hangar(.largeHangar))
        fleet.advanceDays(100)
        let outsideWear = fleet.aircraft(id: outside)?.components[.airframe]?.wear ?? 0
        let shelteredWear = fleet.aircraft(id: sheltered)?.components[.airframe]?.wear ?? 0
        #expect(abs(outsideWear - 100.0 / 2_500) < 1e-9)
        #expect(shelteredWear == 0)
    }
}

@Suite struct SeededGeneratorTests {
    @Test func sameSeedRepeatsSequence() {
        var a = SeededGenerator(seed: 123)
        var b = SeededGenerator(seed: 123)
        for _ in 0..<10 { #expect(a.next() == b.next()) }
    }
}
