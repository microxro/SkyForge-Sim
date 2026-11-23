import Testing
import Foundation
@testable import SFCareer

@Suite struct LogbookTests {
    private func flight(aircraft: String = "org.skyforge.sf1", from: String = "KSFO", to: String? = "KOAK",
                        seconds: Double = 600, landed: Bool = true, crashed: Bool = false) -> FlightReport {
        FlightReport(aircraftID: aircraft, departureICAO: from, arrivalICAO: to, durationS: seconds, distanceM: 20_000,
                     landed: landed, crashed: crashed)
    }

    @Test func recordsTotalsPerAircraft() {
        var book = Logbook()
        book.record(flight(seconds: 600))
        book.record(flight(aircraft: "org.skyforge.sf3", seconds: 300))
        #expect(book.aircraft["org.skyforge.sf1"]?.flights == 1)
        #expect(book.aircraft["org.skyforge.sf1"]?.seconds == 600)
        #expect(book.aircraft["org.skyforge.sf3"]?.seconds == 300)
        #expect(book.totalFlights == 2)
        #expect(book.totalSeconds == 900)
    }

    @Test func countsLandingsAndCrashesSeparately() {
        var book = Logbook()
        book.record(flight(landed: true))
        book.record(flight(landed: false, crashed: true))
        let totals = book.aircraft["org.skyforge.sf1"]
        #expect(totals?.flights == 2)
        #expect(totals?.landings == 1)
        #expect(totals?.crashes == 1)
    }

    @Test func airportVisitsCountOncePerFlight() {
        var book = Logbook()
        book.record(flight(from: "KSFO", to: "KSFO"))   // departs and lands at the same field: one visit
        book.record(flight(from: "KSFO", to: "KOAK"))
        book.record(flight(from: "KOAK", to: nil))      // no runway arrival: only the departure counts
        #expect(book.airportVisits["KSFO"] == 2)
        #expect(book.airportVisits["KOAK"] == 2)
    }

    @Test func badDurationsCountAsZero() {
        var book = Logbook()
        book.record(flight(seconds: .nan))
        book.record(flight(seconds: -50))
        #expect(book.aircraft["org.skyforge.sf1"]?.flights == 2)
        #expect(book.aircraft["org.skyforge.sf1"]?.seconds == 0)
    }

    @Test func storeStartsEmptyRecordsAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = LogbookStore(url: dir.appendingPathComponent("logbook.json"))
        let empty = try store.load()
        #expect(empty == Logbook())
        #expect(store.record(flight(seconds: 120)))
        #expect(store.record(flight(seconds: 60)))
        let saved = try store.load()
        #expect(saved.aircraft["org.skyforge.sf1"]?.seconds == 180)
        #expect(saved.totalFlights == 2)
        try? FileManager.default.removeItem(at: dir)
    }
}
