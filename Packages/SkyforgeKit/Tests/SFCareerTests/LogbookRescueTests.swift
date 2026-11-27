import Testing
import Foundation
@testable import SFCareer

@Suite struct LogbookRescueTests {
    private func mission(_ id: String, success: Bool) -> FlightReport {
        FlightReport.fromMission(id: id, aircraftID: "org.skyforge.sf1", success: success, score: 1_000,
                                 elapsed: 600, kills: 0, crashed: false, endedAt: 0)
    }

    @Test func aCompletedRescueMissionCountsAsARescue() {
        var book = Logbook()
        book.record(mission("sar-grid-search", success: true))
        book.record(mission("sar-two-survivors", success: true))
        #expect(book.rescues == 2)
        #expect(book.totalFlights == 2)
    }

    @Test func aFailedRescueOrAnOtherMissionDoesNotCount() {
        var book = Logbook()
        book.record(mission("sar-medevac-strip", success: false))
        book.record(mission("rescue-pickup", success: true))
        #expect(book.rescues == 0)
        #expect(book.totalFlights == 2)
    }

    @Test func aLogbookSavedBeforeRescuesExistedStillLoads() throws {
        let legacy = Data(#"{"version":1,"aircraft":{"org.skyforge.sf1":{"flights":3,"seconds":900,"distanceM":0,"landings":2,"crashes":0}},"airportVisits":{"KSFO":3}}"#.utf8)
        let book = try JSONDecoder().decode(Logbook.self, from: legacy)
        #expect(book.rescues == 0)
        #expect(book.totalFlights == 3)
        #expect(book.airportVisits["KSFO"] == 3)
    }

    @Test func rescuesSurviveARoundTrip() throws {
        var book = Logbook()
        book.record(mission("sar-medevac-strip", success: true))
        let data = try JSONEncoder().encode(book)
        let back = try JSONDecoder().decode(Logbook.self, from: data)
        #expect(back.rescues == 1)
    }
}
