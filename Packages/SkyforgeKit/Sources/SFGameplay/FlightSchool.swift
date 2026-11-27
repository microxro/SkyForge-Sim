// SKYFORGE — Apache-2.0
// Flight school: a linear course of lessons that ends in licences. A lesson flies an existing mission
// definition. A checkride flies one too, but must meet stricter criteria, and passing it grants the
// licence. Pure and deterministic, so the instructor's verdict can be tested without the simulator.
import Foundation

public enum Licence: String, Sendable, Codable, CaseIterable {
    case privatePilot, instrumentRating

    public var displayName: String {
        switch self {
        case .privatePilot: return "Private Pilot Licence"
        case .instrumentRating: return "Instrument Rating"
        }
    }
}

public enum LessonKind: String, Sendable, Codable {
    case lesson, checkride
}

/// Pass standard for a checkride, applied on top of the mission's own success test.
public struct CheckrideCriteria: Sendable, Codable, Equatable {
    /// Lowest score as a fraction of the mission's base points.
    public var minScoreFraction: Double
    /// Every objective must be completed, not just most of them.
    public var requireAllObjectives: Bool
    /// Lowest medal that passes.
    public var minimumMedal: MissionMedal

    public init(minScoreFraction: Double, requireAllObjectives: Bool = true, minimumMedal: MissionMedal = .none) {
        self.minScoreFraction = minScoreFraction
        self.requireAllObjectives = requireAllObjectives
        self.minimumMedal = minimumMedal
    }

    /// Instructor's verdict on a flown mission. Every failed standard adds one reason.
    public func evaluate(_ result: MissionResult, mission: MissionDefinition) -> CheckrideVerdict {
        var reasons: [String] = FlightSchoolCurriculum.failureReasons(result)
        let base = max(1, mission.maxBasePoints)
        let fraction = Double(max(0, result.score)) / Double(base)
        if fraction < minScoreFraction {
            reasons.append("Score \(Int(fraction * 100))% is below the \(Int(minScoreFraction * 100))% standard.")
        }
        if requireAllObjectives && result.objectivesCompleted < mission.objectives.count {
            reasons.append("Only \(result.objectivesCompleted) of \(mission.objectives.count) objectives were completed.")
        }
        if result.medal < minimumMedal {
            reasons.append("The \(minimumMedal.displayName) medal standard was not met.")
        }
        return CheckrideVerdict(passed: reasons.isEmpty, reasons: reasons)
    }
}

/// The instructor's verdict on one flight, with the reasons in plain words.
public struct CheckrideVerdict: Sendable, Codable, Equatable {
    public var passed: Bool
    public var reasons: [String]

    public init(passed: Bool, reasons: [String]) {
        self.passed = passed
        self.reasons = reasons
    }

    /// One line the instructor says after the flight.
    public var debrief: String {
        passed ? "Well flown. That one counts." : "Not yet. " + reasons.joined(separator: " ")
    }
}

public struct FlightLesson: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var kind: LessonKind
    /// Mission flown for this lesson. Must exist in `MissionCatalog`.
    public var missionID: String
    /// Licence this lesson counts toward.
    public var licence: Licence
    /// What the instructor says before the flight, one line each.
    public var instructorBriefing: [String]
    /// Pass standard for a checkride. Nil for an ordinary lesson, which passes when the mission succeeds.
    public var criteria: CheckrideCriteria?

    public init(id: String, title: String, kind: LessonKind, missionID: String, licence: Licence,
                instructorBriefing: [String], criteria: CheckrideCriteria? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.missionID = missionID
        self.licence = licence
        self.instructorBriefing = instructorBriefing
        self.criteria = criteria
    }

    /// Verdict for a flown mission. Ordinary lessons pass on mission success alone.
    public func verdict(for result: MissionResult, mission: MissionDefinition) -> CheckrideVerdict {
        if let criteria {
            return criteria.evaluate(result, mission: mission)
        }
        let reasons = FlightSchoolCurriculum.failureReasons(result)
        return CheckrideVerdict(passed: result.success && reasons.isEmpty, reasons: reasons)
    }
}

