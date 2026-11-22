// SKYFORGE — Apache-2.0
// Turns a stream of per-frame flight samples into one touchdown event, so free flights can be scored
// as landings. Pure and deterministic: the sim feeds samples, the detector never touches the sim.
import Foundation

public struct TouchdownSample: Sendable, Equatable {
    public var time: Double
    /// Height above the runway surface (m).
    public var heightAGLM: Double
    /// Descent rate (m/s), positive = sinking.
    public var sinkMPS: Double
    /// Lateral offset from the runway centreline (m), signed.
    public var offsetM: Double
    /// Distance past the landing threshold (m).
    public var distancePastThresholdM: Double
    public init(time: Double, heightAGLM: Double, sinkMPS: Double, offsetM: Double, distancePastThresholdM: Double) {
        self.time = time; self.heightAGLM = heightAGLM; self.sinkMPS = sinkMPS
        self.offsetM = offsetM; self.distancePastThresholdM = distancePastThresholdM
    }
}

public struct TouchdownEvent: Sendable, Equatable {
    public var time: Double
    public var sinkFPM: Double
    public var offsetM: Double
    public var distancePastThresholdM: Double
}

/// Detects the first contact after an airborne phase. Contact is height at or below `contactHeightM`.
/// The reported sink is the peak descent rate in the last `sinkWindowS` seconds before contact, because a flare
/// reduces sink right at the wheels and the score should reflect the worst part of the approach.
public struct TouchdownDetector: Sendable {
    public static let contactHeightM = 0.5
    public static let sinkWindowS = 1.0
    private var recent: [TouchdownSample] = []
    private var airborne = false
    public private(set) var event: TouchdownEvent?

    public init() {}

    /// Feed samples in time order. Returns the event the first time contact happens, nil otherwise.
    public mutating func feed(_ s: TouchdownSample) -> TouchdownEvent? {
        guard event == nil, s.heightAGLM.isFinite, s.sinkMPS.isFinite, s.time.isFinite else { return nil }
        if s.heightAGLM > Self.contactHeightM {
            airborne = true
            recent.append(s)
            recent.removeAll { s.time - $0.time > Self.sinkWindowS }
            return nil
        }
        guard airborne else { return nil }   // started on the ground: not a landing
        let peakSink = (recent + [s]).map(\.sinkMPS).max() ?? s.sinkMPS
        event = TouchdownEvent(time: s.time, sinkFPM: max(0, peakSink) * 196.850394,
                               offsetM: s.offsetM, distancePastThresholdM: s.distancePastThresholdM)
        return event
    }
}

public extension FlightReport {
    /// Writes a detected touchdown into the report. Crashed flights keep their crash state.
    mutating func applyTouchdown(_ e: TouchdownEvent) {
        landed = true
        touchdownSinkFPM = e.sinkFPM
        touchdownOffsetM = e.offsetM
        touchdownDistancePastThresholdM = e.distancePastThresholdM
    }
}
