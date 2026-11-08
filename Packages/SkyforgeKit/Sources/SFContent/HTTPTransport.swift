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
}

public struct URLSessionTransport: HTTPTransport {
    public let userAgent: String
    public init(userAgent: String = "SKYFORGE/0.1 (+https://github.com/microxro/SkyForge-Sim)") { self.userAgent = userAgent }
    public func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw TransportError.status(http.statusCode) }
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
