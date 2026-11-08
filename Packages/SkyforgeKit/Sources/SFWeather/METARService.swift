// SKYFORGE — Apache-2.0
// Live METAR from the public aviationweather.gov data API (no key, no account). Reports are
// cached for 10 minutes in memory and on disk; when the network fails, the last report is
// returned marked stale, so flight never blocks on weather (§11, airplane mode).
import Foundation
import SFContent

public actor METARService {
    public static let defaultBaseURL = URL(string: "https://aviationweather.gov/api/data/metar")!

    public enum Freshness: Sendable, Equatable {
        case fresh
        case stale(ageSeconds: Double)
    }

    public struct Report: Sendable, Equatable {
        public var metar: METAR
        public var fetchedAt: Date
        public var freshness: Freshness
    }

    public enum ServiceError: Error, Equatable {
        case invalidStation(String)
        case noReport(String)            // station exists in the request but nothing came back
        case unavailable(String)         // network failed and nothing is cached
    }

    private struct Entry: Codable, Sendable, Equatable { var raw: String; var fetchedAt: Date }

    private let transport: any HTTPTransport
    private let cache: KeyedCache?
    private let ttl: TimeInterval
    private let baseURL: URL
    private let now: @Sendable () -> Date
    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<Entry, Error>] = [:]

    public init(transport: any HTTPTransport, cache: KeyedCache? = nil, ttl: TimeInterval = 600,
                baseURL: URL = METARService.defaultBaseURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.cache = cache; self.ttl = ttl; self.baseURL = baseURL; self.now = now
    }

    public static func isValidStation(_ s: String) -> Bool {
        s.count == 4 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    public func requestURL(for station: String) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "ids", value: station), URLQueryItem(name: "format", value: "raw")]
        return c.url!
    }

    public func report(for stationIn: String) async throws -> Report {
        let station = stationIn.uppercased()
        guard Self.isValidStation(station) else { throw ServiceError.invalidStation(stationIn) }
        let t = now()
        var cached = memory[station]
        if cached == nil { cached = await diskEntry(station) }
        if let e = cached, t.timeIntervalSince(e.fetchedAt) < ttl, let m = try? METARParser.parse(e.raw) {
            memory[station] = e
            return Report(metar: m, fetchedAt: e.fetchedAt, freshness: .fresh)
        }
        do {
            let e = try await fetch(station)
            return Report(metar: try METARParser.parse(e.raw), fetchedAt: e.fetchedAt, freshness: .fresh)
        } catch let err as ServiceError {
            // A body without a usable report (e.g. a maintenance page) falls back like a network failure.
            if cached == nil { throw err }
            return try stale(cached, station: station, now: t)
        } catch {
            return try stale(cached, station: station, now: t)
        }
    }

    private func stale(_ e: Entry?, station: String, now t: Date) throws -> Report {
        guard let e, let m = try? METARParser.parse(e.raw) else { throw ServiceError.unavailable(station) }
        return Report(metar: m, fetchedAt: e.fetchedAt, freshness: .stale(ageSeconds: t.timeIntervalSince(e.fetchedAt)))
    }

    /// One request per station at a time; concurrent callers share it.
    private func fetch(_ station: String) async throws -> Entry {
        if let task = inFlight[station] { return try await task.value }
        let url = requestURL(for: station)
        let transport = self.transport
        let stamp = now()
        let task = Task<Entry, Error> {
            let data = try await transport.get(url)
            guard let text = String(data: data, encoding: .utf8),
                  let line = Self.firstReport(in: text, station: station) else { throw ServiceError.noReport(station) }
            _ = try METARParser.parse(line)   // reject garbage before it reaches the cache
            return Entry(raw: line, fetchedAt: stamp)
        }
        inFlight[station] = task
        defer { inFlight[station] = nil }
        let e = try await task.value
        memory[station] = e
        if let cache, let blob = try? JSONEncoder().encode(e) { try? await cache.put("metar/\(station)", blob) }
        return e
    }

    private func diskEntry(_ station: String) async -> Entry? {
        guard let cache, let d = await cache.get("metar/\(station)") else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: d)
    }

    /// The raw API returns one report per line, optionally prefixed by METAR/SPECI.
    static func firstReport(in text: String, station: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            var body = line
            for prefix in ["METAR ", "SPECI "] where body.hasPrefix(prefix) { body = String(body.dropFirst(prefix.count)) }
            if body.hasPrefix(station + " ") { return line }
        }
        return nil
    }
}
