import Testing
import Foundation
@testable import SFCareer

let kmry = AirportRef(icao: "KMRY", name: "Monterey", latitudeDeg: 36.587, longitudeDeg: -121.843, longestRunwayM: 2_100)
let ksfo = AirportRef(icao: "KSFO", name: "San Francisco", latitudeDeg: 37.619, longitudeDeg: -122.375, longestRunwayM: 3_600)
let klax = AirportRef(icao: "KLAX", name: "Los Angeles", latitudeDeg: 33.942, longitudeDeg: -118.408, longestRunwayM: 3_700)
let airports = [kmry, ksfo, klax]

@Suite struct ProgressionTests {
    @Test func levelCurveIsMonotonicAndInvertible() {
        var prev = -1
        for l in 1...Progression.maxLevel {
            let x = Progression.xpForLevel(l)
            #expect(x > prev)
            #expect(Progression.level(forXP: x) == l)
            if x > 0 { #expect(Progression.level(forXP: x - 1) == l - 1) }
            prev = x
        }
        #expect(Progression.level(forXP: -50) == 1)
        #expect(Progression.level(forXP: Int.max / 2) == Progression.maxLevel)
    }
    @Test func ranksFollowLevels() {
        #expect(PilotRank.forLevel(1) == .student)
        #expect(PilotRank.forLevel(10) == .commercial)
        #expect(PilotRank.forLevel(75) == .legend)
    }
}

@Suite struct ScoringTests {
    func good() -> FlightReport {
        FlightReport(aircraftID: "org.skyforge.sf1", arrivalICAO: "KMRY", landed: true,
                     touchdownSinkFPM: 90, touchdownOffsetM: 0.5, touchdownDistancePastThresholdM: 300)
    }
    @Test func perfectLandingScoresMax() { #expect(ChallengeScoring.landing(good()) == 1_000) }
    @Test func hardLandingScoresLess() {
        var r = good(); r.touchdownSinkFPM = 500
        #expect(ChallengeScoring.landing(r) < ChallengeScoring.landing(good()))
    }
    @Test func crashScoresZero() {
        var r = good(); r.crashed = true
        #expect(ChallengeScoring.landing(r) == 0)
        #expect(ChallengeScoring.aerobatics(r) == 0)
    }
    @Test func aerobaticRepeatsDecay() {
        let one = FlightReport(aircraftID: "a", aerobaticFigures: [.loop])
        let two = FlightReport(aircraftID: "a", aerobaticFigures: [.loop, .loop])
        let mixed = FlightReport(aircraftID: "a", aerobaticFigures: [.loop, .immelmann])
        #expect(ChallengeScoring.aerobatics(two) < ChallengeScoring.aerobatics(one) * 2)
        #expect(ChallengeScoring.aerobatics(mixed) > ChallengeScoring.aerobatics(two))
    }
    @Test func timeTrialPenalisesMissedGates() {
        let clean = FlightReport(aircraftID: "a", gatesPassed: 10, gatesTotal: 10, completionTimeS: 100)
        let missed = FlightReport(aircraftID: "a", gatesPassed: 8, gatesTotal: 10, completionTimeS: 100)
        #expect(ChallengeScoring.timeTrial(clean, parSeconds: 100) == 1_000)
        #expect(ChallengeScoring.timeTrial(missed, parSeconds: 100) < 1_000)
    }
    @Test func medalThresholds() {
        #expect(Medal.forScore(949, thresholds: [500, 700, 850, 950]) == .gold)
        #expect(Medal.forScore(950, thresholds: [500, 700, 850, 950]) == .platinum)
        #expect(Medal.forScore(10, thresholds: [500, 700, 850, 950]) == .none)
    }
    @Test func nonFiniteReportIsSanitised() {
        var r = good(); r.maxG = .nan; r.durationS = .infinity; r.touchdownSinkFPM = -Double.infinity
        let s = r.sanitized()
        #expect(s.maxG.isFinite && s.durationS.isFinite && (s.touchdownSinkFPM ?? 0).isFinite)
    }
}

func buyError(_ s: inout CareerState, _ id: String) -> CareerState.PurchaseError? {
    do { try s.buy(aircraftID: id); return nil } catch let e as CareerState.PurchaseError { return e } catch { return nil }
}
func isFailure(_ r: Result<Void, JobRejection>, _ e: JobRejection) -> Bool {
    if case .failure(let x) = r { return x == e }
    return false
}

@Suite struct EconomyTests {
    @Test func jobBoardIsDeterministic() {
        let a = JobBoard.generate(origin: kmry, airports: airports, dayIndex: 20_000, playerLevel: 3)
        let b = JobBoard.generate(origin: kmry, airports: airports, dayIndex: 20_000, playerLevel: 3)
        let c = JobBoard.generate(origin: kmry, airports: airports, dayIndex: 20_001, playerLevel: 3)
        #expect(a == b)
        #expect(a != c)
        #expect(a.allSatisfy { $0.origin.icao == "KMRY" && $0.destination.icao != "KMRY" && $0.basePay >= 100 })
    }
    @Test func emptyAirportListYieldsNoJobs() {
        #expect(JobBoard.generate(origin: kmry, airports: [kmry], dayIndex: 1, playerLevel: 1).isEmpty)
    }
    @Test func distanceKMRYtoKSFOisAbout124km() {
        let d = greatCircleDistanceM(kmry, ksfo) / 1000
        #expect(d > 110 && d < 140)
    }
    @Test func buyingChecksLevelAndFunds() {
        var s = CareerState()
        #expect(buyError(&s, "org.skyforge.sfc") == .levelTooLow(needed: 3))
        s.xp = Progression.xpForLevel(3)
        #expect(buyError(&s, "org.skyforge.sfc") == .insufficientFunds(short: 40_000))
        s.credits = 50_000
        #expect(buyError(&s, "org.skyforge.sfc") == nil)
        #expect(s.credits == 5_000 && s.ownedAircraft.contains("org.skyforge.sfc"))
        #expect(buyError(&s, "org.skyforge.sfc") == .alreadyOwned)
    }
    @Test func settlementPaysOnlyAtDestination() {
        let job = Job(id: "j", kind: .passenger, origin: kmry, destination: ksfo, distanceKm: 150, passengers: 2, cargoKg: 0,
                      deadlineMinutes: 60, basePay: 1_000, minLevel: 1, requiresRunwayM: 600, expiresDay: 9)
        var r = FlightReport(kind: .job(jobID: "j"), aircraftID: "org.skyforge.sfc", departureICAO: "KMRY", arrivalICAO: "KSFO", durationS: 1_800, distanceM: 140_000, landed: true,
                             touchdownSinkFPM: 100, maxG: 1.3, minG: 0.9, maxBankDeg: 25)
        let ok = JobSettler.settle(job: job, report: r, owned: false)
        #expect(ok.success && ok.net == 1_250)
        r.arrivalICAO = "KLAX"
        #expect(JobSettler.settle(job: job, report: r, owned: false).payout == 0)
        r.arrivalICAO = "KSFO"; r.crashed = true
        let crash = JobSettler.settle(job: job, report: r, owned: false)
        #expect(!crash.success && crash.damagePenalty == 500)
    }
}

@Suite struct EngineTests {
    @Test func firstFlightUnlocksAchievementsAndLevelsUp() {
        var s = CareerState()
        let r = FlightReport(aircraftID: "org.skyforge.sf1", arrivalICAO: "KMRY", durationS: 1_200, distanceM: 30_000, landed: true,
                             touchdownSinkFPM: 100, endedAt: 1_000)
        let out = CareerEngine.apply(r, to: &s)
        #expect(out.newAchievements.contains("first-flight"))
        #expect(out.newAchievements.contains("butter"))
        #expect(s.xp == s.log.last?.xpGained)
        #expect(s.level > 1)
        #expect(out.leveledUpTo == s.level)
        #expect(s.credits > Economy.startingCredits)
    }
    @Test func challengeMedalCannotBeFarmed() {
        var s = CareerState()
        let c = Challenge(id: "c1", type: .landing, title: "t", airportICAO: "KMRY", parSeconds: 0, medalThresholds: [500, 700, 850, 950],
                          crosswindKts: 0, visibilityKm: 10, cloudBaseFt: 3_000, aircraftID: "org.skyforge.sf1")
        let r = FlightReport(kind: .challenge(challengeID: "c1"), aircraftID: "org.skyforge.sf1", arrivalICAO: "KMRY", landed: true,
                             touchdownSinkFPM: 90, touchdownOffsetM: 0.5, touchdownDistancePastThresholdM: 300)
        let first = CareerEngine.apply(r, to: &s, challenge: c)
        let second = CareerEngine.apply(r, to: &s, challenge: c)
        #expect(first.medal == .platinum)
        #expect(first.creditsDelta >= Medal.platinum.credits)
        #expect(second.creditsDelta < Medal.bronze.credits)   // no second payout for the same medal
        #expect(s.challenges["c1"]?.attempts == 2)
        #expect(s.stats.goldMedals == 1)
    }
    @Test func jobFlowSettlesAndClearsActiveJob() {
        var s = CareerState()
        s.xp = Progression.xpForLevel(8)
        let sfc = Economy.spec("org.skyforge.sfc")!
        let job = Job(id: "j", kind: .cargo, origin: kmry, destination: ksfo, distanceKm: 150, passengers: 0, cargoKg: 100,
                      deadlineMinutes: 60, basePay: 800, minLevel: 1, requiresRunwayM: 600, expiresDay: 9)
        if case .failure = s.accept(job: job, aircraft: sfc) { Issue.record("first accept should succeed") }
        let second = s.accept(job: job, aircraft: sfc)
        #expect(isFailure(second, .alreadyHaveJob))
        let r = FlightReport(kind: .job(jobID: "j"), aircraftID: "org.skyforge.sfc", departureICAO: "KMRY", arrivalICAO: "KSFO", durationS: 1_800, distanceM: 140_000, landed: true, touchdownSinkFPM: 200)
        let out = CareerEngine.apply(r, to: &s)
        #expect(out.settlement?.success == true)
        #expect(s.activeJob == nil && s.stats.jobsCompleted == 1)
    }
    @Test func dailyStreakCountsConsecutiveDays() {
        var st = CareerStats()
        for d in [10, 11, 11, 12] { CareerEngine.updateStreak(&st, day: d) }
        #expect(st.dailyStreak == 3)
        CareerEngine.updateStreak(&st, day: 20)
        #expect(st.dailyStreak == 1 && st.bestDailyStreak == 3)
    }
    @Test func dailyChallengeIsStablePerDay() {
        let a = DailyChallenge.make(dayIndex: 123, airports: airports, aircraftIDs: ["a", "b"])
        #expect(a == DailyChallenge.make(dayIndex: 123, airports: airports, aircraftIDs: ["a", "b"]))
        #expect(a != DailyChallenge.make(dayIndex: 124, airports: airports, aircraftIDs: ["a", "b"]))
        #expect(DailyChallenge.make(dayIndex: 1, airports: [], aircraftIDs: ["a"]) == nil)
    }
    @Test func logIsCapped() {
        var s = CareerState()
        for i in 0..<(CareerState.maxLogEntries + 20) { CareerEngine.apply(FlightReport(aircraftID: "a", endedAt: i), to: &s) }
        #expect(s.log.count == CareerState.maxLogEntries)
    }
}

@Suite struct SaveTests {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sfcareer-\(UUID().uuidString)/career.json") }
    @Test func roundTrip() throws {
        let store = SaveStore(url: tmp())
        var s = CareerState(); s.pilotName = "Ada"; s.xp = 999; s.stats.airportsVisited = ["KMRY"]
        try store.save(s)
        #expect(try store.load() == s)
    }
    @Test func missingFileGivesFreshProfile() throws { #expect(try SaveStore(url: tmp()).load() == CareerState()) }
    @Test func corruptMainFallsBackToBackup() throws {
        let store = SaveStore(url: tmp())
        var s = CareerState(); s.xp = 500
        try store.save(s)
        s.xp = 600
        try store.save(s)                                   // backup now holds xp 500
        try Data("not json".utf8).write(to: store.url)
        #expect(try store.load().xp == 500)
    }
    @Test func bothCorruptThrowsInsteadOfWiping() throws {
        let store = SaveStore(url: tmp())
        try store.save(CareerState()); try store.save(CareerState())
        try Data("x".utf8).write(to: store.url); try Data("y".utf8).write(to: store.url.appendingPathExtension("bak"))
        #expect(throws: SaveStore.SaveError.unreadable) { try store.load() }
    }
    @Test func newerSaveVersionIsRefused() throws {
        let store = SaveStore(url: tmp())
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":999}"#.utf8).write(to: store.url)
        #expect(throws: SaveStore.SaveError.newerThanApp(999)) { try store.load() }
    }
}

@Suite struct CampaignTests {
    @Test func rewardsPayOnceAndUnlockAircraft() {
        var s = CareerState()
        #expect(s.progress(in: .airWing).completed == 0)
        s.completedMissions = ["wingman-formation", "intercept-bogey", "gunnery-range", "low-level-nav", "air-combat-training"]
        let first = s.claimCampaignRewards()
        #expect(first.credits == 17_500 && first.unlocked == ["org.skyforge.sff1"])
        #expect(s.progress(in: .airWing).isComplete)
        let again = s.claimCampaignRewards()
        #expect(again.credits == 0 && again.xp == 0 && again.unlocked.isEmpty)
    }
    @Test func nextStageIsFirstIncomplete() {
        var s = CareerState(); s.completedMissions = ["first-flight"]
        #expect(s.progress(in: .flightSchool).nextStage?.missionID == "pattern-landing")
    }
    @Test func missionAdapterFeedsEngine() {
        var s = CareerState()
        let r = FlightReport.fromMission(id: "first-flight", aircraftID: "org.skyforge.sf1", success: true, score: 300, elapsed: 400, kills: 0, crashed: false, endedAt: 5)
        CareerEngine.apply(r, to: &s)
        #expect(s.completedMissions.contains("first-flight"))
    }
}
