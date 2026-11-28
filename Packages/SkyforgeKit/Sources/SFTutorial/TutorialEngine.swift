// SKYFORGE — Apache-2.0
// Walks a new player through the lessons one frame at a time. Pure Swift, Linux-testable.
import Foundation

/// Where the tutorial goes after the last lesson. The flight school owns everything after this point.
public enum TutorialHandoff: Sendable, Equatable {
    case flightSchool
}

public struct TutorialEngine: Sendable {
    /// Seconds into a lesson before the first hint appears.
    public static let firstHintAfter: Double = 15
    /// Seconds into a lesson before the second hint appears and the player may skip.
    public static let secondHintAfter: Double = 30
    public static let skipAfter: Double = 60
    /// Holding time drains at this multiple of real time when the check stops being met, so a brief wobble
    /// does not throw the player back to the start of a lesson.
    static let drainFactor: Double = 2

    public private(set) var index: Int = 0
    public private(set) var holdTime: Double = 0
    public private(set) var timeInLesson: Double = 0
    public private(set) var progress = TutorialProgress()
    public private(set) var recovery: TutorialRecovery?
    public private(set) var completed: [TutorialLesson] = []
    /// Lessons in order. Override in tests to check a shorter route.
    public let lessons: [TutorialLesson]

    private var previousHeading: Double?

    public init(lessons: [TutorialLesson] = TutorialLesson.allCases) {
        self.lessons = lessons
    }

    /// The lesson the player is on, or nil once the tutorial is finished.
    public var current: TutorialLesson? {
        index < lessons.count ? lessons[index] : nil
    }

    public var isFinished: Bool { current == nil }

    public var handoff: TutorialHandoff? { isFinished ? .flightSchool : nil }

    /// 0…1 share of lessons done.
    public var fraction: Double {
        lessons.isEmpty ? 1 : Double(index) / Double(lessons.count)
    }

    /// The hint to show right now, or nil while the player is still getting going.
    public var currentHint: String? {
        guard let lesson = current else { return nil }
        if timeInLesson >= Self.secondHintAfter, lesson.hints.count > 1 { return lesson.hints[1] }
        if timeInLesson >= Self.firstHintAfter, let first = lesson.hints.first { return first }
        return nil
    }

    /// True once the player has been stuck long enough to be offered a skip.
    public var canSkip: Bool {
        current != nil && timeInLesson >= Self.skipAfter
    }

    /// Feed one frame of aircraft state. `dt` is the frame time in seconds.
    public mutating func update(_ s: TutorialSnapshot, dt: Double) {
        guard let lesson = current, dt.isFinite, dt > 0, s.isFinite else { return }
        timeInLesson += dt
        trackHeading(s)
        if s.onGround == false { progress.sawAirborne = true }

        recovery = lesson.recovery(s)
        if let warning = recovery, let back = warning.returnTo, let target = lessons.firstIndex(of: back), target < index {
            // Go-around: step back to an earlier lesson but keep what the player already did, and keep the message on screen.
            index = target
            resetLessonMemory()
            recovery = warning
            return
        }

        if lesson.requiresConfirm { return }

        if lesson.isMet(s, progress) {
            holdTime += dt
            if holdTime >= lesson.holdSeconds { advance() }
        } else {
            holdTime = max(0, holdTime - Self.drainFactor * dt)
        }
    }

    /// Starts the current lesson again from the top, for example after a crash. Completed lessons stay done.
    public mutating func restartLesson() {
        resetLessonMemory()
    }

    /// The player tapped Got it on a confirm-only lesson.
    public mutating func confirm() {
        guard let lesson = current, lesson.requiresConfirm else { return }
        advance(from: lesson)
    }

    /// The player asked to skip a lesson they are stuck on. Only allowed after the skip delay.
    public mutating func skip() {
        guard canSkip, let lesson = current else { return }
        advance(from: lesson)
    }

    private mutating func advance(from lesson: TutorialLesson? = nil) {
        guard let done = lesson ?? current else { return }
        // A lesson re-flown after a go-around is completed again; it is listed once.
        if !completed.contains(done) { completed.append(done) }
        index += 1
        resetLessonMemory()
    }

    private mutating func resetLessonMemory() {
        holdTime = 0
        timeInLesson = 0
        progress = TutorialProgress()
        recovery = nil
        previousHeading = nil
    }

    private mutating func trackHeading(_ s: TutorialSnapshot) {
        if let prev = previousHeading {
            progress.headingTurned += abs(TutorialLesson.headingDelta(from: prev, to: s.headingDeg))
        }
        previousHeading = s.headingDeg
    }
}
