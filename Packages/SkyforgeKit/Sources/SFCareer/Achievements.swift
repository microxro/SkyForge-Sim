// SKYFORGE — Apache-2.0
import Foundation

/// Lifetime counters. Everything an achievement can depend on lives here, so achievements are pure functions of stats.
public struct CareerStats: Codable, Sendable, Equatable {
    public var flights = 0
    public var landings = 0
    public var crashes = 0
    public var smoothLandings = 0       // sink < 120 fpm
    public var flightSeconds = 0.0
    public var distanceKm = 0.0
    public var jobsCompleted = 0
    public var jobsFailed = 0
    public var creditsEarned = 0
    public var kills = 0
    public var missionsWon = 0
    public var challengesPlayed = 0
    public var goldMedals = 0
    public var aerobaticFigures = 0
    public var dailyStreak = 0
    public var bestDailyStreak = 0
    public var lastDailyDay = -1
    public var airportsVisited: Set<String> = []
    public var aircraftFlown: Set<String> = []
    public var highestG = 1.0
    public var discoveries: Set<String> = []
    public init() {}

    enum CodingKeys: String, CodingKey {
        case flights, landings, crashes, smoothLandings, flightSeconds, distanceKm, jobsCompleted, jobsFailed, creditsEarned
        case kills, missionsWon, challengesPlayed, goldMedals, aerobaticFigures, dailyStreak, bestDailyStreak, lastDailyDay
        case airportsVisited, aircraftFlown, highestG, discoveries
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func i(_ k: CodingKeys, _ def: Int = 0) throws -> Int { try c.decodeIfPresent(Int.self, forKey: k) ?? def }
        func f(_ k: CodingKeys, _ def: Double = 0) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? def }
        flights = try i(.flights); landings = try i(.landings); crashes = try i(.crashes); smoothLandings = try i(.smoothLandings)
        flightSeconds = try f(.flightSeconds); distanceKm = try f(.distanceKm); jobsCompleted = try i(.jobsCompleted)
        jobsFailed = try i(.jobsFailed); creditsEarned = try i(.creditsEarned); kills = try i(.kills); missionsWon = try i(.missionsWon)
        challengesPlayed = try i(.challengesPlayed); goldMedals = try i(.goldMedals); aerobaticFigures = try i(.aerobaticFigures)
        dailyStreak = try i(.dailyStreak); bestDailyStreak = try i(.bestDailyStreak); lastDailyDay = try i(.lastDailyDay, -1)
        airportsVisited = try c.decodeIfPresent(Set<String>.self, forKey: .airportsVisited) ?? []
        aircraftFlown = try c.decodeIfPresent(Set<String>.self, forKey: .aircraftFlown) ?? []
        highestG = try f(.highestG, 1)
        discoveries = try c.decodeIfPresent(Set<String>.self, forKey: .discoveries) ?? []
        sanitize()
    }

    mutating func sanitize() {
        let cap = 2_000_000_000
        func ci(_ v: Int) -> Int { min(max(v, 0), cap) }
        func cd(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1.0e12) : 0 }
        flights = ci(flights); landings = ci(landings); crashes = ci(crashes); smoothLandings = ci(smoothLandings)
        jobsCompleted = ci(jobsCompleted); jobsFailed = ci(jobsFailed); creditsEarned = ci(creditsEarned); kills = ci(kills)
        missionsWon = ci(missionsWon); challengesPlayed = ci(challengesPlayed); goldMedals = ci(goldMedals)
        aerobaticFigures = ci(aerobaticFigures); dailyStreak = ci(dailyStreak); bestDailyStreak = ci(bestDailyStreak)
        lastDailyDay = min(max(lastDailyDay, -1), cap)
        flightSeconds = cd(flightSeconds); distanceKm = cd(distanceKm)
        highestG = highestG.isFinite ? min(max(highestG, -20), 30) : 1
        airportsVisited = Set(airportsVisited.filter { $0.utf8.count <= 8 }.prefix(5_000))
        aircraftFlown = aircraftFlown.filter { Economy.spec($0) != nil }
        discoveries = Set(discoveries.filter { Discoveries.isKnown($0) })
    }
}

