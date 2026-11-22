// SKYFORGE — Apache-2.0
// The player's persistent profile and the pipeline that turns a FlightReport into progress.
import Foundation

public struct ChallengeRecord: Codable, Sendable, Equatable {
    public var bestScore: Double
    public var medal: AwardMedal
    public var attempts: Int
}

public struct FlightLogEntry: Codable, Sendable, Equatable {
    public var report: FlightReport
    public var xpGained: Int
    public var creditsDelta: Int
}

public struct CareerState: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = CareerState.currentVersion
    public var pilotName = "Pilot"
    public var xp = 0
    public var credits = Economy.startingCredits
    public var ownedAircraft: Set<String> = ["org.skyforge.sf1"]
    public var unlockedAchievements: Set<String> = []
    public var stats = CareerStats()
    public var challenges: [String: ChallengeRecord] = [:]
    public var completedMissions: Set<String> = []
    public var completedJobIDs: Set<String> = []
    public var claimedCampaignStages: Set<String> = []
    public var activeJob: Job?
    public var log: [FlightLogEntry] = []        // most recent last, capped
    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, pilotName, xp, credits, ownedAircraft, unlockedAchievements, stats, challenges
        case completedMissions, completedJobIDs, claimedCampaignStages, activeJob, log
    }

    /// Tolerant decoding: every field optional so old saves survive new fields; result is always sanitised.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = CareerState()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? def.version
        pilotName = try c.decodeIfPresent(String.self, forKey: .pilotName) ?? def.pilotName
        xp = try c.decodeIfPresent(Int.self, forKey: .xp) ?? 0
        credits = try c.decodeIfPresent(Int.self, forKey: .credits) ?? def.credits
        ownedAircraft = try c.decodeIfPresent(Set<String>.self, forKey: .ownedAircraft) ?? def.ownedAircraft
        unlockedAchievements = try c.decodeIfPresent(Set<String>.self, forKey: .unlockedAchievements) ?? []
        stats = try c.decodeIfPresent(CareerStats.self, forKey: .stats) ?? CareerStats()
        challenges = try c.decodeIfPresent([String: ChallengeRecord].self, forKey: .challenges) ?? [:]
        completedMissions = try c.decodeIfPresent(Set<String>.self, forKey: .completedMissions) ?? []
        completedJobIDs = try c.decodeIfPresent(Set<String>.self, forKey: .completedJobIDs) ?? []
        claimedCampaignStages = try c.decodeIfPresent(Set<String>.self, forKey: .claimedCampaignStages) ?? []
        activeJob = try c.decodeIfPresent(Job.self, forKey: .activeJob)
        log = try c.decodeIfPresent([FlightLogEntry].self, forKey: .log) ?? []
        sanitize()
    }

    public static let maxCredits = 2_000_000_000
    public static let maxXP = 1_000_000_000
    static func validID(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    /// Clamps numbers and bounds collections so a tampered or corrupt save can never trap or bloat memory.
    public mutating func sanitize() {
        for id in ownedAircraft where Economy.spec(id) == nil {
            credits += Economy.retiredAircraftRefunds[id] ?? 0   // refund once; the id is dropped below
        }
        xp = min(max(xp, 0), Self.maxXP)
        credits = min(max(credits, 0), Self.maxCredits)
        pilotName = String(pilotName.prefix(32))
        completedMissions = Set(completedMissions.filter(Self.validID).prefix(1_000))
        completedJobIDs = Set(completedJobIDs.prefix(5_000))
        claimedCampaignStages = Set(claimedCampaignStages.prefix(1_000))
        unlockedAchievements = unlockedAchievements.filter { id in AchievementCatalog.all.contains { $0.id == id } }
        ownedAircraft = ownedAircraft.filter { Economy.spec($0) != nil }
        ownedAircraft.insert("org.skyforge.sf1")
        stats.sanitize()
        if log.count > Self.maxLogEntries { log.removeFirst(log.count - Self.maxLogEntries) }
        if let j = activeJob, !(j.distanceKm.isFinite && j.basePay >= 0 && j.basePay < 10_000_000 && j.deadlineMinutes.isFinite) { activeJob = nil }
    }

    public var level: Int { Progression.level(forXP: xp) }
    public var rank: PilotRank { PilotRank.forLevel(level) }
    public static let maxLogEntries = 200

    public enum PurchaseError: Error, Sendable, Equatable { case unknownAircraft, alreadyOwned, levelTooLow(needed: Int), insufficientFunds(short: Int) }

    public mutating func buy(aircraftID: String, catalog: [HangarAircraft] = Economy.catalog) throws {
        guard let a = Economy.spec(aircraftID, in: catalog) else { throw PurchaseError.unknownAircraft }
        guard !ownedAircraft.contains(a.id) else { throw PurchaseError.alreadyOwned }
        guard level >= a.unlockLevel else { throw PurchaseError.levelTooLow(needed: a.unlockLevel) }
        guard credits >= a.purchasePrice else { throw PurchaseError.insufficientFunds(short: a.purchasePrice - credits) }
        credits -= a.purchasePrice
        ownedAircraft.insert(a.id)
    }

    /// Can the player take this aircraft out (owned, or rentable at their level)?
    public func canUse(aircraftID: String, catalog: [HangarAircraft] = Economy.catalog) -> Bool {
        guard let a = Economy.spec(aircraftID, in: catalog) else { return false }
        return ownedAircraft.contains(a.id) || level >= a.unlockLevel
    }

    /// Accept a job. Fails if one is already active or the aircraft cannot do it.
    public mutating func accept(job: Job, aircraft: HangarAircraft) -> Result<Void, JobRejection> {
        if activeJob != nil { return .failure(.alreadyHaveJob) }
        if completedJobIDs.contains(job.id) { return .failure(.alreadyHaveJob) }
        switch JobBoard.canFly(job, with: aircraft, level: level) {
        case .success: activeJob = job; return .success(())
        case .failure(let e): return .failure(e)
        }
    }
}

