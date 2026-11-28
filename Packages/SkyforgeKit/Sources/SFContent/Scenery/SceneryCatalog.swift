// SKYFORGE — Apache-2.0
// Whole-Earth scenery catalog: the optional, free download that sits beside the base game.
// The catalog lists the segments that can be downloaded (each a Background Assets pack), their sizes,
// hashes and coverage. Pure Swift so it runs and is tested on Linux CI.
import Foundation

/// A latitude/longitude rectangle in degrees. Segments never cross the antimeridian: split them instead.
public struct SceneryBounds: Codable, Sendable, Equatable {
    public var minLat: Double
    public var maxLat: Double
    public var minLon: Double
    public var maxLon: Double

    public init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.minLat = minLat; self.maxLat = maxLat; self.minLon = minLon; self.maxLon = maxLon
    }

    /// True when the bounds lie in the valid degree ranges with a positive extent.
    public var isValid: Bool {
        (-90...90).contains(minLat) && (-90...90).contains(maxLat) && minLat < maxLat &&
        (-180...180).contains(minLon) && (-180...180).contains(maxLon) && minLon < maxLon
    }

    public func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= minLat && latitude <= maxLat && longitude >= minLon && longitude <= maxLon
    }
}

/// One downloadable piece of whole-Earth scenery, delivered as one Background Assets pack.
public struct ScenerySegment: Codable, Sendable, Equatable, Identifiable {
    /// Stable identifier, for example `"eu-west-z6"`. Also the Background Assets pack identifier.
    public var id: String
    /// Size of the downloaded archive in bytes.
    public var bytes: Int64
    /// SHA-256 (lowercase hex) of the whole archive. The app refuses a segment whose hash does not match.
    public var sha256: String
    public var bounds: SceneryBounds

    public init(id: String, bytes: Int64, sha256: String, bounds: SceneryBounds) {
        self.id = id; self.bytes = bytes; self.sha256 = sha256; self.bounds = bounds
    }
}

public enum SceneryCatalogError: Error, Equatable {
    case unsupportedSchema(Int)
    case emptyRelease
    case noSegments
    case duplicateSegment(String)
    case invalidSegmentID(String)
    case nonPositiveSize(String)
    case sizeOutOfRange(String)
    case invalidHash(String)
    case invalidBounds(String)
}

/// The downloadable catalog. Stored as `scenery-catalog.json` on the server and shipped beside the app.
public struct SceneryCatalog: Codable, Sendable, Equatable {
    /// The only schema version this build reads.
    public static let supportedSchema = 1

    public var schema: Int
    /// Release label, for example `"earth-2026.11"`. A new release replaces the installed one.
    public var release: String
    public var segments: [ScenerySegment]
    /// Attribution strings shown in the in-app credits, one per source.
    public var attribution: [String]

    public init(schema: Int = SceneryCatalog.supportedSchema, release: String, segments: [ScenerySegment], attribution: [String]) {
        self.schema = schema; self.release = release; self.segments = segments; self.attribution = attribution
    }

    /// Total size of every segment in the catalog.
    public var totalBytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }

    /// Checks the catalog before any download starts. Throws the first problem found.
    public func validated() throws -> SceneryCatalog {
        guard schema == SceneryCatalog.supportedSchema else { throw SceneryCatalogError.unsupportedSchema(schema) }
        guard !release.trimmingCharacters(in: .whitespaces).isEmpty else { throw SceneryCatalogError.emptyRelease }
        guard !segments.isEmpty else { throw SceneryCatalogError.noSegments }
        var seen = Set<String>()
        for s in segments {
            guard SceneryCatalog.isValidID(s.id) else { throw SceneryCatalogError.invalidSegmentID(s.id) }
            guard seen.insert(s.id).inserted else { throw SceneryCatalogError.duplicateSegment(s.id) }
            guard s.bytes > 0 else { throw SceneryCatalogError.nonPositiveSize(s.id) }
            // A segment above the largest quota can never install, and capping each one keeps the Int64 sums of
            // segment sizes (totalBytes, installer progress) from overflowing on a hostile catalog.
            guard s.bytes <= ScenerySpace.quotaRange.upperBound else { throw SceneryCatalogError.sizeOutOfRange(s.id) }
            guard TilePack.isValidHash(s.sha256) else { throw SceneryCatalogError.invalidHash(s.id) }
            guard s.bounds.isValid else { throw SceneryCatalogError.invalidBounds(s.id) }
        }
        return self
    }

    /// Segment IDs are lowercase letters, digits and hyphens, so they are safe as file and pack names.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d }
    }

    public func segment(id: String) -> ScenerySegment? { segments.first { $0.id == id } }
}
