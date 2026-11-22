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
}

public struct PlayerProgress: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public var version = PlayerProgress.currentVersion
    public var records: [String: MissionRecord] = [:]
    public var selectedAircraftID: String = AircraftCatalog.sf1Trainer.id

    public init() {}

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
        r.attempts += 1
        if result.success {
            r.completions += 1
            r.bestScore = max(r.bestScore, result.score)
            r.bestMedal = max(r.bestMedal, result.medal)
            r.bestTime = min(r.bestTime ?? result.elapsed, result.elapsed)
        }
        records[result.missionID] = r
        return (unlockedAircraft.filter { !beforeAircraft.contains($0.id) },
                unlockedMissions.filter { !beforeMissions.contains($0.id) })
    }
}

public struct ProgressStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> PlayerProgress {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(PlayerProgress.self, from: data),
              p.version <= PlayerProgress.currentVersion else { return PlayerProgress() }
        return p
    }

    public func save(_ progress: PlayerProgress) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(progress)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
