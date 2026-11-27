import Testing
import Foundation
@testable import SFGameplay

private func passingResult(_ m: MissionDefinition) -> MissionResult {
    MissionResult(missionID: m.id, aircraftID: "test", success: true, failureReason: nil, score: m.maxBasePoints,
                  medal: .gold, elapsed: 100, objectivesCompleted: m.objectives.count, breakdown: [:])
}

private func failingResult(_ m: MissionDefinition, reason: String? = "Hard landing") -> MissionResult {
    MissionResult(missionID: m.id, aircraftID: "test", success: false, failureReason: reason, score: 0,
                  medal: .none, elapsed: 50, objectivesCompleted: 0, breakdown: [:])
}

@Suite struct FlightSchoolTests {
    @Test func everyLessonFliesASoundExistingMission() {
        for lesson in FlightSchoolCurriculum.lessons {
            let mission = MissionCatalog.mission(id: lesson.missionID)
            #expect(mission != nil, "\(lesson.id) names a missing mission")
            #expect(mission?.validationProblems.isEmpty == true, "\(lesson.id) mission is not sound")
        }
    }

    @Test func lessonIDsAreUnique() {
        let ids = FlightSchoolCurriculum.lessons.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func onlyTheFirstLessonIsOpenAtStart() {
        let progress = FlightSchoolProgress()
        let course = FlightSchoolCurriculum.lessons
        #expect(progress.isUnlocked(course[0]))
        #expect(!progress.isUnlocked(course[1]))
        #expect(progress.nextLesson?.id == course[0].id)
    }

    @Test func lockedLessonCannotBeRecorded() {
        var progress = FlightSchoolProgress()
        let lesson = FlightSchoolCurriculum.lessons[1]
        let mission = MissionCatalog.mission(id: lesson.missionID)!
        #expect(progress.record(lesson: lesson, result: passingResult(mission)) == nil)
        #expect(progress.completedLessonIDs.isEmpty)
    }

    @Test func checkrideFailsWithPlainReasons() {
        let lesson = FlightSchoolCurriculum.lessons.first { $0.id == "fs-ppl-checkride" }!
        let mission = MissionCatalog.mission(id: lesson.missionID)!
        let weak = MissionResult(missionID: mission.id, aircraftID: "test", success: true, failureReason: nil, score: 50,
                                 medal: .bronze, elapsed: 100, objectivesCompleted: 1, breakdown: [:])
        let verdict = lesson.verdict(for: weak, mission: mission)
        #expect(!verdict.passed)
        #expect(verdict.reasons.count == 2)
        #expect(verdict.debrief.hasPrefix("Not yet."))
    }

    @Test func ordinaryLessonPassesOnSuccessAlone() {
        let lesson = FlightSchoolCurriculum.lessons[0]
        let mission = MissionCatalog.mission(id: lesson.missionID)!
        #expect(lesson.verdict(for: passingResult(mission), mission: mission).passed)
        let failed = lesson.verdict(for: failingResult(mission), mission: mission)
        #expect(!failed.passed && failed.reasons == ["The flight ended early: Hard landing."])
    }

    @Test func passingTheWholeCourseGrantsBothLicences() {
        var progress = FlightSchoolProgress()
        for lesson in FlightSchoolCurriculum.lessons {
            let mission = MissionCatalog.mission(id: lesson.missionID)!
            let verdict = progress.record(lesson: lesson, result: passingResult(mission))
            #expect(verdict?.passed == true, "\(lesson.id) should pass")
        }
        #expect(progress.holds(.privatePilot))
        #expect(progress.holds(.instrumentRating))
        #expect(progress.nextLesson == nil)
    }

    @Test func failedCheckrideGrantsNothingAndCountsAttempt() {
        var progress = FlightSchoolProgress()
        let course = FlightSchoolCurriculum.lessons
        for lesson in course.prefix(3) {
            progress.record(lesson: lesson, result: passingResult(MissionCatalog.mission(id: lesson.missionID)!))
        }
        let checkride = course[3]
        let mission = MissionCatalog.mission(id: checkride.missionID)!
        let verdict = progress.record(lesson: checkride, result: failingResult(mission))
        #expect(verdict?.passed == false)
        #expect(!progress.holds(.privatePilot))
        #expect(!progress.isCompleted(checkride))
        #expect(progress.checkrideAttempts[checkride.id] == 1)
    }

    @Test func loadDropsUnknownAndDuplicateLessons() throws {
        let json = #"{"completedLessonIDs":["fs-discovery","fs-discovery","bogus"],"licences":["privatePilot","privatePilot"],"checkrideAttempts":{"bogus":4,"fs-ppl-checkride":-2}}"#
        let progress = try JSONDecoder().decode(FlightSchoolProgress.self, from: Data(json.utf8))
        #expect(progress.completedLessonIDs == ["fs-discovery"])
        #expect(progress.licences == [.privatePilot])
        #expect(progress.checkrideAttempts == ["fs-ppl-checkride": 0])
    }

    @Test func progressRoundTrips() throws {
        var progress = FlightSchoolProgress()
        let lesson = FlightSchoolCurriculum.lessons[0]
        progress.record(lesson: lesson, result: passingResult(MissionCatalog.mission(id: lesson.missionID)!))
        let data = try JSONEncoder().encode(progress)
        let back = try JSONDecoder().decode(FlightSchoolProgress.self, from: data)
        #expect(back == progress)
    }
}
