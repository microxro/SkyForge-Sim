// SKYFORGE — Apache-2.0
// The airline career is reached from a flight: accepting a leg makes it the active job, and applying the
// flown report pays the job and updates the airline record. Covers the path the UI uses.
import Testing
import Foundation
@testable import SFCareer

private let wHub = AirportRef(icao: "KMRY", name: "Monterey", latitudeDeg: 36.587, longitudeDeg: -121.843, longestRunwayM: 2_100)
private let wSFO = AirportRef(icao: "KSFO", name: "San Francisco", latitudeDeg: 37.619, longitudeDeg: -122.375, longestRunwayM: 3_600)

private func wRoute() -> AirlineRoute {
    AirlineRoute(id: "KMRY-1-0", origin: wHub, destination: wSFO, distanceKm: 115, departureMinute: 540,
                 passengers: 1, minimumRank: .cadet, expiresDay: 2)
}

/// A clean, on-time leg from KMRY to KSFO on the scheduled route.
private func wLeg(durationMin: Double = 40) -> FlightReport {
    FlightReport(kind: .job(jobID: "KMRY-1-0"), aircraftID: "org.skyforge.sfc", departureICAO: "KMRY", arrivalICAO: "KSFO",
                 durationS: durationMin * 60, distanceM: 115_000, landed: true, touchdownSinkFPM: 90, touchdownOffsetM: 0,
                 maxG: 1.1, minG: 0.9, maxBankDeg: 15, fuelUsedKg: 10)
}

@Suite("Airline career wiring")
struct AirlineWiringTests {
    @Test func flownLegPaysAndUpdatesTheAirlineRecord() {
        var s = CareerState()
        let sfc = Economy.spec("org.skyforge.sfc")!
        s.ownedAircraft.insert(sfc.id)
        let before = s.credits
        if case .failure(let e) = s.accept(airline: wRoute(), aircraft: sfc, pilotRank: .legend) {
            Issue.record("leg should be accepted, got \(e)")
        }
        #expect(s.activeAirlineRoute?.id == "KMRY-1-0")
        #expect(s.activeJob?.id == "KMRY-1-0")

        _ = CareerEngine.apply(wLeg(), to: &s)

        #expect(s.airline.legsFlown == 1)
        #expect(s.airline.legsOnTime == 1)
        #expect(s.completedJobIDs.contains("KMRY-1-0"))
        #expect(s.activeAirlineRoute == nil)
        #expect(s.activeJob == nil)
        #expect(s.credits > before)
    }

    @Test func secondLegCannotStartWhileOneIsActive() {
        var s = CareerState()
        let sfc = Economy.spec("org.skyforge.sfc")!
        s.ownedAircraft.insert(sfc.id)
        _ = s.accept(airline: wRoute(), aircraft: sfc, pilotRank: .legend)
        if case .failure(let e) = s.accept(airline: wRoute(), aircraft: sfc, pilotRank: .legend) {
            #expect(e == .jobInProgress)
        } else {
            Issue.record("a second leg should be rejected while one is active")
        }
    }

    @Test func crashedLegRecordsNoLegAndDropsTheRoute() {
        var s = CareerState()
        let sfc = Economy.spec("org.skyforge.sfc")!
        s.ownedAircraft.insert(sfc.id)
        _ = s.accept(airline: wRoute(), aircraft: sfc, pilotRank: .legend)
        var crashed = wLeg()
        crashed.crashed = true
        crashed.landed = false
        _ = CareerEngine.apply(crashed, to: &s)
        #expect(s.airline.legsFlown == 0)
        #expect(s.airline.reputation < 50)
        #expect(s.activeAirlineRoute == nil)
    }
}

@Suite("Airline route menu")
struct AirlineRouteMenuTests {
    @Test func todaysLegsLeaveTheHubAndRepeatForTheSameDay() {
        for rank in AirlineRank.allCases {
            var s = CareerState()
            s.airline.rank = rank
            let legs = AirlineNetwork.schedule(for: s, dayIndex: 20_000)
            #expect(legs.count <= 6)
            for leg in legs {
                #expect(leg.origin.icao == AirlineNetwork.hub.icao)
                #expect(leg.destination.icao != AirlineNetwork.hub.icao)
            }
            #expect(legs == AirlineNetwork.schedule(for: s, dayIndex: 20_000))
        }
    }
}
