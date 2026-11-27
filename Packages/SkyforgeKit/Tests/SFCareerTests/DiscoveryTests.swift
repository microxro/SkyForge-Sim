import Testing
import Foundation
@testable import SFCareer

@Suite struct DiscoveryTests {
    @Test func catalogIdsAreUniqueAndWellFormed() {
        let ids = Discoveries.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for d in Discoveries.all {
            #expect(CareerState.validID(d.id))
            #expect((-90...90).contains(d.latitudeDeg) && (-180...180).contains(d.longitudeDeg))
            #expect(d.radiusKm > 0 && d.radiusKm <= 100)
            #expect(d.xp > 0)
        }
    }

    @Test func spotsFoundOnlyInsideRadius() {
        let gg = Discoveries.all.first { $0.id == "golden-gate" }!
        #expect(Discoveries.spots(nearLatitude: gg.latitudeDeg, longitude: gg.longitudeDeg).contains { $0.id == "golden-gate" })
        // Mid-Pacific is nowhere near any catalogue spot.
        #expect(Discoveries.spots(nearLatitude: 0, longitude: -150).isEmpty)
        #expect(Discoveries.spots(nearLatitude: .nan, longitude: 0).isEmpty)
        #expect(Discoveries.spots(nearLatitude: 0, longitude: 400).isEmpty)
    }

    @Test func haversineKnownDistance() {
        // London to Paris is roughly 344 km.
        let d = Discoveries.distanceKm(lat1: 51.5074, lon1: -0.1278, lat2: 48.8566, lon2: 2.3522)
        #expect(abs(d - 344) < 3)
        #expect(Discoveries.distanceKm(lat1: 10, lon1: 10, lat2: 10, lon2: 10) == 0)
    }

    @Test func newIDsSkipsKnownDuplicatesUnknownAndCaps() {
        let reached = ["golden-gate", "golden-gate", "not-a-spot", "eiffel-tower", "big-ben"]
        #expect(Discoveries.newIDs(reached: reached, known: ["big-ben"]) == ["golden-gate", "eiffel-tower"])
        let many = Discoveries.all.map(\.id)
        #expect(Discoveries.newIDs(reached: many, known: []).count == Discoveries.maxAwardsPerFlight)
    }

    @Test func discoveryPaysOnceAndFeedsAchievements() {
        var s = CareerState()
        let xpBefore = s.xp
        let first = CareerEngine.apply(FlightReport(aircraftID: "org.skyforge.sf1", durationS: 60),
                                       to: &s, discoveriesReached: ["golden-gate"])
        #expect(first.newDiscoveries == ["golden-gate"])
        #expect(s.xp - xpBefore >= 150)
        #expect(s.stats.discoveries == ["golden-gate"])

        let second = CareerEngine.apply(FlightReport(aircraftID: "org.skyforge.sf1", durationS: 60),
                                        to: &s, discoveriesReached: ["golden-gate"])
        #expect(second.newDiscoveries.isEmpty)
        #expect(s.stats.discoveries.count == 1)
    }

    @Test func savedDiscoveriesSurviveTamperedIds() throws {
        var st = CareerStats()
        st.discoveries = ["golden-gate", "bogus-id"]
        st.sanitize()
        #expect(st.discoveries == ["golden-gate"])
    }

    @Test func achievementIdsAreUniqueAndCountIsLarge() {
        let ids = AchievementCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count >= 120)
    }

    @Test func tieredAchievementUnlocksAtThreshold() {
        var st = CareerStats()
        st.flights = 4
        let five = AchievementCatalog.all.first { $0.id == "flights-5" }!
        #expect(!five.isUnlocked(st))
        st.flights = 5
        #expect(five.isUnlocked(st))
    }
}