public enum FlightSchoolCurriculum {
    /// Ordered course. A lesson unlocks when every lesson before it is complete.
    public static let lessons: [FlightLesson] = [
        FlightLesson(
            id: "fs-discovery", title: "Discovery Flight", kind: .lesson, missionID: "first-flight", licence: .privatePilot,
            instructorBriefing: ["Welcome. We take off, climb to 1,500 feet and fly to the marker.",
                                 "Keep the wings level and hold the climb attitude."]),
        FlightLesson(
            id: "fs-circuit", title: "Traffic Pattern", kind: .lesson, missionID: "pattern-landing", licence: .privatePilot,
            instructorBriefing: ["Fly the rectangle at 1,000 feet. Call each turn.",
                                 "On final, aim for the three-degree path, not the runway edge."]),
        FlightLesson(
            id: "fs-crosswind", title: "Crosswind Landing", kind: .lesson, missionID: "precision-landing", licence: .privatePilot,
            instructorBriefing: ["Crab into the wind on final, then kick out the drift before touchdown.",
                                 "A gentle touchdown in the zone beats a fast one."]),
        FlightLesson(
            id: "fs-ppl-checkride", title: "Private Pilot Checkride", kind: .checkride, missionID: "precision-landing",
            licence: .privatePilot,
            instructorBriefing: ["This is your checkride. I will be quiet and watch.",
                                 "Land in the zone with a silver medal or better and you pass."],
            criteria: CheckrideCriteria(minScoreFraction: 0.8, requireAllObjectives: true, minimumMedal: .silver)),
        FlightLesson(
            id: "fs-instrument-approach", title: "Instrument Approach", kind: .lesson, missionID: "ifr-approach",
            licence: .instrumentRating,
            instructorBriefing: ["Fly the glideslope by instruments only. Stay on the centreline.",
                                 "Three seconds out of band is the limit."]),
        FlightLesson(
            id: "fs-ir-checkride", title: "Instrument Rating Checkride", kind: .checkride, missionID: "ifr-approach",
            licence: .instrumentRating,
            instructorBriefing: ["Instrument checkride. Hold the approach from start to touchdown."],
            criteria: CheckrideCriteria(minScoreFraction: 0.85, requireAllObjectives: true, minimumMedal: .silver)),
    ]

    public static func lesson(id: String) -> FlightLesson? { lessons.first { $0.id == id } }

    /// Plain-words reasons a flight did not succeed. Empty when it did.
    static func failureReasons(_ result: MissionResult) -> [String] {
        if result.success { return [] }
        if let why = result.failureReason, !why.isEmpty { return ["The flight ended early: \(why)."] }
        return ["The flight did not meet the mission goals."]
    }
}

/// A pilot's place in the course. Stored as small versioned JSON; unknown lessons are dropped on load.
public struct FlightSchoolProgress: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public var version = FlightSchoolProgress.currentVersion
    /// Passed lessons and checkrides, in the order they were passed.
    public var completedLessonIDs: [String] = []
    /// Licences granted by passed checkrides, in the order they were granted.
    public var licences: [Licence] = []
    /// Checkride attempts per checkride lesson id.
    public var checkrideAttempts: [String: Int] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case version, completedLessonIDs, licences, checkrideAttempts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        completedLessonIDs = try c.decodeIfPresent([String].self, forKey: .completedLessonIDs) ?? []
        licences = try c.decodeIfPresent([Licence].self, forKey: .licences) ?? []
        checkrideAttempts = try c.decodeIfPresent([String: Int].self, forKey: .checkrideAttempts) ?? [:]
        sanitize()
    }

    /// Keeps only known lessons, each once, and clamps attempt counts.
    mutating func sanitize() {
        let known = Set(FlightSchoolCurriculum.lessons.map(\.id))
        var seen = Set<String>()
        completedLessonIDs = completedLessonIDs.filter { known.contains($0) && seen.insert($0).inserted }
        var uniqueLicences: [Licence] = []
        for l in licences where !uniqueLicences.contains(l) { uniqueLicences.append(l) }
        licences = uniqueLicences
        checkrideAttempts = checkrideAttempts.filter { known.contains($0.key) }
            .mapValues { min(MissionRecord.limit, max(0, $0)) }
    }

    public func isCompleted(_ lesson: FlightLesson) -> Bool { completedLessonIDs.contains(lesson.id) }

    public func holds(_ licence: Licence) -> Bool { licences.contains(licence) }

    /// A lesson is open when every lesson before it in the course is complete.
    public func isUnlocked(_ lesson: FlightLesson) -> Bool {
        let course = FlightSchoolCurriculum.lessons
        guard let index = course.firstIndex(where: { $0.id == lesson.id }) else { return false }
        return course[..<index].allSatisfy { isCompleted($0) }
    }

    /// The first lesson not yet passed, or nil when the course is finished.
    public var nextLesson: FlightLesson? {
        FlightSchoolCurriculum.lessons.first { !isCompleted($0) }
    }

    /// Records a flown lesson. Returns nil when the lesson is locked or its mission is unknown.
    /// A passed checkride grants its licence. A failed one changes nothing but the attempt count.
    @discardableResult
    public mutating func record(lesson: FlightLesson, result: MissionResult) -> CheckrideVerdict? {
        guard isUnlocked(lesson), let mission = MissionCatalog.mission(id: lesson.missionID) else { return nil }
        let verdict = lesson.verdict(for: result, mission: mission)
        if lesson.kind == .checkride {
            checkrideAttempts[lesson.id] = min(MissionRecord.limit, (checkrideAttempts[lesson.id] ?? 0) + 1)
        }
        if verdict.passed {
            if !isCompleted(lesson) { completedLessonIDs.append(lesson.id) }
            if lesson.kind == .checkride && !holds(lesson.licence) { licences.append(lesson.licence) }
        }
        return verdict
    }
}
