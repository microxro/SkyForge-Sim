// SKYFORGE — Apache-2.0
// The aerial firefighting career: a finished fire incident becomes a score, a payout and career progress.
// It takes plain numbers, not SFGameplay types, so SFCareer keeps its only dependency on SFMath. The
// incident summary is built by the gameplay layer from the fire model's outcome.
import Foundation

/// What the career needs to know about one fire incident.
public struct FireIncidentSummary: Codable, Sendable, Equatable {
    /// Total area that burned over the incident (hectares).
    public var burnedHectares: Double
    /// True when every cell went out.
    public var contained: Bool
    /// Drops released.
    public var drops: Int
    /// Drops that put at least half their water on burning cells.
    public var accurateDrops: Int
    public var elapsed: Double

    public init(burnedHectares: Double, contained: Bool, drops: Int, accurateDrops: Int, elapsed: Double) {
        self.burnedHectares = burnedHectares; self.contained = contained
        self.drops = drops; self.accurateDrops = accurateDrops; self.elapsed = elapsed
    }

    /// Clamps the numbers so a bad or tampered summary cannot produce a negative or huge payout.
    public var sanitized: FireIncidentSummary {
        let d = max(0, min(drops, 10_000))
        return FireIncidentSummary(
            burnedHectares: burnedHectares.isFinite ? min(max(burnedHectares, 0), 1_000_000) : 0,
            contained: contained,
            drops: d,
            accurateDrops: min(max(accurateDrops, 0), d),
            elapsed: elapsed.isFinite ? min(max(elapsed, 0), 86_400) : 0)
    }
}

public enum FirefightingScoring {
    public static let containedBase = 500
    public static let perAccurateDrop = 100
    public static let wastedDropPenalty = 20
    public static let fastContainmentSeconds = 600.0
    public static let fastContainmentBonus = 200
    public static let creditsPerPoint = 5

    /// Points for one incident. A lost fire scores nothing, and a wasted drop costs points.
    public static func score(_ raw: FireIncidentSummary) -> Int {
        let s = raw.sanitized
        guard s.contained else { return 0 }
        let wasted = s.drops - s.accurateDrops
        var points = containedBase + perAccurateDrop * s.accurateDrops - wastedDropPenalty * wasted
        if s.elapsed <= fastContainmentSeconds { points += fastContainmentBonus }
        return max(0, points)
    }
}

public enum FirefightingRank: Int, Codable, Sendable, CaseIterable, Comparable {
    case trainee, scooper, leadScooper, airAttackOfficer, divisionBoss

    public static func < (a: FirefightingRank, b: FirefightingRank) -> Bool { a.rawValue < b.rawValue }

    public var displayName: String {
        switch self {
        case .trainee: return "Trainee"
        case .scooper: return "Scooper Pilot"
        case .leadScooper: return "Lead Scooper"
        case .airAttackOfficer: return "Air Attack Officer"
        case .divisionBoss: return "Division Boss"
        }
    }

    /// Contained fires needed to reach each rank.
    public var containedRequired: Int {
        switch self {
        case .trainee: return 0
        case .scooper: return 3
        case .leadScooper: return 8
        case .airAttackOfficer: return 20
        case .divisionBoss: return 40
        }
    }

    public static func forContained(_ n: Int) -> FirefightingRank {
        allCases.last { n >= $0.containedRequired } ?? .trainee
    }
}

/// Lifetime firefighting record, kept inside the career save.
public struct FirefightingRecord: Codable, Sendable, Equatable {
    public var incidents = 0
    public var contained = 0
    public var lost = 0
    public var drops = 0
    public var accurateDrops = 0
    public var hectaresBurned = 0.0
    public var bestScore = 0

    public init() {}

    public var rank: FirefightingRank { FirefightingRank.forContained(contained) }

    /// Accuracy across every drop (0...1), or 0 before the first drop.
    public var dropAccuracy: Double { drops > 0 ? Double(accurateDrops) / Double(drops) : 0 }

    public mutating func sanitize() {
        incidents = min(max(incidents, 0), 1_000_000)
        contained = min(max(contained, 0), incidents)
        lost = min(max(lost, 0), incidents - contained)
        drops = min(max(drops, 0), 10_000_000)
        accurateDrops = min(max(accurateDrops, 0), drops)
        hectaresBurned = hectaresBurned.isFinite ? min(max(hectaresBurned, 0), 1e9) : 0
        bestScore = min(max(bestScore, 0), 10_000_000)
    }
}

/// What one settled incident paid out.
public struct FirefightingSettlement: Sendable, Equatable {
    public var score: Int
    public var credits: Int
    public var xp: Int
    public var rankBefore: FirefightingRank
    public var rankAfter: FirefightingRank
    public var rankedUp: Bool { rankAfter > rankBefore }
}

public extension CareerState {
    /// Records a finished fire incident: updates the firefighting record, pays credits and XP, and returns what
    /// happened. A lost fire is recorded and pays nothing.
    @discardableResult
    mutating func settleFireIncident(_ raw: FireIncidentSummary) -> FirefightingSettlement {
        let s = raw.sanitized
        let before = firefighting.rank
        let score = FirefightingScoring.score(s)
        firefighting.incidents += 1
        firefighting.drops += s.drops
        firefighting.accurateDrops += s.accurateDrops
        firefighting.hectaresBurned += s.burnedHectares
        if s.contained {
            firefighting.contained += 1
            firefighting.bestScore = max(firefighting.bestScore, score)
        } else {
            firefighting.lost += 1
        }
        firefighting.sanitize()
        let credits = score * FirefightingScoring.creditsPerPoint
        let xpGain = score / 2
        self.credits = min(self.credits + credits, Self.maxCredits)
        self.xp = min(self.xp + xpGain, Self.maxXP)
        return FirefightingSettlement(score: score, credits: credits, xp: xpGain,
                                      rankBefore: before, rankAfter: firefighting.rank)
    }
}
