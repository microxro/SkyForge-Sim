// SKYFORGE — Apache-2.0
// Offline tile packs: a recorded set of HTTP responses (imagery, elevation, map data) keyed by URL,
// stored content-addressed with a SHA-256 manifest. `TilePackTransport` serves pack hits first and
// falls back to another transport, so bundled showcase airports fly offline and stream elsewhere.
import Foundation

/// Manifest of a pack directory: URL → SHA-256 of the body (the file name in the pack).
public struct TilePackManifest: Codable, Sendable, Equatable {
    public var name: String
    public var files: [String: String]
    public var attribution: [String]
    public init(name: String, files: [String: String], attribution: [String]) {
        self.name = name; self.files = files; self.attribution = attribution
    }
}

public enum TilePackError: Error, Equatable { case missingManifest, corrupt(String) }

/// A read-only pack on disk (`manifest.json` plus one file per distinct body, named by its hash).
public struct TilePack: Sendable {
    public let root: URL
    public let manifest: TilePackManifest

    public init(root: URL) throws {
        self.root = root
        guard let d = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) else { throw TilePackError.missingManifest }
        manifest = try JSONDecoder().decode(TilePackManifest.self, from: d)
    }

    /// Body for a URL, verified against its hash; nil when the pack does not hold it.
    public func data(for url: URL) throws -> Data? {
        guard let hex = manifest.files[url.absoluteString] else { return nil }
        let d = try Data(contentsOf: root.appendingPathComponent(hex))
        guard ContentID(data: d).hex == hex else { throw TilePackError.corrupt(url.absoluteString) }
        return d
    }

    /// Writes a pack (bodies deduplicated by hash). Overwrites an existing manifest, or with `merge`
    /// adds to it (a pack recorded at several detail tiers holds the tiles of all of them).
    public static func write(name: String, responses: [URL: Data], attribution: [String], to root: URL, merge: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files: [String: String] = [:]
        var attribution = attribution
        if merge, let old = try? TilePack(root: root) {
            files = old.manifest.files
            for a in old.manifest.attribution where !attribution.contains(a) { attribution.append(a) }
        }
        for (url, body) in responses {
            let hex = ContentID(data: body).hex
            let f = root.appendingPathComponent(hex)
            if !FileManager.default.fileExists(atPath: f.path) { try body.write(to: f, options: .atomic) }
            files[url.absoluteString] = hex
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(TilePackManifest(name: name, files: files, attribution: attribution))
            .write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

/// Serves URLs from packs, otherwise asks `fallback` (nil fallback = offline: pack misses throw).
public struct TilePackTransport: HTTPTransport {
    public let packs: [TilePack]
    public let fallback: (any HTTPTransport)?
    public init(packs: [TilePack], fallback: (any HTTPTransport)?) { self.packs = packs; self.fallback = fallback }

    public func get(_ url: URL) async throws -> Data {
        for p in packs { if let d = try p.data(for: url) { return d } }
        guard let fallback else { throw TransportError.offline }
        return try await fallback.get(url)
    }
}

/// Records every successful response of the wrapped transport (used by the pack builder).
public actor RecordingTransport: HTTPTransport {
    let base: any HTTPTransport
    public private(set) var responses: [URL: Data] = [:]
    public init(_ base: any HTTPTransport) { self.base = base }
    public func get(_ url: URL) async throws -> Data {
        let d = try await base.get(url)
        responses[url] = d
        return d
    }
}
