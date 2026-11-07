// SKYFORGE — Apache-2.0
// Fixed-timestep accumulator (Fiedler, "Fix Your Timestep") and a triple buffer for snapshots.
import Synchronization

/// Accumulates wall-clock frame time into fixed simulation steps.
public struct FixedStepClock: Sendable {
    public let dt: Double
    public let maxSubsteps: Int
    public private(set) var accumulator: Double = 0
    public private(set) var simTime: Double = 0
    public private(set) var stepCount: UInt64 = 0

    public init(dt: Double = 1.0 / 120.0, maxSubsteps: Int = 8) {
        self.dt = dt
        self.maxSubsteps = maxSubsteps
    }

    /// Adds frame time and returns how many fixed steps to run now. Excess time beyond
    /// `maxSubsteps` is dropped (spiral-of-death guard).
    public mutating func advance(frameTime: Double) -> Int {
        accumulator += max(0, min(frameTime, 0.25))
        var n = 0
        while accumulator >= dt && n < maxSubsteps {
            accumulator -= dt
            simTime += dt
            stepCount += 1
            n += 1
        }
        if n == maxSubsteps && accumulator >= dt { accumulator = accumulator.truncatingRemainder(dividingBy: dt) }
        return n
    }

    /// Interpolation factor for rendering between the previous and current state.
    public var alpha: Double { accumulator / dt }
}

/// Lock-protected triple buffer: the simulation publishes, the renderer reads the latest.
public final class TripleBuffer<Value: Sendable>: Sendable {
    private struct Slots: Sendable {
        var values: [Value]
        var latest: Int
        var sequence: UInt64
    }
    private let slots: Mutex<Slots>

    public init(initial: Value) {
        slots = Mutex(Slots(values: [initial, initial, initial], latest: 0, sequence: 0))
    }

    public func publish(_ value: Value) {
        slots.withLock { s in
            let next = (s.latest + 1) % 3
            s.values[next] = value
            s.latest = next
            s.sequence &+= 1
        }
    }

    /// Returns the most recently published value and its sequence number.
    public func read() -> (value: Value, sequence: UInt64) {
        slots.withLock { s in (s.values[s.latest], s.sequence) }
    }
}
