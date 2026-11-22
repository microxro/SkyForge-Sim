// SKYFORGE — Apache-2.0
// Pilot progress: best score and medal per mission, and what that has unlocked. Stored as small
// versioned JSON; a missing or corrupt file yields a fresh profile rather than an error.
import Foundation

public struct MissionRecord: Sendable, Codable, Equatable {
    public var bestScore: Int = 0
    public var bestMedal: Medal = .none
    public var attempts: Int = 0
    public var completions: Int = 0
    public var bestTime: Double?
    public init() {}

    /// Largest value any counter or score may hold; saved files beyond it are clamped on load.
    public static let limit = 1_000_000

    enum CodingKeys: String, CodingKey { case bestScore, bestMedal, attempts, completions, bestTime }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bestScore = try c.decodeIfPresent(Int.self, forKey: .bestScore) ?? 0
        bestMedal = try c.decodeIfPresent(Medal.self, forKey: .bestMedal) ?? .none
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        completions = try c.decodeIfPresent(Int.self, forKey: .completions) ?? 0
        bestTime = try c.decodeIfPresent(Double.self, forKey: .bestTime)
        sanitize()
    }

    /// Clamps counts and scores into range and drops a non-finite time.
    mutating func sanitize() {
        let lim = Self.limit
        bestScore = min(lim, max(0, bestScore)); attempts = min(lim, max(0, attempts)); completions = min(lim, max(0, completions))
        if let t = bestTime, !(t.isFinite && t >= 0) { bestTime = nil }
    }
}

public struct PlayerProgress: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public var version = PlayerProgress.currentVersion
    public var records: [String: MissionRecord] = [:]
    public var selectedAircraftID: String = AircraftCatalog.sf1Trainer.id

    public init() {}

    enum CodingKeys: String, CodingKey { case version, records, selectedAircraftID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        records = try c.decodeIfPresent([String: MissionRecord].self, forKey: .records) ?? [:]
        selectedAircraftID = try c.decodeIfPresent(String.self, forKey: .selectedAircraftID) ?? AircraftCatalog.sf1Trainer.id
    }

    /// Falls back to the SF-1 when the saved aircraft is unknown or still locked.
    mutating func sanitize() {
        if let a = AircraftCatalog.spec(id: selectedAircraftID), isUnlocked(a) {} else { selectedAircraftID = AircraftCatalog.sf1Trainer.id }
    }

    /// Whether a mission may be flown in an aircraft: both unlocked and the aircraft allowed by the mission.
    public func canStart(_ mission: MissionDefinition, in aircraft: AircraftSpec) -> Bool {
        isUnlocked(mission) && isUnlocked(aircraft) && mission.allows(aircraft)
    }

    public var totalMedals: Int { records.values.filter { $0.bestMedal != .none }.count }

    public func isCompleted(_ missionID: String) -> Bool { (records[missionID]?.completions ?? 0) > 0 }

    public func isUnlocked(_ requirement: UnlockRequirement) -> Bool {
        switch requirement {
        case .none: return true
        case .mission(let id): return isCompleted(id)
        case .medals(let n): return totalMedals >= n
        }
    }

    public func isUnlocked(_ aircraft: AircraftSpec) -> Bool { isUnlocked(aircraft.unlock) }
    public func isUnlocked(_ mission: MissionDefinition) -> Bool { isUnlocked(mission.unlock) }

    public var unlockedAircraft: [AircraftSpec] { AircraftCatalog.all.filter { isUnlocked($0) } }
    public var unlockedMissions: [MissionDefinition] { MissionCatalog.all.filter { isUnlocked($0) } }

    /// Unlocked aircraft that may fly a mission.
    public func aircraft(for mission: MissionDefinition) -> [AircraftSpec] {
        unlockedAircraft.filter { mission.allows($0) }
    }

    /// Records a finished mission; returns the aircraft and missions this result newly unlocked.
    @discardableResult
    public mutating func record(_ result: MissionResult) -> (aircraft: [AircraftSpec], missions: [MissionDefinition]) {
        let beforeAircraft = Set(unlockedAircraft.map(\.id)), beforeMissions = Set(unlockedMissions.map(\.id))
        var r = records[result.missionID] ?? MissionRecord()
        let lim = MissionRecord.limit
        r.attempts = min(lim, r.attempts + 1)
        if result.success {
            r.completions = min(lim, r.completions + 1)
            r.bestScore = max(r.bestScore, min(lim, max(0, result.score)))
            r.bestMedal = max(r.bestMedal, result.medal)
            if result.elapsed.isFinite && result.elapsed >= 0 { r.bestTime = min(r.bestTime ?? result.elapsed, result.elapsed) }
        }
        records[result.missionID] = r
        return (unlockedAircraft.filter { !beforeAircraft.contains($0.id) },
                unlockedMissions.filter { !beforeMissions.contains($0.id) })
    }
}

public struct ProgressStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    /// The pilot's progress file in Application Support.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Skyforge", isDirectory: true).appendingPathComponent("progress.json")
    }

    /// Largest save file read (bytes); anything bigger is treated as corrupt.
    public static let maxFileSize = 1_000_000

    /// Loads the saved progress. A missing file gives a fresh profile. A file that is too large, unreadable
    /// or from a newer version is moved aside to `progress.json.bak` (so the next save cannot destroy it)
    /// and a fresh profile is returned.
    public func load() -> PlayerProgress {
        guard FileManager.default.fileExists(atPath: url.path) else { return PlayerProgress() }
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxFileSize,
              var p = try? JSONDecoder().decode(PlayerProgress.self, from: data),
              p.version <= PlayerProgress.currentVersion else {
            backUpUnreadableFile()
            return PlayerProgress()
        }
        for key in p.records.keys { p.records[key]?.sanitize() }
        p.sanitize()
        return p
    }

    private func backUpUnreadableFile() {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)   // best effort: the save that follows is the real write
    }

    public func save(_ progress: PlayerProgress) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(progress)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
