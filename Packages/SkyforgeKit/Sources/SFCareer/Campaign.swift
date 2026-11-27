// SKYFORGE — Apache-2.0
// Campaign ladders built from SFGameplay mission ids (strings, so no module dependency), and the adapter that
// turns a finished mission into a FlightReport. Progress is derived from CareerState.completedMissions.
import Foundation

public struct CampaignStage: Sendable, Equatable {
    public var missionID: String
    public var title: String
    public var rewardCredits: Int
    public var rewardXP: Int
}

public struct Campaign: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var stages: [CampaignStage]
    public var completionAircraftUnlock: String?

    /// Ids match SFGameplay/MissionCatalog.swift (PR #19).
    public static let flightSchool = Campaign(
        id: "flight-school", title: "Flight School", summary: "From first takeoff to a crosswind precision landing.",
        stages: [
            .init(missionID: "first-flight", title: "First Flight", rewardCredits: 500, rewardXP: 100),
            .init(missionID: "pattern-landing", title: "Traffic Pattern", rewardCredits: 800, rewardXP: 150),
            .init(missionID: "precision-landing", title: "Crosswind Precision", rewardCredits: 1_500, rewardXP: 250),
        ], completionAircraftUnlock: nil)

    public static let airWing = Campaign(
        id: "air-wing", title: "Air Wing", summary: "Formation, intercept, gunnery and your first dogfight.",
        stages: [
            .init(missionID: "wingman-formation", title: "Wingman", rewardCredits: 2_000, rewardXP: 300),
            .init(missionID: "intercept-bogey", title: "Quick Reaction Alert", rewardCredits: 3_000, rewardXP: 400),
            .init(missionID: "gunnery-range", title: "Gunnery Range", rewardCredits: 3_000, rewardXP: 400),
            .init(missionID: "low-level-nav", title: "Low-Level Navigation", rewardCredits: 3_500, rewardXP: 450),
            .init(missionID: "air-combat-training", title: "Air Combat Training", rewardCredits: 6_000, rewardXP: 800),
        ], completionAircraftUnlock: "org.skyforge.sff1")

    public static let searchAndRescue = Campaign(
        id: "search-and-rescue", title: "Search and Rescue", summary: "Find people in the hills, bring them off the strip and fly them to hospital.",
        stages: [
            .init(missionID: "sar-grid-search", title: "Grid Search", rewardCredits: 1_200, rewardXP: 200),
            .init(missionID: "sar-medevac-strip", title: "Medevac from the Strip", rewardCredits: 1_500, rewardXP: 250),
            .init(missionID: "sar-two-survivors", title: "Two Survivors", rewardCredits: 2_500, rewardXP: 400),
        ], completionAircraftUnlock: nil)

    public static let all: [Campaign] = [flightSchool, airWing, searchAndRescue]
}

public struct CampaignProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var nextStage: CampaignStage?
    public var isComplete: Bool { completed == total }
}

public extension CareerState {
    func progress(in c: Campaign) -> CampaignProgress {
        let done = c.stages.filter { completedMissions.contains($0.missionID) }.count
        let next = c.stages.first { !completedMissions.contains($0.missionID) }
        return CampaignProgress(completed: done, total: c.stages.count, nextStage: next)
    }

    /// Campaign claims already paid out (stored so rewards are one-time).
    /// Claims every stage reward and the completion unlock that is newly earned; safe to call after every flight.
    @discardableResult
    mutating func claimCampaignRewards(_ campaigns: [Campaign] = Campaign.all) -> (credits: Int, xp: Int, unlocked: [String]) {
        var credits = 0, xp = 0
        var unlocked: [String] = []
        for c in campaigns {
            for s in c.stages where completedMissions.contains(s.missionID) && claimedCampaignStages.insert("\(c.id)/\(s.missionID)").inserted {
                credits += s.rewardCredits; xp += s.rewardXP
            }
            if progress(in: c).isComplete, let a = c.completionAircraftUnlock, ownedAircraft.insert(a).inserted { unlocked.append(a) }
        }
        self.credits += credits
        self.xp = min(self.xp + xp, 1_000_000_000)
        return (credits, xp, unlocked)
    }
}

public extension FlightReport {
    /// Adapter for SFGameplay's MissionResult (pass its fields; no module dependency needed).
    static func fromMission(id: String, aircraftID: String, success: Bool, score: Int, elapsed: Double,
                            kills: Int, crashed: Bool, departureICAO: String = "", endedAt: Int) -> FlightReport {
        FlightReport(kind: .mission(missionID: id), aircraftID: aircraftID, departureICAO: departureICAO,
                     durationS: elapsed, crashed: crashed, kills: kills, missionSuccess: success,
                     rawScore: Double(max(0, score)), endedAt: endedAt)
    }
}
