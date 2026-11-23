// SKYFORGE — Apache-2.0
// Engine-out state machine for training and gameplay: an engine can fail, stay windmilling, and be
// relit in flight. A relight needs airspeed above a windmill threshold and takes a fixed time; if the
// airspeed falls below the threshold during the relight, the attempt is aborted. The failure mask it
// produces feeds `ControlInputs.engineFailureMask`.
import Foundation

public struct EngineOperations: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running
        case failed
        case relighting(remaining: Double)
    }

    public private(set) var states: [State]
    /// Seconds a relight takes once started (ignition, fuel flow and spool-up).
    public var relightTime: Double
    /// Minimum true airspeed (m/s) to start or keep a relight; below it the windmill is too weak.
    public var minRelightSpeed: Double

    public init(engineCount: Int, relightTime: Double = 15, minRelightSpeed: Double = 55) {
        let n = min(8, max(0, engineCount))
        self.states = Array(repeating: .running, count: n)
        self.relightTime = relightTime.isFinite ? max(0, relightTime) : 15
        self.minRelightSpeed = minRelightSpeed.isFinite ? max(0, minRelightSpeed) : 55
    }

    public var engineCount: Int { states.count }

    /// Count of engines producing thrust.
    public var runningCount: Int { states.filter { $0 == .running }.count }

    /// Bit i is set while engine i produces no thrust (failed, windmilling or relighting).
    public var failureMask: Int {
        var mask = 0
        for (i, s) in states.enumerated() where s != .running { mask |= 1 << i }
        return mask
    }

    /// Fails a running engine. Returns false when the index is invalid or the engine was not running.
    @discardableResult
    public mutating func fail(_ i: Int) -> Bool {
        guard states.indices.contains(i), states[i] == .running else { return false }
        states[i] = .failed
        return true
    }

    /// Starts a relight on a failed engine. Returns false when the engine is not failed or the
    /// airspeed is below the windmill threshold.
    @discardableResult
    public mutating func requestRestart(_ i: Int, trueAirspeed: Double) -> Bool {
        guard states.indices.contains(i), states[i] == .failed else { return false }
        guard trueAirspeed.isFinite, trueAirspeed >= minRelightSpeed else { return false }
        states[i] = .relighting(remaining: relightTime)
        return true
    }

    /// Advances relights. A relight that completes sets the engine to running; one whose airspeed
    /// drops below the threshold reverts to failed.
    public mutating func update(dt: Double, trueAirspeed: Double) {
        guard dt.isFinite, dt > 0 else { return }
        let fast = trueAirspeed.isFinite && trueAirspeed >= minRelightSpeed
        for i in states.indices {
            guard case .relighting(let remaining) = states[i] else { continue }
            if !fast {
                states[i] = .failed
            } else if remaining - dt <= 0 {
                states[i] = .running
            } else {
                states[i] = .relighting(remaining: remaining - dt)
            }
        }
    }
}
