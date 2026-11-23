// SKYFORGE — Apache-2.0
// Tampered saves must sanitise to safe values instead of trapping or growing without bound.
import Testing
import Foundation
@testable import SFCareer

@Suite("Save tampering")
struct SaveTamperTests {
    @Test func challengeAttemptsAreClamped() {
        var s = CareerState()
        s.challenges["daily-3"] = ChallengeRecord(bestScore: 5, medal: .none, attempts: Int.max)
        s.sanitize()
        #expect(s.challenges["daily-3"]?.attempts == 1_000_000)
    }

    @Test func challengeScoreIsFiniteAndBounded() {
        var s = CareerState()
        s.challenges["daily-4"] = ChallengeRecord(bestScore: .infinity, medal: .none, attempts: 1)
        s.sanitize()
        #expect(s.challenges["daily-4"]?.bestScore == 0)
    }

    @Test func badChallengeKeysAreDropped() {
        var s = CareerState()
        s.challenges["bad key!"] = ChallengeRecord(bestScore: 1, medal: .none, attempts: 1)
        s.sanitize()
        #expect(s.challenges["bad key!"] == nil)
    }
}
