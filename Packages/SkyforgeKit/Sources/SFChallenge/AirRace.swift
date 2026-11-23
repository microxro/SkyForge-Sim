// SKYFORGE — Apache-2.0
// Air race gates: plane-crossing detection, split times and missed-gate penalties. Pure logic.
import Foundation

/// A gate is a disc in the plane through `center` perpendicular to `normal`.
/// Crossing it counts only when travelling along `normal` and within `radius` of `center`.
public struct RaceGate: Sendable, Equatable {
    public var center: SIMD3<Double>   // NED, m
    public var normal: SIMD3<Double>   // unit vector, direction of travel through the gate
    public var radius: Double          // m

    public init(center: SIMD3<Double>, normal: SIMD3<Double>, radius: Double) {
        self.center = center; self.normal = normal; self.radius = radius
    }
}

public enum GateEvent: Sendable, Equatable {
    case passed(time: Double)
    case missed(time: Double)
}

/// Runs a gated course in order. Gate 0 starts the clock. Crossing the plane outside a gate's
/// radius counts as a miss and moves on to the next gate. Each miss adds `missPenalty` seconds.
public struct AirRace: Sendable {
    public static let missPenalty = 10.0   // s per missed gate

    public let gates: [RaceGate]
    public private(set) var events: [GateEvent] = []
    public private(set) var nextGate = 0
    private var previousPosition: SIMD3<Double>?
    private var previousTime = 0.0

    public init(gates: [RaceGate]) {
        self.gates = gates
    }

    public var isFinished: Bool { !gates.isEmpty && nextGate >= gates.count }
    public var missedCount: Int {
        events.filter { if case .missed = $0 { return true } else { return false } }.count
    }

    /// Time from the first gate to the last, or nil until the race is finished.
    public var totalTime: Double? {
        guard isFinished, let start = startTime, let finish = finishTime else { return nil }
        return finish - start
    }

    /// `totalTime` plus the miss penalties.
    public var penalizedTime: Double? {
        totalTime.map { $0 + Double(missedCount) * Self.missPenalty }
    }

    private var startTime: Double? {
        for e in events { return time(of: e) }
        return nil
    }

    private var finishTime: Double? {
        events.count == gates.count ? events.last.map(time(of:)) : nil
    }

    private func time(of e: GateEvent) -> Double {
        switch e {
        case .passed(let t), .missed(let t): return t
        }
    }

    /// Feeds one position sample. Call at a steady rate; the crossing time is interpolated.
    public mutating func update(position p: SIMD3<Double>, time t: Double) {
        defer { previousPosition = p; previousTime = t }
        guard let prev = previousPosition, nextGate < gates.count else { return }
        let gate = gates[nextGate]
        let d0 = Self.dot(prev - gate.center, gate.normal)
        let d1 = Self.dot(p - gate.center, gate.normal)
        // Only a crossing in the direction of `normal` counts: from behind the plane to in front.
        guard d0 < 0, d1 >= 0 else { return }
        let f = d0 / (d0 - d1)
        let hit = prev + (p - prev) * f
        let offset = hit - gate.center
        let inPlane = offset - gate.normal * Self.dot(offset, gate.normal)
        let crossTime = previousTime + (t - previousTime) * f
        if Self.dot(inPlane, inPlane).squareRoot() <= gate.radius {
            events.append(.passed(time: crossTime))
        } else {
            events.append(.missed(time: crossTime))
        }
        nextGate += 1
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
}
