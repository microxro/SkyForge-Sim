/// Records flight samples while flying.
/// Keeps time strictly increasing, drops samples closer than `minInterval`,
/// and caps memory by discarding the oldest samples past `capacity`.
public struct FlightRecorder: Sendable {
    public let capacity: Int
    public let minInterval: Double
    public private(set) var samples: [FlightSample] = []

    public init(capacity: Int = 36_000, minInterval: Double = 1.0 / 30.0) {
        self.capacity = max(2, capacity)
        self.minInterval = max(0, minInterval)
    }

    /// Returns true when the sample was stored.
    @discardableResult
    public mutating func record(_ sample: FlightSample) -> Bool {
        guard sample.time.isFinite else { return false }
        if let last = samples.last {
            guard sample.time > last.time else { return false }
            guard sample.time - last.time >= minInterval else { return false }
        }
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        return true
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
