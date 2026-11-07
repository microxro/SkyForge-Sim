// SKYFORGE — Apache-2.0
import Foundation
import Crypto

/// A SHA-256 content address (lowercase hex).
public struct ContentID: Hashable, Sendable, CustomStringConvertible {
    public let hex: String
    public init(data: Data) {
        hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public init?(hex: String) {
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.hex = hex
    }
    public var description: String { hex }
    /// Two-level fan-out path, e.g. "ab/cd/abcd...".
    public var relativePath: String {
        let a = hex.prefix(2), b = hex.dropFirst(2).prefix(2)
        return "\(a)/\(b)/\(hex)"
    }
}

/// Errors raised by the content store.
public enum ContentError: Error, Equatable {
    case corrupted(expected: String, actual: String)
    case notFound(String)
}

/// A minimal content-addressable blob store with atomic install and verify-on-read.
/// Quota, LRU eviction and manifests follow in P3 (see PROGRESS.md).
public final class ContentStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    func url(for id: ContentID) -> URL { root.appendingPathComponent(id.relativePath) }

    /// Writes data atomically (temp file -> verify -> rename) and returns its address.
    @discardableResult
    public func put(_ data: Data) throws -> ContentID {
        let id = ContentID(data: data)
        let dest = url(for: id)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { return id }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        let check = ContentID(data: try Data(contentsOf: tmp))
        guard check == id else {
            try? fm.removeItem(at: tmp)
            throw ContentError.corrupted(expected: id.hex, actual: check.hex)
        }
        do { try fm.moveItem(at: tmp, to: dest) } catch {
            try? fm.removeItem(at: tmp)
            if !fm.fileExists(atPath: dest.path) { throw error }
        }
        return id
    }

    /// Reads and verifies a blob. Corrupted blobs are deleted so callers can re-fetch.
    public func get(_ id: ContentID) throws -> Data {
        let u = url(for: id)
        guard let data = FileManager.default.contents(atPath: u.path) else { throw ContentError.notFound(id.hex) }
        let actual = ContentID(data: data)
        guard actual == id else {
            try? FileManager.default.removeItem(at: u)
            throw ContentError.corrupted(expected: id.hex, actual: actual.hex)
        }
        return data
    }

    public func contains(_ id: ContentID) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }
}