public struct FlightOutcome: Sendable, Equatable {
    public var xpGained: Int
    public var creditsDelta: Int
    public var leveledUpTo: Int?
    public var newAchievements: [String]
    public var medal: AwardMedal?
    public var score: Double?
    public var settlement: JobSettlement?
}

public enum CareerEngine {
    /// Applies one flight to the profile. Deterministic; rejects nothing (a bad report is sanitised, never trusted).
    @discardableResult
    public static func apply(_ raw: FlightReport, to state: inout CareerState,
                             challenge: Challenge? = nil, catalog: [HangarAircraft] = Economy.catalog) -> FlightOutcome {
        let r = raw.sanitized()
        let levelBefore = state.level
        var xp = 0, credits = 0
        var medal: AwardMedal? = nil, score: Double? = nil, settlement: JobSettlement? = nil

        // --- base xp: time aloft, distance, landing ---
        xp += Int(r.durationS / 60) * 2 + Int(r.distanceM / 1000 / 5)
        if r.landed && !r.crashed {
            xp += 25
            if let s = r.touchdownSinkFPM, s < 120 { xp += 40 } else if let s = r.touchdownSinkFPM, s < 250 { xp += 15 }
        }
        if r.crashed { xp = xp / 4 }

        // --- kind-specific rewards ---
        switch r.kind {
        case .freeFlight: break
        case .job(let jobID):
            if let job = state.activeJob, job.id == jobID {
                let owned = state.ownedAircraft.contains(r.aircraftID)
                let rent = Economy.spec(r.aircraftID, in: catalog)?.rentalPerHour ?? 0
                let s = JobSettler.settle(job: job, report: r, owned: owned, rentalPerHour: rent)
                settlement = s
                credits += s.net
                if s.success { state.completedJobIDs.insert(job.id); xp += 80 + Int((job.distanceKm.isFinite ? min(max(job.distanceKm, 0), 20_000) : 0) / 4); state.stats.jobsCompleted += 1 } else { state.stats.jobsFailed += 1 }
                state.activeJob = nil
            }
        case .challenge:
            if let c = challenge, case .challenge(let cid) = r.kind, cid == c.id {
                var r = r
                if c.type == .landing && r.arrivalICAO != c.airportICAO { r.landed = false }
                let sc = c.score(r)
                let m = c.medal(for: r)
                score = sc; medal = m
                var rec = state.challenges[c.id] ?? ChallengeRecord(bestScore: 0, medal: .none, attempts: 0)
                rec.attempts += 1
                // Pay out only the improvement over the previous best medal, so a challenge can't be farmed.
                if m > rec.medal {
                    let prior = rec.medal
                    xp += m.xp - prior.xp
                    credits += m.credits - prior.credits
                    if m >= .gold && prior < .gold { state.stats.goldMedals += 1 }
                    rec.medal = m
                }
                rec.bestScore = max(rec.bestScore, sc)
                state.challenges[c.id] = rec
                state.stats.challengesPlayed += 1
                if m != .none, c.id.hasPrefix("daily-"), let day = Int(c.id.dropFirst(6)) { updateStreak(&state.stats, day: day) }
            }
        case .mission(let id):
            score = r.rawScore
            if CareerState.validID(id) && r.missionSuccess && !r.crashed && r.durationS >= 15 && (state.completedMissions.contains(id) || state.completedMissions.count < 1_000) {
                let first = state.completedMissions.insert(id).inserted
                xp += first ? 250 : 40
                credits += first ? 1_500 : 150
                state.stats.missionsWon += 1
            }
        }

        // --- combat ---
        let paidKills = min(r.kills, 10)
        if paidKills > 0 { xp += paidKills * 60; credits += paidKills * 120 }

        // --- stats ---
        var st = state.stats
        st.flights += 1
        st.flightSeconds += r.durationS
        st.distanceKm += r.distanceM / 1000
        st.kills += r.kills
        st.aerobaticFigures += r.aerobaticFigures.count
        st.highestG = max(st.highestG, r.maxG)
        if Economy.spec(r.aircraftID, in: catalog) != nil { st.aircraftFlown.insert(r.aircraftID) }
        if r.crashed { st.crashes += 1 }
        if r.landed && !r.crashed {
            st.landings += 1
            if let s = r.touchdownSinkFPM, s < 120 { st.smoothLandings += 1 }
            if let icao = r.arrivalICAO, !icao.isEmpty, icao.count <= 8, st.airportsVisited.count < 5_000 { st.airportsVisited.insert(icao) }
        }
        if credits > 0 { st.creditsEarned += credits }
        state.stats = st

        xp = max(0, xp)
        state.xp = min(state.xp + xp, CareerState.maxXP)
        state.credits = min(max(0, state.credits + credits), CareerState.maxCredits)

        let camp = state.claimCampaignRewards()
        xp += camp.xp; credits += camp.credits

        // --- level-up bonus, then achievements (which may add more xp) ---
        var newAch: [String] = []
        var settled = false
        while !settled {
            settled = true
            for a in AchievementCatalog.all where !state.unlockedAchievements.contains(a.id) && a.isUnlocked(state.stats) {
                state.unlockedAchievements.insert(a.id)
                state.xp += a.xp
                xp += a.xp
                newAch.append(a.id)
                settled = false
            }
        }
        let levelAfter = state.level
        if levelAfter > levelBefore {
            for l in (levelBefore + 1)...levelAfter { let b = Economy.levelUpCreditBonus(l); state.credits += b; credits += b }
        }

        state.xp = min(state.xp, CareerState.maxXP)
        state.credits = min(state.credits, CareerState.maxCredits)
        state.log.append(FlightLogEntry(report: r, xpGained: xp, creditsDelta: credits))
        if state.log.count > CareerState.maxLogEntries { state.log.removeFirst(state.log.count - CareerState.maxLogEntries) }

        return FlightOutcome(xpGained: xp, creditsDelta: credits, leveledUpTo: levelAfter > levelBefore ? levelAfter : nil,
                             newAchievements: newAch, medal: medal, score: score, settlement: settlement)
    }

    static func updateStreak(_ s: inout CareerStats, day: Int) {
        if day <= s.lastDailyDay { return }
        s.dailyStreak = (day == s.lastDailyDay + 1) ? s.dailyStreak + 1 : 1
        s.lastDailyDay = day
        s.bestDailyStreak = max(s.bestDailyStreak, s.dailyStreak)
    }
}
