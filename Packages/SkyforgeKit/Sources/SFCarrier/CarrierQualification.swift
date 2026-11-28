// SKYFORGE — Apache-2.0
// Carrier qualification: a run of traps graded by the LSO. Bolters and wave-offs are attempts;
// caught wires and overruns are graded. The run ends after four graded traps or eight attempts.
import Foundation

public struct CarrierQualification: Sendable, Codable, Equatable {
    public static let gradedTrapsRequired = 4
    public static let maxAttempts = 8
    public static let passesRequired = 3       // graded traps at OK, (OK) or Fair, with no Unsat

    public struct Attempt: Sendable, Codable, Equatable {
        public var outcome: TrapOutcome
        public var grade: LSOGrade
    }

    public private(set) var attempts: [Attempt] = []

    public init() {}

    /// Traps the hook caught, and overruns (too fast or past the stern), which the LSO grades Unsat.
    public var gradedAttempts: [Attempt] {
        attempts.filter {
            switch $0.outcome {
            case .wire, .overrun: return true
            case .bolter, .waveOff: return false
            }
        }
    }

    public var isFinished: Bool {
        gradedAttempts.count >= Self.gradedTrapsRequired || attempts.count >= Self.maxAttempts
    }

    /// Qualified when the run has finished, no graded trap was Unsat, and enough graded traps passed.
    public var qualified: Bool {
        guard isFinished else { return false }
        let graded = gradedAttempts
        if graded.contains(where: { $0.grade == .unsat }) { return false }
        return graded.filter { $0.grade.isPass }.count >= Self.passesRequired
    }

    public var score: Int { attempts.reduce(0) { $0 + $1.grade.points } }

    /// Record one trap. Once the run has finished, further calls are ignored.
    public mutating func record(_ trap: TrapApproach, result: TrapResult) {
        guard !isFinished else { return }
        attempts.append(Attempt(outcome: result.outcome, grade: LSO.grade(trap, result)))
    }
}
