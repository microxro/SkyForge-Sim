// SKYFORGE — Apache-2.0
// Injectable HTTP transport so networked code is testable offline (tests never hit the live network).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func get(_ url: URL) async throws -> Data
}

public enum TransportError: Error, Equatable {
    case status(Int)
    case offline
    case insecureURL
    case tooLarge
}

public struct URLSessionTransport: HTTPTransport {
    /// Hosts the app may contact, exactly as listed in docs/DATA_SOURCES.md. Any other host is refused.
    public static let allowedHosts: Set<String> = [
        "s3.amazonaws.com",
        "overturemaps-us-west-2.s3.amazonaws.com",
        "esa-worldcover.s3.eu-central-1.amazonaws.com",
        "nz-imagery.s3.ap-southeast-2.amazonaws.com",
        "basemap.nationalmap.gov",
        "tiles.maps.eox.at",
        "aviationweather.gov",
        "api.open-meteo.com",
        "overpass-api.de",
        "davidmegginson.github.io",
    ]
    public let userAgent: String
    /// Largest response body accepted, in bytes.
    public let maxBytes: Int
    /// Per-request timeout in seconds.
    public let timeout: TimeInterval
    public init(userAgent: String = "SKYFORGE/0.1 (+https://github.com/microxro/SkyForge-Sim)",
                maxBytes: Int = 64 * 1024 * 1024, timeout: TimeInterval = 30) {
        self.userAgent = userAgent; self.maxBytes = maxBytes; self.timeout = timeout
    }
    public func get(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw TransportError.insecureURL }
        // Host allow-list: refuse anything not documented in DATA_SOURCES.md (reported as insecureURL).
        guard let host = url.host?.lowercased(), Self.allowedHosts.contains(host) else { throw TransportError.insecureURL }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 4
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw TransportError.status(http.statusCode) }
        guard data.count <= maxBytes else { throw TransportError.tooLarge }
        return data
    }
}

/// Maps string keys (e.g. tile URLs) to content IDs in a ContentStore, persisted as a small JSON index.
public actor KeyedCache {
    public nonisolated let store: ContentStore
    let indexURL: URL
    var index: [String: String]

    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ContentStore(root: root)
        indexURL = root.appendingPathComponent("index.json")
        index = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))) ?? [:]
    }

    /// Returns cached bytes, or nil if missing or corrupted (corrupted entries are dropped).
    public func get(_ key: String) -> Data? {
        guard let hex = index[key], let id = ContentID(hex: hex) else { return nil }
        do { return try store.get(id) } catch {
            index[key] = nil
            persist()
            return nil
        }
    }

    public func put(_ key: String, _ data: Data) throws {
        let id = try store.put(data)
        index[key] = id.hex
        persist()
    }

    func persist() {
        if let d = try? JSONEncoder().encode(index) { try? d.write(to: indexURL, options: .atomic) }
    }
}
