// SKYFORGE — Apache-2.0
// Per-tick wake bookkeeping for the sim loop. The owner of the aircraft list calls `emit` for each heavy
// aircraft (typically once per flight-path sample), calls `step` once per tick, and passes `active` to the
// follower's `FlightEnvironment.wakes`. Pairs decay and are dropped once they are negligible.
import Foundation

public struct WakeTracker: Sendable, Equatable {
    public private(set) var pairs: [WakeVortexPair] = []
    /// Maximum number of live pairs; the oldest is dropped first.
    public var capacity: Int
    /// Pairs whose strength falls below this fraction of their birth strength are removed.
    public var negligibleFraction: Double

    public init(capacity: Int = 64, negligibleFraction: Double = 0.02) {
        self.capacity = max(1, capacity)
        self.negligibleFraction = min(0.5, max(0, negligibleFraction))
    }

    /// Adds a pair emitted by a heavy aircraft.
    public mutating func emit(_ pair: WakeVortexPair) {
        pairs.append(pair)
        if pairs.count > capacity { pairs.removeFirst(pairs.count - capacity) }
    }

    /// Ages every pair by `dt` seconds and removes the negligible ones.
    public mutating func step(dt: Double) {
        guard dt.isFinite, dt > 0 else { return }
        for i in pairs.indices { pairs[i].age += dt }
        pairs.removeAll { p in
            let birth = abs(p.circulation)
            return birth == 0 || abs(p.strength) < negligibleFraction * birth
        }
    }

    /// Pairs to pass to a follower's environment.
    public var active: [WakeVortexPair] { pairs }
}
