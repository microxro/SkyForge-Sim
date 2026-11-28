// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFCareer

@Suite struct FirefightingCareerTests {
    @Test func containedFastAccurateFireScoresBonuses() {
        let s = FireIncidentSummary(burnedHectares: 2, contained: true, drops: 2, accurateDrops: 2, elapsed: 300)
        // 500 base + 2 accurate drops at 100 + fast containment at 200.
        #expect(FirefightingScoring.score(s) == 900)
    }

    @Test func wastedDropsCostPoints() {
        let s = FireIncidentSummary(burnedHectares: 9, contained: true, drops: 5, accurateDrops: 1, elapsed: 1_000)
        // 500 base + 100 accurate - 4 wasted at 20, and no fast bonus.
        #expect(FirefightingScoring.score(s) == 520)
    }

    @Test func lostFireScoresNothing() {
        let s = FireIncidentSummary(burnedHectares: 40, contained: false, drops: 9, accurateDrops: 9, elapsed: 500)
        #expect(FirefightingScoring.score(s) == 0)
    }

    @Test func badNumbersAreClamped() {
        let s = FireIncidentSummary(burnedHectares: .nan, contained: true, drops: -3, accurateDrops: 7, elapsed: .infinity).sanitized
        #expect(s.burnedHectares == 0)
        #expect(s.drops == 0)
        #expect(s.accurateDrops == 0)
        #expect(s.elapsed == 0)
    }

    @Test func rankFollowsContainedCount() {
        #expect(FirefightingRank.forContained(-5) == .trainee)
        #expect(FirefightingRank.forContained(2) == .trainee)
        #expect(FirefightingRank.forContained(3) == .scooper)
        #expect(FirefightingRank.forContained(8) == .leadScooper)
        #expect(FirefightingRank.forContained(40) == .divisionBoss)
        #expect(FirefightingRank.forContained(10_000) == .divisionBoss)
    }

    @Test func settlingContainedFirePaysAndRanksUp() {
        var c = CareerState()
        let start = c.credits
        let fast = FireIncidentSummary(burnedHectares: 2, contained: true, drops: 2, accurateDrops: 2, elapsed: 300)
        let first = c.settleFireIncident(fast)
        #expect(first.score == 900)
        #expect(first.credits == 4_500)
        #expect(c.credits == start + 4_500)
        #expect(!first.rankedUp)
        c.settleFireIncident(fast)
        let third = c.settleFireIncident(fast)
        #expect(third.rankedUp)
        #expect(third.rankAfter == .scooper)
        #expect(c.firefighting.contained == 3)
        #expect(c.firefighting.bestScore == 900)
    }

    @Test func lostFireIsRecordedAndPaysNothing() {
        var c = CareerState()
        let start = c.credits
        let lost = FireIncidentSummary(burnedHectares: 60, contained: false, drops: 4, accurateDrops: 1, elapsed: 900)
        let r = c.settleFireIncident(lost)
        #expect(r.credits == 0)
        #expect(c.credits == start)
        #expect(c.firefighting.incidents == 1)
        #expect(c.firefighting.lost == 1)
        #expect(c.firefighting.contained == 0)
        #expect(c.firefighting.drops == 4)
        #expect(c.firefighting.accurateDrops == 1)
    }

    @Test func careerRoundTripsAndOldSavesStillLoad() throws {
        var c = CareerState()
        c.settleFireIncident(FireIncidentSummary(burnedHectares: 1, contained: true, drops: 1, accurateDrops: 1, elapsed: 100))
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(CareerState.self, from: data) == c)

        // A save written before the firefighting record existed has no "firefighting" key.
        var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        obj.removeValue(forKey: "firefighting")
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(CareerState.self, from: old)
        #expect(back.firefighting == FirefightingRecord())
    }
}
