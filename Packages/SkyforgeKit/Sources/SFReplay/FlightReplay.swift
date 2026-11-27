public enum FlightReplayError: Error, Equatable, Sendable {
    case tooFewSamples
    case nonMonotonicTime
}

/// Immutable recording that can be sampled at any time.
public struct FlightReplay: Sendable {
    public let samples: [FlightSample]

    public init(samples: [FlightSample]) throws {
        guard samples.count >= 2 else { throw FlightReplayError.tooFewSamples }
        for i in 1..<samples.count where !(samples[i].time > samples[i - 1].time) {
            throw FlightReplayError.nonMonotonicTime
        }
        self.samples = samples
    }

    public var startTime: Double { samples[0].time }
    public var endTime: Double { samples[samples.count - 1].time }
    public var duration: Double { endTime - startTime }

    /// Interpolated state at `time`. Times outside the recording are clamped to the ends.
    public func sample(at time: Double) -> FlightSample {
        if time <= startTime { return samples[0] }
        if time >= endTime { return samples[samples.count - 1] }

        var lo = 0
        var hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].time <= time {
                lo = mid
            } else {
                hi = mid
            }
        }
        let a = samples[lo]
        let b = samples[hi]
        let span = b.time - a.time
        let t = span > 0 ? (time - a.time) / span : 0
        return FlightSample(
            time: time,
            position: a.position.lerp(to: b.position, t: t),
            orientation: Quat.slerp(a.orientation, b.orientation, t),
            airspeed: a.airspeed + (b.airspeed - a.airspeed) * t
        )
    }
}