public struct Achievement: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let xp: Int
    public let isUnlocked: @Sendable (CareerStats) -> Bool
}

public enum AchievementCatalog {
    static let handcrafted: [Achievement] = [
        .init(id: "first-flight", title: "Wheels Up", detail: "Complete your first flight", xp: 50) { $0.flights >= 1 },
        .init(id: "first-landing", title: "Touchdown", detail: "Land safely for the first time", xp: 75) { $0.landings >= 1 },
        .init(id: "butter", title: "Butter", detail: "Land with under 120 fpm sink rate", xp: 100) { $0.smoothLandings >= 1 },
        .init(id: "butter-25", title: "Greaser", detail: "25 smooth landings", xp: 400) { $0.smoothLandings >= 25 },
        .init(id: "ten-hours", title: "Ten Hours", detail: "Log 10 hours in the air", xp: 200) { $0.flightSeconds >= 36_000 },
        .init(id: "hundred-hours", title: "Century", detail: "Log 100 hours in the air", xp: 1_500) { $0.flightSeconds >= 360_000 },
        .init(id: "thousand-km", title: "Long Haul", detail: "Fly 1,000 km in total", xp: 150) { $0.distanceKm >= 1_000 },
        .init(id: "round-world", title: "Around The World", detail: "Fly 40,000 km in total", xp: 2_500) { $0.distanceKm >= 40_000 },
        .init(id: "first-job", title: "Gig Pilot", detail: "Complete a job", xp: 75) { $0.jobsCompleted >= 1 },
        .init(id: "jobs-25", title: "Frequent Hauler", detail: "Complete 25 jobs", xp: 600) { $0.jobsCompleted >= 25 },
        .init(id: "millionaire", title: "Aviation Baron", detail: "Earn 1,000,000 credits", xp: 1_000) { $0.creditsEarned >= 1_000_000 },
        .init(id: "explorer-10", title: "Explorer", detail: "Land at 10 different airports", xp: 300) { $0.airportsVisited.count >= 10 },
        .init(id: "hangar-5", title: "Collector", detail: "Fly 5 different aircraft", xp: 300) { $0.aircraftFlown.count >= 5 },
        .init(id: "first-kill", title: "First Blood", detail: "Score your first kill", xp: 100) { $0.kills >= 1 },
        .init(id: "ace", title: "Ace", detail: "Score 5 kills", xp: 500) { $0.kills >= 5 },
        .init(id: "aerobat-20", title: "Stunt Pilot", detail: "Fly 20 aerobatic figures", xp: 300) { $0.aerobaticFigures >= 20 },
        .init(id: "gold-5", title: "Gold Standard", detail: "Win 5 gold medals", xp: 500) { $0.goldMedals >= 5 },
        .init(id: "streak-7", title: "Weekly Habit", detail: "Play the daily challenge 7 days running", xp: 700) { $0.bestDailyStreak >= 7 },
        .init(id: "g-force", title: "Pull Hard", detail: "Reach 8 g and land", xp: 200) { $0.highestG >= 8 && $0.landings >= 1 },
        .init(id: "survivor", title: "Walk It Off", detail: "Survive a crash and keep flying", xp: 50) { $0.crashes >= 1 && $0.flights > $0.crashes },
    ]
    /// Every achievement: the hand-written milestones plus the tiered families.
    public static let all: [Achievement] = handcrafted + generated
    static let byID: [String: Achievement] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

// MARK: - Tiered families

extension AchievementCatalog {
    /// One achievement per threshold, so progress is always visible and there is always a next goal.
    struct Family: Sendable {
        let key: String
        let thresholds: [Int]
        let value: @Sendable (CareerStats) -> Double
        let title: @Sendable (Int) -> String
        let detail: @Sendable (Int) -> String
    }

