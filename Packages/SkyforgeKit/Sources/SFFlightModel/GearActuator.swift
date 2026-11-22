// SKYFORGE — Apache-2.0
// Landing-gear travel: moves the gear position toward the commanded position at a fixed rate. Pure value
// type; the orchestrator keeps one and feeds `position` to `ControlInputs.gear`.
import Foundation

public struct GearActuator: Sendable, Equatable {
    /// Actual gear position, 0 retracted … 1 extended.
    public private(set) var position: Double
    /// Seconds for a full retraction or extension.
    public var travelTime: Double

    public init(position: Double = 1, travelTime: Double = 6) {
        self.position = min(1, max(0, position)); self.travelTime = travelTime
    }

    public var isDownAndLocked: Bool { position >= 1 }
    public var isUpAndLocked: Bool { position <= 0 }
    public var inTransit: Bool { position > 0 && position < 1 }

    /// Advances toward `commandDown` (true = extend). Returns the new position.
    @discardableResult
    public mutating func update(commandDown: Bool, dt: Double) -> Double {
        guard dt.isFinite, dt > 0, travelTime > 0 else { return position }
        let step = dt / travelTime
        position = commandDown ? min(1, position + step) : max(0, position - step)
        return position
    }
}
