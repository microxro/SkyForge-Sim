import Testing
import Foundation
@testable import SFCareer

@Suite struct BushFlyingTests {
    private static let sfa = Economy.spec("org.skyforge.sfa")!     // paved only, 400 m minimum runway
    private static let sfc = Economy.spec("org.skyforge.sfc")!     // unpaved rated, 600 m minimum runway
    private static let sf1 = Economy.spec("org.skyforge.sf1")!     // single seat

    /// The rejection a Result carries, or nil on success. (Result<Void, _> is not Equatable, so compare this instead.)
    private static func rejection(_ r: Result<Void, BushRejection>) -> BushRejection? {
        if case .failure(let e) = r { return e }
        return nil
    }

    private static func contract(to strip: BushStrip, passengers: Int = 0, cargoKg: Double = 200,
                                 basePay: Int = 1_000, risk: Double = 0.5, minLevel: Int = 1) -> BushContract {
        BushContract(id: "t-\(strip.id)", kind: passengers > 0 ? .passenger : .cargo,
                     origin: BushStripCatalog.hub, destination: strip, distanceKm: 40,
                     passengers: passengers, cargoKg: cargoKg, deadlineMinutes: 60, basePay: basePay,
                     weatherRisk: risk, minLevel: minLevel, expiresDay: 3)
    }

    private static func landing(at strip: BushStrip, contractID: String, kind: FlightKind? = nil, past: Double? = 100,
                                maxG: Double = 1.1, minG: Double = 0.9) -> FlightReport {
        FlightReport(kind: kind ?? .bush(contractID: contractID), aircraftID: "org.skyforge.sfc",
                     departureICAO: BushStripCatalog.hub.id, arrivalICAO: strip.id, durationS: 1_800, distanceM: 40_000,
                     landed: true, crashed: false, touchdownSinkFPM: 100, touchdownDistancePastThresholdM: past,
                     maxG: maxG, minG: minG, maxBankDeg: 20, fuelUsedKg: 30, endedAt: 1)
    }

    @Test func boardIsDeterministicAndAlwaysRunsThroughTheHub() {
        let a = BushBoard.generate(dayIndex: 42, playerLevel: 8)
        let b = BushBoard.generate(dayIndex: 42, playerLevel: 8)
        #expect(a == b)
        #expect(a.count == 6)
        for c in a {
            #expect(c.origin.id == BushStripCatalog.hub.id || c.destination.id == BushStripCatalog.hub.id)
            #expect((0...1).contains(c.weatherRisk))
            #expect(c.basePay >= 150)
        }
    }

    @Test func pilotsWithoutAnUnpavedRatingAreTurnedAwayFromGrassAndMud() {
        let c = Self.contract(to: BushStripCatalog.strip(id: "BSH02")!, cargoKg: 0)     // grass
        #expect(Self.rejection(BushRules.canFly(c, with: Self.sfa, level: 10)) == .unpavedNotRated)
    }

    @Test func stripLengthIsJudgedAgainstSurface() {
        // SF-1 needs 450 m on paved, which becomes 562 m on grass. Moose Creek is only 480 m.
        let c = Self.contract(to: BushStripCatalog.strip(id: "BSH02")!, cargoKg: 0)
        #expect(Self.rejection(BushRules.canFly(c, with: Self.sf1, level: 10)) == .stripTooShort)
        // SF-C can take Spruce Bend (900 m gravel, needs 690 m).
        let ok = Self.contract(to: BushStripCatalog.strip(id: "BSH04")!)
        #expect(Self.rejection(BushRules.canFly(ok, with: Self.sfc, level: 10)) == nil)
    }

    @Test func passengersNeedSeatsAndLevelIsChecked() {
        let pax = Self.contract(to: BushStripCatalog.strip(id: "BSH04")!, passengers: 2, cargoKg: 0)
        #expect(Self.rejection(BushRules.canFly(pax, with: Self.sf1, level: 10)) == .notEnoughSeats)
        let high = Self.contract(to: BushStripCatalog.strip(id: "BSH04")!, minLevel: 9)
        #expect(Self.rejection(BushRules.canFly(high, with: Self.sfc, level: 4)) == .levelTooLow(needed: 9))
    }