    static let families: [Family] = [
        Family(key: "flights", thresholds: [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500],
               value: { Double($0.flights) }, title: { "Logbook \($0)" }, detail: { "Complete \($0) flights" }),
        Family(key: "landings", thresholds: [10, 25, 50, 100, 250, 500, 1_000, 2_500],
               value: { Double($0.landings) }, title: { "Touchdowns \($0)" }, detail: { "Land \($0) times" }),
        Family(key: "smooth", thresholds: [5, 10, 50, 100, 250, 500, 1_000],
               value: { Double($0.smoothLandings) }, title: { "Smooth Operator \($0)" }, detail: { "Land \($0) times under 120 fpm" }),
        Family(key: "hours", thresholds: [1, 25, 50, 250, 500, 1_000],
               value: { $0.flightSeconds / 3_600 }, title: { "\($0) Hours Aloft" }, detail: { "Log \($0) hours in the air" }),
        Family(key: "distance", thresholds: [100, 500, 2_500, 5_000, 10_000, 20_000, 100_000],
               value: { $0.distanceKm }, title: { "\($0) km Flown" }, detail: { "Fly \($0) km in total" }),
        Family(key: "jobs", thresholds: [5, 10, 50, 100, 250, 500],
               value: { Double($0.jobsCompleted) }, title: { "Hauler \($0)" }, detail: { "Complete \($0) jobs" }),
        Family(key: "credits", thresholds: [10_000, 100_000, 10_000_000, 100_000_000, 1_000_000_000],
               value: { Double($0.creditsEarned) }, title: { "Credits \($0.formatted())" }, detail: { "Earn \($0.formatted()) credits in total" }),
        Family(key: "kills", thresholds: [10, 25, 50, 100],
               value: { Double($0.kills) }, title: { "Kills \($0)" }, detail: { "Score \($0) kills" }),
        Family(key: "figures", thresholds: [1, 5, 10, 50, 100, 250, 500],
               value: { Double($0.aerobaticFigures) }, title: { "Figures \($0)" }, detail: { "Fly \($0) aerobatic figures" }),
        Family(key: "gold", thresholds: [1, 10, 25, 50, 100],
               value: { Double($0.goldMedals) }, title: { "Gold Run \($0)" }, detail: { "Win \($0) gold medals" }),
        Family(key: "missions", thresholds: [1, 5, 10, 25, 50, 100],
               value: { Double($0.missionsWon) }, title: { "Mission \($0)" }, detail: { "Win \($0) missions" }),
        Family(key: "challenges", thresholds: [1, 10, 25, 50, 100, 250, 500],
               value: { Double($0.challengesPlayed) }, title: { "Challenger \($0)" }, detail: { "Play \($0) challenges" }),
        Family(key: "airports", thresholds: [5, 25, 50, 100, 200],
               value: { Double($0.airportsVisited.count) }, title: { "Airports \($0)" }, detail: { "Land at \($0) different airports" }),
        Family(key: "aircraft", thresholds: [2, 3, 4, 6, 8, 12],
               value: { Double($0.aircraftFlown.count) }, title: { "Fleet \($0)" }, detail: { "Fly \($0) different aircraft" }),
        Family(key: "streak", thresholds: [3, 14, 30, 60, 100],
               value: { Double($0.bestDailyStreak) }, title: { "Streak \($0)" }, detail: { "Play the daily challenge \($0) days running" }),
        Family(key: "g", thresholds: [2, 4, 6, 8, 9],
               value: { $0.highestG }, title: { "Pull \($0) g" }, detail: { "Reach \($0) g" }),
        Family(key: "discover", thresholds: [1, 5, 10, 25, 50, 75, 100],
               value: { Double($0.discoveries.count) }, title: { "Discoverer \($0)" }, detail: { "Discover \($0) landmarks and scenic points" }),
    ]

    static let generated: [Achievement] = families.flatMap { AchievementCatalog.expand($0) }

    static func expand(_ f: Family) -> [Achievement] {
        f.thresholds.enumerated().map { index, n in
            let value = f.value
            let target = Double(n)
            return Achievement(id: "\(f.key)-\(n)", title: f.title(n), detail: f.detail(n),
                               xp: min(1_500, 40 + 35 * index),
                               isUnlocked: { value($0) >= target })
        }
    }
}
