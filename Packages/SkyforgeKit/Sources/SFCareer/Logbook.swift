// SKYFORGE — Apache-2.0
// The pilot's logbook: hours, landings and visits per aircraft and per airport. It consumes the same FlightReport
// as the career but lives in its own file, so the career save, its unlocks and its economy never change.
import Foundation

public struct AircraftLogTotals: Codable, Sendable, Equatable {
    public var flights = 0
    public var seconds = 0.0
    public var distanceM = 0.0
    public var landings = 0
    public var crashes = 0
    public init() {}
}

public struct Logbook: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = Logbook.currentVersion
    /// Totals keyed by aircraft id.
    public var aircraft: [String: AircraftLogTotals] = [:]
    /// Flights that departed from or landed at each airport, counted once per flight.
    public var airportVisits: [String: Int] = [:]
    /// Search and rescue missions completed successfully (a casualty found, reached or brought home).
    public var rescues = 0

    /// Mission ids that count as rescues in the logbook. Kept as strings, like the career campaigns.
    public static let rescueMissionIDs: Set<String> = ["sar-grid-search", "sar-medevac-strip", "sar-two-survivors"]

    public init() {}

    /// Hand-written so logbooks saved before `rescues` existed still load instead of being refused.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Logbook.currentVersion
        aircraft = try c.decodeIfPresent([String: AircraftLogTotals].self, forKey: .aircraft) ?? [:]
        airportVisits = try c.decodeIfPresent([String: Int].self, forKey: .airportVisits) ?? [:]
        rescues = try c.decodeIfPresent(Int.self, forKey: .rescues) ?? 0
    }

    public var totalFlights: Int { aircraft.values.reduce(0) { $0 + $1.flights } }
    public var totalSeconds: Double { aircraft.values.reduce(0) { $0 + $1.seconds } }

    /// Adds one finished flight. Non-finite or negative durations and distances count as zero.
    public mutating func record(_ report: FlightReport) {
        var totals = aircraft[report.aircraftID] ?? AircraftLogTotals()
        totals.flights += 1
        totals.seconds += Self.nonNegative(report.durationS)
        totals.distanceM += Self.nonNegative(report.distanceM)
        if report.landed { totals.landings += 1 }
        if report.crashed { totals.crashes += 1 }
        aircraft[report.aircraftID] = totals

        var airports = Set<String>()
        if !report.departureICAO.isEmpty { airports.insert(report.departureICAO) }
        if let arrival = report.arrivalICAO, !arrival.isEmpty { airports.insert(arrival) }
        for icao in airports { airportVisits[icao, default: 0] += 1 }

        if case .mission(let missionID) = report.kind, report.missionSuccess, Self.rescueMissionIDs.contains(missionID) {
            rescues += 1
        }
    }

    static func nonNegative(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}

/// The logbook file in Application Support, next to the career save.
public struct LogbookStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Skyforge", isDirectory: true).appendingPathComponent("logbook.json")
    }

    /// The saved logbook, or an empty one if no file exists yet. Throws if the file exists but cannot be read.
    public func load() throws -> Logbook {
        guard FileManager.default.fileExists(atPath: url.path) else { return Logbook() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Logbook.self, from: data)
    }

    /// Adds one flight and writes the logbook back atomically. Returns false if the file could not be read or
    /// written; an unreadable logbook is never overwritten.
    @discardableResult
    public func record(_ report: FlightReport) -> Bool {
        guard var book = try? load() else { return false }
        book.record(report)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(book).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
