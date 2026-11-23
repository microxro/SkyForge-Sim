// SKYFORGE — Apache-2.0
// The logbook tab: hours, landings and crashes per aircraft, and visits per airport. The totals come from
// SFCareer's Logbook; this view only presents them.
#if canImport(SwiftUI)
import SwiftUI
import SFCareer

struct LogbookView: View {
    let logbook: Logbook

    var body: some View {
        List {
            Section("Totals") {
                stat("Flights", "\(logbook.totalFlights)")
                stat("Hours flown", String(format: "%.1f", logbook.totalSeconds / 3600))
            }
            Section("Aircraft") {
                if logbook.aircraft.isEmpty {
                    Text("No flights logged yet.").foregroundStyle(.secondary)
                }
                ForEach(aircraftRows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.headline)
                        Text("\(row.totals.flights) flights · \(String(format: "%.1f", row.totals.seconds / 3600)) h · "
                             + "\(row.totals.landings) landings · \(row.totals.crashes) crashes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Airports") {
                if logbook.airportVisits.isEmpty {
                    Text("No airports visited yet.").foregroundStyle(.secondary)
                }
                ForEach(airportRows, id: \.icao) { row in
                    stat(row.icao, "\(row.visits) visits")
                }
            }
        }
    }

    /// Aircraft flown, most hours first.
    private var aircraftRows: [AircraftRow] {
        logbook.aircraft
            .map { id, totals in AircraftRow(id: id, name: Self.name(for: id), totals: totals) }
            .sorted { $0.totals.seconds > $1.totals.seconds }
    }

    /// Airports visited, most visits first, then by code.
    private var airportRows: [AirportRow] {
        logbook.airportVisits
            .map { AirportRow(icao: $0.key, visits: $0.value) }
            .sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.icao < $1.icao }
    }

    /// The aircraft's display name, or its id if the hangar does not list it.
    static func name(for id: String) -> String {
        Economy.catalog.first { $0.id == id }?.name ?? id
    }

    private func stat(_ key: String, _ value: String) -> some View {
        HStack { Text(key); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }
    }
}

private struct AircraftRow {
    let id: String
    let name: String
    let totals: AircraftLogTotals
}

private struct AirportRow {
    let icao: String
    let visits: Int
}
#endif
