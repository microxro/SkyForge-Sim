// SKYFORGE — Apache-2.0
// Crash-safe save files: versioned JSON, atomic writes, rolling backup, corrupt-file recovery.
import Foundation

public struct SaveStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    var backupURL: URL { url.appendingPathExtension("bak") }

    public enum SaveError: Error, Sendable, Equatable { case newerThanApp(Int), unreadable }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }

    public func save(_ state: CareerState) throws {
        let data = try Self.encoder().encode(state)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the previous good save as a backup before replacing it.
        if fm.fileExists(atPath: url.path), let cur = try? Data(contentsOf: url), (try? decode(cur)) != nil {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: url, to: backupURL)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Loads the profile. Missing file → fresh profile. Corrupt main file → backup. Both corrupt → throws `.unreadable`
    /// (the caller decides; we never silently overwrite a player's progress with a blank profile).
    public func load() throws -> CareerState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return CareerState() }

        for u in [url, backupURL] {
            guard let data = try? Data(contentsOf: u) else { continue }
            do { return try decode(data) }
            catch let e as SaveError { throw e }   // newer-than-app must never fall back to a stale backup
            catch { continue }
        }

        throw SaveError.unreadable
    }

    func decode(_ data: Data) throws -> CareerState {
        struct Header: Decodable { var version: Int }
        let h = try JSONDecoder().decode(Header.self, from: data)
        if h.version > CareerState.currentVersion { throw SaveError.newerThanApp(h.version) }
        // Future migrations switch on h.version here.
        var s = try JSONDecoder().decode(CareerState.self, from: data)
        s.version = CareerState.currentVersion
        return s
    }
}
