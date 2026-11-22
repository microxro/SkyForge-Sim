// SKYFORGE — Apache-2.0
// What the mission and weapon HUD shows, as plain values so any UI (SwiftUI, Metal) can draw it and
// tests can check it.
import Foundation

public extension EnvelopeWarning {
    /// Short cockpit callout.
    var callout: String {
        switch self {
        case .stall: return "STALL"
        case .overspeed: return "OVERSPEED"
        case .overMach: return "MACH LIMIT"
        case .flapOverspeed: return "FLAPS"
        case .overG: return "OVERG"
        case .negativeG: return "NEG G"
        case .terrain: return "PULL UP"
        }
    }
}

public extension UnlockRequirement {
    /// Plain-language unlock hint for the selection screens.
    var hint: String {
        switch self {
        case .none: return ""
        case .mission(let id): return "Complete \(MissionCatalog.mission(id: id)?.title ?? id)"
        case .medals(let n): return "Earn \(n) medals"
        }
    }
}

public struct GameplayHUD: Sendable, Equatable {
    public var objectiveTitle: String?
    public var objectiveNumber: Int
    public var objectiveCount: Int
    public var objectiveProgress: Double
    public var elapsed: Double
    public var warnings: [EnvelopeWarning]
    public var loadFactor: Double
    public var mach: Double
    public var lockText: String?
    public var cannonRounds: Int
    public var missiles: Int
    public var status: MissionStatus?
    public var kills: Int = 0

    public var timeText: String {
        let s = Int(max(0, elapsed))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

public extension GameplayDirector {
    /// HUD values for the current moment. `mach` and `time` come from the flight.
    func hud(mach: Double, time: Double) -> GameplayHUD {
        var lock: String?
        switch weapons.lock {
        case .none: lock = nil
        case .acquiring(let id, let p): lock = "ACQUIRING \(id) \(Int(p * 100))%"
        case .locked(let id): lock = "LOCK \(id)"
        }
        return GameplayHUD(
            objectiveTitle: runtime?.currentObjective?.title,
            objectiveNumber: min((runtime?.objectiveIndex ?? 0) + 1, runtime?.mission.objectives.count ?? 0),
            objectiveCount: runtime?.mission.objectives.count ?? 0,
            objectiveProgress: runtime?.progress ?? 0,
            elapsed: runtime?.elapsed ?? time,
            warnings: monitor.warnings.sorted(),
            loadFactor: loadFactor, mach: mach, lockText: lock,
            cannonRounds: weapons.cannonRounds, missiles: weapons.missilesRemaining,
            status: runtime?.status, kills: kills)
    }
}

public extension GameplaySession {
    var hud: GameplayHUD { director.hud(mach: mach, time: time) }
}
