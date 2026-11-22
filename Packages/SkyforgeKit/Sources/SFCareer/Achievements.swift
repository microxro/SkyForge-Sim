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
    public init() {}
}

public struct Achievement: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let xp: Int
    public let isUnlocked: @Sendable (CareerStats) -> Bool
}

public enum AchievementCatalog {
    public static let all: [Achievement] = [
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
    static let byID: [String: Achievement] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
