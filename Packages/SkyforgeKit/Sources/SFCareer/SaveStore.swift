// SKYFORGE — Apache-2.0
// Crash-safe save files: versioned JSON, atomic writes, rolling backup, corrupt-file recovery.
import Foundation

public struct SaveStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    var backupURL: URL { url.appendingPathExtension("bak") }
    var quarantineURL: URL { url.appendingPathExtension("corrupt") }

    /// The pilot's career file in Application Support, next to the mission progress file.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Skyforge", isDirectory: true).appendingPathComponent("career.json")
    }

    /// Applies one finished flight to the saved career and writes it back. Returns nil if the save could not be
    /// read or written (a newer-version or unreadable save is never overwritten).
    @discardableResult
    public func record(_ report: FlightReport, challenge: Challenge? = nil) -> FlightOutcome? {
        guard var career = try? load() else { return nil }
        let outcome = CareerEngine.apply(report, to: &career, challenge: challenge)
        do { try save(career) } catch { return nil }
        return outcome
    }

    public enum SaveError: Error, Sendable, Equatable { case newerThanApp(Int), unreadable }
    public static let maxFileBytes = 1_048_576

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
            guard let data = try? Data(contentsOf: u), data.count <= Self.maxFileBytes else { continue }
            do { return try decode(data) }
            catch let e as SaveError { throw e }   // newer-than-app must never fall back to a stale backup
            catch { continue }
        }

        // Keep the unreadable file for recovery instead of letting the next save destroy it.
        try? fm.removeItem(at: quarantineURL)
        try? fm.moveItem(at: url, to: quarantineURL)
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
