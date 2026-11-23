import Testing
import Foundation
import SFFlightModel
@testable import SFTraffic

private func profileRunway(length: Double, threshold: SIMD2<Double> = SIMD2(0, 0)) -> TrafficRunway {
    TrafficRunway(threshold: threshold, heading: 0, length: length, elevation: 0)
}

@Suite struct TrafficProfileTests {

    @Test func runwayLengthSetsTheFieldClass() {
        #expect(TrafficProfile(runway: profileRunway(length: 3_000)).fieldClass == .busy)
        #expect(TrafficProfile(runway: profileRunway(length: 1_800)).fieldClass == .medium)
        #expect(TrafficProfile(runway: profileRunway(length: 800)).fieldClass == .quiet)
    }

    @Test func busierFieldsHaveMoreAircraftAndMoreFrequentMovements() {
        let busy = TrafficProfile(runway: profileRunway(length: 3_000))
        let medium = TrafficProfile(runway: profileRunway(length: 1_800))
        let quiet = TrafficProfile(runway: profileRunway(length: 800))
        #expect(busy.schedule.maxAircraft > medium.schedule.maxAircraft)
        #expect(medium.schedule.maxAircraft > quiet.schedule.maxAircraft)
        #expect(busy.schedule.meanArrivalInterval < medium.schedule.meanArrivalInterval)
        #expect(quiet.schedule.meanArrivalInterval > medium.schedule.meanArrivalInterval)
    }

    @Test func quietFieldsFlyOnlyTheLightTypes() {
        let quiet = TrafficProfile(runway: profileRunway(length: 800))
        #expect(!quiet.fleet.isEmpty)
        #expect(!quiet.fleet.contains(AircraftConfig.sf3Twin))
        #expect(!quiet.fleet.contains(AircraftConfig.sf5Jet))
    }

    @Test func everyFieldHasItsOwnSeedAndTheSameFieldAlwaysGetsTheSame() {
        let here = TrafficProfile(runway: profileRunway(length: 2_000, threshold: SIMD2(100, 200)))
        let there = TrafficProfile(runway: profileRunway(length: 2_000, threshold: SIMD2(5_000, -300)))
        let again = TrafficProfile(runway: profileRunway(length: 2_000, threshold: SIMD2(100, 200)))
        #expect(here.seed != there.seed)
        #expect(here.seed == again.seed)
        #expect(here.seed != 0)
    }

    @Test func aNonFiniteThresholdStillGivesANonZeroSeed() {
        let profile = TrafficProfile(runway: profileRunway(length: 2_000, threshold: SIMD2(.nan, .infinity)))
        #expect(profile.seed != 0)
    }

    @Test func everyFieldGetsArrivalsAndDeparturesWithinAMinute() {
        for length in [800.0, 1_800.0, 3_000.0] {
            let runway = profileRunway(length: length)
            let profile = TrafficProfile(runway: runway)
            var system = TrafficSystem(runway: runway, seed: profile.seed, schedule: profile.schedule, fleet: profile.fleet)
            // Sixty seconds at half-second steps. The first arrival is due at 20 s and the first departure at 45 s.
            for _ in 0..<120 { system.step(dt: 0.5) }
            #expect(system.aircraft.contains { $0.kind == .arrival }, "no arrival at a \(length) m field")
            #expect(system.aircraft.contains { $0.kind == .departure }, "no departure at a \(length) m field")
        }
    }
}
