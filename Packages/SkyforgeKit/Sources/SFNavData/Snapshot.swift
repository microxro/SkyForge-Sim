// SKYFORGE — Apache-2.0
// Bundled OurAirports snapshot (zlib-compressed CSV, decoded with the pure-Swift inflater) and a
// validated, atomic "Update airport database" path with an injectable transport.
import Foundation
import SFTerrainCore
import SFContent

public struct SnapshotManifest: Codable, Sendable, Equatable {
    public struct FileInfo: Codable, Sendable, Equatable {
        public var rows: Int
        public var rawBytes: Int
        public var compressedBytes: Int
    }
    public var source: String
    public var built: String
    public var files: [String: FileInfo]
}

public enum SnapshotError: Error, Equatable {
    case missingResource(String)
    case decode(String)
    case validation(String)
    case transport(String)
}

public enum BundledNavData {
    static func resourceURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: nil)
    }

    public static func manifest() throws -> SnapshotManifest {
        guard let u = resourceURL("manifest.json") else { throw SnapshotError.missingResource("manifest.json") }
        return try JSONDecoder().decode(SnapshotManifest.self, from: Data(contentsOf: u))
    }

    /// Inflates one bundled CSV (zlib integrity is checked by its Adler-32 trailer).
    public static func csv(_ name: String) throws -> String {
        guard let u = resourceURL("\(name).csv.z") else { throw SnapshotError.missingResource("\(name).csv.z") }
        do {
            let raw = try Inflate.zlib([UInt8](Data(contentsOf: u)))
            return String(decoding: raw, as: UTF8.self)
        } catch {
            throw SnapshotError.decode("\(name): \(error)")
        }
    }

    /// Loads the full offline database from the app bundle.
    public static func load() throws -> NavDatabase {
        NavDatabase(airportsCSV: try csv("airports"), runwaysCSV: try csv("runways"), navaidsCSV: try csv("navaids"))
    }
}

public struct AirportDatabaseUpdater: Sendable {
    public let transport: any HTTPTransport
    public let baseline: SnapshotManifest
    public init(transport: any HTTPTransport, baseline: SnapshotManifest) { self.transport = transport; self.baseline = baseline }

    /// Downloads airports/runways/navaids, validates them (parse success, row counts within ±20 % of the
    /// baseline after the same filtering, size sanity) and writes them atomically into `directory`.
    public func update(into directory: URL) async throws -> NavDatabase {
        var texts: [String: String] = [:]
        for name in ["airports", "runways", "navaids"] {
            guard let url = URL(string: NavDatabase.ourAirportsURL(name)) else { throw SnapshotError.transport("bad URL") }
            let data = try await transport.get(url)
            guard data.count > 1_000 else { throw SnapshotError.validation("\(name): only \(data.count) bytes") }
            texts[name] = String(decoding: data, as: UTF8.self)
        }
        let db = NavDatabase(airportsCSV: texts["airports"] ?? "", runwaysCSV: texts["runways"] ?? "", navaidsCSV: texts["navaids"] ?? "")
        let counts = [
            "airports": db.airports.values.filter { !["closed", "heliport", "balloonport"].contains($0.type) }.count,
            "runways": db.runwaysByAirport.values.reduce(0) { $0 + $1.filter { !$0.closed }.count },
            "navaids": db.navaids.count,
        ]
        for (name, n) in counts {
            guard let expected = baseline.files[name]?.rows, expected > 0 else { continue }
            let ratio = Double(n) / Double(expected)
            guard ratio > 0.8 && ratio < 1.2 else {
                throw SnapshotError.validation("\(name): \(n) rows vs baseline \(expected) (outside ±20 %)")
            }
        }
        // Atomic install: write to a temporary directory, then swap.
        let fm = FileManager.default
        let tmp = directory.deletingLastPathComponent().appendingPathComponent(".airports-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (name, text) in texts { try Data(text.utf8).write(to: tmp.appendingPathComponent("\(name).csv")) }
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: tmp, to: directory)
        return db
    }
}
