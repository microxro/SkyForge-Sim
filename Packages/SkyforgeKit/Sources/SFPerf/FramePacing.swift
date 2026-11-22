// SKYFORGE — Apache-2.0
// Pure Swift (Linux-testable). Frame statistics and refresh-rate policy (§11).
import Foundation

public enum ThermalLevel: Int, Sendable, Comparable, CaseIterable {
    case nominal = 0, fair, serious, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    public init(_ s: ProcessInfo.ThermalState) {
        switch s {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

/// Picks the frame-rate cap. `maxFPS` is what the display offers (120 on ProMotion and iPad Pro, else 60).
public enum RefreshPolicy {
    public static func targetFPS(maxFPS: Int, platform: DevicePlatform, thermal: ThermalLevel, lowPowerMode: Bool) -> Int {
        var cap = max(30, maxFPS)
        // Phones default to 60 even on ProMotion; tablets and Macs may use the full rate.
        if platform == .phone { cap = min(cap, 60) }
        if thermal >= .fair { cap = min(cap, 60) }
        if thermal >= .serious || lowPowerMode { cap = min(cap, 30) }
        return cap
    }

    /// Frame-time budget in milliseconds.
    public static func budgetMS(fps: Int) -> Double { 1_000.0 / Double(max(1, fps)) }
}

/// Fixed-size ring of frame times with the percentile and hitch figures from §11.
public struct FrameStats: Sendable {
    public let capacity: Int
    private var ring: [Double] = []
    private var next = 0
    public private(set) var totalFrames = 0
    public private(set) var hitches = 0
    public private(set) var elapsedMS = 0.0

    public init(capacity: Int = 240) {
        self.capacity = max(2, capacity)
        ring.reserveCapacity(self.capacity)
    }

    public var count: Int { ring.count }

    /// Records one frame. A hitch is a frame longer than 2 × the target budget.
    public mutating func record(frameMS: Double, targetMS: Double) {
        let ms = max(0, frameMS)
        if ring.count < capacity { ring.append(ms) } else { ring[next] = ms }
        next = (next + 1) % capacity
        totalFrames += 1
        elapsedMS += ms
        if ms > 2 * targetMS { hitches += 1 }
    }

    /// Nearest-rank percentile over the window (0 when empty).
    public func percentile(_ p: Double) -> Double {
        guard !ring.isEmpty else { return 0 }
        let s = ring.sorted()
        let rank = Int((min(1, max(0, p)) * Double(s.count)).rounded(.up))
        return s[min(s.count - 1, max(0, rank - 1))]
    }

    public var p50: Double { percentile(0.5) }
    public var p99: Double { percentile(0.99) }

    public var hitchesPerMinute: Double {
        elapsedMS > 0 ? Double(hitches) / (elapsedMS / 60_000) : 0
    }

    /// §11: p99 ≤ 1.25 × target and ≤ 1 hitch per minute.
    public func meetsPacingTarget(targetMS: Double) -> Bool {
        count > 0 && p99 <= 1.25 * targetMS && hitchesPerMinute <= 1
    }
}
