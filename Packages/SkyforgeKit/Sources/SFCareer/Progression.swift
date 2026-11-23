// SKYFORGE — Apache-2.0
// XP, levels and ranks. Pure arithmetic, deterministic, no state.
import Foundation

public enum PilotRank: Int, Codable, Sendable, CaseIterable, Comparable {
    case student, privatePilot, commercial, instructor, captain, squadronLeader, ace, legend

    public static func < (a: PilotRank, b: PilotRank) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .student: return "Student Pilot"
        case .privatePilot: return "Private Pilot"
        case .commercial: return "Commercial Pilot"
        case .instructor: return "Flight Instructor"
        case .captain: return "Captain"
        case .squadronLeader: return "Squadron Leader"
        case .ace: return "Ace"
        case .legend: return "Legend"
        }
    }

    /// First level at which this rank applies.
    public var minLevel: Int {
        switch self {
        case .student: return 1
        case .privatePilot: return 5
        case .commercial: return 10
        case .instructor: return 16
        case .captain: return 24
        case .squadronLeader: return 34
        case .ace: return 46
        case .legend: return 60
        }
    }

    public static func forLevel(_ level: Int) -> PilotRank {
        allCases.last { level >= $0.minLevel } ?? .student
    }
}

public enum Progression {
    public static let maxLevel = 75

    /// Cumulative XP needed to *reach* `level` (level 1 = 0 XP). Smooth power curve: ~hours of play per level early,
    /// stretching to tens of hours at the top, so there is always a next goal.
    public static func xpForLevel(_ level: Int) -> Int {
        let l = min(max(level, 1), maxLevel)
        guard l > 1 else { return 0 }
        return Int((120.0 * pow(Double(l - 1), 1.75)).rounded())
    }

    public static func level(forXP xp: Int) -> Int {
        let x = max(0, xp)
        var lo = 1, hi = maxLevel
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if xpForLevel(mid) <= x { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Progress 0...1 through the current level; 1 at max level.
    public static func levelProgress(xp: Int) -> Double {
        let l = level(forXP: xp)
        guard l < maxLevel else { return 1 }
        let a = xpForLevel(l), b = xpForLevel(l + 1)
        return Double(max(0, xp) - a) / Double(b - a)
    }
}
