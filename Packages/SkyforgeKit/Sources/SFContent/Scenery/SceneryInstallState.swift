// SKYFORGE — Apache-2.0
// The install state machine for whole-Earth scenery. Pure: the UI and the Background Assets backend
// send events, and the machine decides the next phase. Illegal events leave the state unchanged.
import Foundation

public enum SceneryFailure: Equatable, Sendable {
    case insufficientStorage(shortBy: Int64)
    case quotaExceeded(overBy: Int64)
    case waitingForWiFi
    case network
    case integrity(segment: String)
    case backend(String)
}

public enum ScenerySyncPhase: Equatable, Sendable {
    /// Nothing installed. The base game flies with procedural scenery.
    case notInstalled
    /// The player must agree to the download size before any bytes move (App Store Guideline 4.2.3).
    case awaitingConsent(requiredBytes: Int64)
    case downloading(completedBytes: Int64, totalBytes: Int64)
    case paused(completedBytes: Int64, totalBytes: Int64)
    case verifying(totalBytes: Int64)
    case installed(release: String, bytes: Int64)
    case failed(SceneryFailure, retryable: Bool, totalBytes: Int64)
}

public enum ScenerySyncEvent: Equatable, Sendable {
    case requestInstall(requiredBytes: Int64)
    case consentGiven
    case consentDeclined
    case progress(completedBytes: Int64)
    case pause
    case resume
    case downloadsFinished
    case verified(release: String)
    case failed(SceneryFailure, retryable: Bool)
    case remove
}

public struct ScenerySyncMachine: Sendable, Equatable {
    public private(set) var phase: ScenerySyncPhase

    public init(phase: ScenerySyncPhase = .notInstalled) { self.phase = phase }

    /// Applies an event. Returns false and leaves the phase unchanged when the event is not valid here.
    @discardableResult
    public mutating func apply(_ event: ScenerySyncEvent) -> Bool {
        guard let next = ScenerySyncMachine.next(from: phase, on: event) else { return false }
        phase = next
        return true
    }

    static func next(from phase: ScenerySyncPhase, on event: ScenerySyncEvent) -> ScenerySyncPhase? {
        switch (phase, event) {
        case (.notInstalled, .requestInstall(let n)) where n > 0:
            return .awaitingConsent(requiredBytes: n)
        case (.failed(_, _, _), .requestInstall(let n)) where n > 0:
            return .awaitingConsent(requiredBytes: n)

        case (.awaitingConsent(let n), .consentGiven):
            return .downloading(completedBytes: 0, totalBytes: n)
        case (.awaitingConsent, .consentDeclined):
            return .notInstalled

        case (.downloading(_, let total), .progress(let c)):
            return .downloading(completedBytes: min(max(c, 0), total), totalBytes: total)
        case (.downloading(let c, let total), .pause):
            return .paused(completedBytes: c, totalBytes: total)
        case (.paused(let c, let total), .resume):
            return .downloading(completedBytes: c, totalBytes: total)
        case (.failed(_, true, let total), .resume):
            return .downloading(completedBytes: 0, totalBytes: total)
        case (.downloading(_, let total), .downloadsFinished):
            return .verifying(totalBytes: total)
        case (.verifying(let total), .verified(let release)):
            return .installed(release: release, bytes: total)

        case (.downloading(_, let total), .failed(let f, let retry)),
             (.paused(_, let total), .failed(let f, let retry)),
             (.verifying(let total), .failed(let f, let retry)):
            return .failed(f, retryable: retry, totalBytes: total)

        case (_, .remove):
            return .notInstalled

        default:
            return nil
        }
    }
}