    @Test func oneContractAtATimeIsEnforcedOnTheCareer() {
        var state = CareerState()
        let c = Self.contract(to: BushStripCatalog.strip(id: "BSH04")!)
        #expect(Self.rejection(state.accept(bush: c, aircraft: Self.sfc)) == nil)
        #expect(state.activeBushContract == c)
        #expect(Self.rejection(state.accept(bush: c, aircraft: Self.sfc)) == .alreadyHaveContract)
    }

    @Test func goodDeliverySettlesWithoutPenalties() {
        let strip = BushStripCatalog.strip(id: "BSH01")!
        let c = Self.contract(to: strip, basePay: 1_000, risk: 0.5)
        let s = BushSettler.settle(contract: c, report: Self.landing(at: strip, contractID: c.id), owned: true)
        #expect(s.success)
        #expect(s.payout == 1_000)
        #expect(s.onTimeBonus == 150)
        #expect(s.damagePenalty == 0)
    }

    @Test func roughRideOnARiskyRouteCostsPartOfThePay() {
        let strip = BushStripCatalog.strip(id: "BSH01")!
        let c = Self.contract(to: strip, basePay: 1_000, risk: 0.5)
        let s = BushSettler.settle(contract: c, report: Self.landing(at: strip, contractID: c.id, maxG: 2.0), owned: true)
        #expect(s.success)
        #expect(s.damagePenalty == 100)     // 1000 * 0.2 * 0.5
    }

    @Test func firstLandingAtAStripPaysDiscoveriesOnlyOnce() {
        let strip = BushStripCatalog.strip(id: "BSH05")!     // grass, 85% remote, 390 m
        let first = BushExploration.discoveries(for: Self.landing(at: strip, contractID: "x", past: 100), known: [])
        #expect(Set(first.map(\.id)) == ["landing:BSH05", "unpaved", "deep-bush", "short-field"])
        let again = BushExploration.discoveries(for: Self.landing(at: strip, contractID: "x", past: 100), known: Set(first.map(\.id)))
        #expect(again.isEmpty)
    }

    @Test func crashesAndLandingsAtOtherAirportsDiscoverNothing() {
        var crashed = Self.landing(at: BushStripCatalog.strip(id: "BSH05")!, contractID: "x")
        crashed.crashed = true
        #expect(BushExploration.discoveries(for: crashed, known: []).isEmpty)
        let kmry = FlightReport(aircraftID: "org.skyforge.sfc", departureICAO: "KMRY", arrivalICAO: "KMRY", durationS: 900,
                                landed: true, touchdownSinkFPM: 90)
        #expect(BushExploration.discoveries(for: kmry, known: []).isEmpty)
    }

    @Test func completedContractPaysAndClearsTheSlot() {
        var state = CareerState()
        let strip = BushStripCatalog.strip(id: "BSH01")!
        let c = Self.contract(to: strip)
        state.activeBushContract = c
        let report = Self.landing(at: strip, contractID: c.id)
        let out = CareerEngine.apply(report, to: &state)
        #expect(state.activeBushContract == nil)
        #expect(state.stats.jobsCompleted == 1)
        #expect(out.settlement?.success == true)
        #expect(state.bushDiscoveries.contains("landing:BSH01"))
        #expect(out.bushDiscoveries.map(\.id).contains("landing:BSH01"))
    }

    @Test func bushStateSurvivesSaveAndSanitises() throws {
        var state = CareerState()
        state.activeBushContract = Self.contract(to: BushStripCatalog.strip(id: "BSH03")!)
        state.bushDiscoveries = ["landing:BSH03", "unpaved"]
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(CareerState.self, from: data)
        #expect(back.activeBushContract == state.activeBushContract)
        #expect(back.bushDiscoveries == state.bushDiscoveries)
    }

    @Test func oldSavesWithoutBushFieldsStillLoad() throws {
        let legacy = #"{"version":1,"pilotName":"Old","xp":10,"credits":500}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(CareerState.self, from: legacy)
        #expect(state.activeBushContract == nil)
        #expect(state.bushDiscoveries.isEmpty)
        #expect(state.pilotName == "Old")
    }
}
