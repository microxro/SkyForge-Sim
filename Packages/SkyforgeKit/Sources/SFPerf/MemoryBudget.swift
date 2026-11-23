// SKYFORGE — Apache-2.0
// Pure Swift (Linux-testable). Memory ceilings from docs/MASTER_PROMPT.md §11.
import Foundation

public enum DevicePlatform: String, Sendable, CaseIterable {
    case phone, tablet, mac
}

public enum MemoryCategory: String, Sendable, CaseIterable {
    case imagery, terrain, geometry, targets, other
}

public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 0, warning, critical
    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }
    /// Cache budgets halve on a warning and quarter when critical.
    public var cacheScale: Double {
        switch self {
        case .normal: 1
        case .warning: 0.5
        case .critical: 0.25
        }
    }
}

/// Per-device resident-memory budget, split into categories. Streaming caches (imagery, terrain) shrink
/// under pressure; render targets and geometry are fixed because shrinking them mid-flight would pop.
public struct MemoryBudget: Sendable, Equatable {
    public static let mebibyte = 1_048_576
    public let ceiling: Int
    public let headroom: Int
    private let shares: [MemoryCategory: Double]

    public init(ceiling: Int, headroom: Int = 400 * MemoryBudget.mebibyte, shares: [MemoryCategory: Double]? = nil) {
        self.ceiling = max(0, ceiling)
        self.headroom = max(0, headroom)
        let raw = shares ?? [.imagery: 0.35, .terrain: 0.15, .geometry: 0.20, .targets: 0.20, .other: 0.10]
        self.shares = raw.mapValues { $0.isFinite ? min(1, max(0, $0)) : 0 }
    }

    /// iPhone ≤ 1.5 GB (and ≤ 25 % of RAM), iPad ≤ 2.5 GB (≤ 35 %), Mac ≤ 4 GB (≤ 50 %).
    public static func forDevice(_ platform: DevicePlatform, physicalMemory: Int) -> MemoryBudget {
        let gib = 1_073_741_824.0
        let phys = Double(max(0, physicalMemory))
        let bytes: Double
        switch platform {
        case .phone: bytes = min(1.5 * gib, phys * 0.25)
        case .tablet: bytes = min(2.5 * gib, phys * 0.35)
        case .mac: bytes = min(4.0 * gib, phys * 0.5)
        }
        return MemoryBudget(ceiling: Int(bytes))
    }

    public func limit(_ category: MemoryCategory) -> Int {
        Int(Double(ceiling) * (shares[category] ?? 0))
    }

    /// Cap for a streaming cache: its share scaled by pressure, and never more than the OS says is
    /// left once `headroom` is kept free (`osAvailable` is `os_proc_available_memory()` where known).
    public func cacheLimit(_ category: MemoryCategory, pressure: MemoryPressure, currentlyResident: Int, osAvailable: Int?) -> Int {
        let scaled = Int(Double(limit(category)) * pressure.cacheScale)
        guard let osAvailable else { return scaled }
        // Below the headroom the cache must give memory back, not merely stop growing.
        let allowed = max(0, currentlyResident) + (osAvailable - headroom)
        return min(scaled, max(0, allowed))
    }
}

/// Byte accounting per category. Value type: owners keep it behind their own lock or actor.
public struct MemoryLedger: Sendable, Equatable {
    public private(set) var used: [MemoryCategory: Int] = [:]
    public init() {}

    public var total: Int { used.values.reduce(0) { $0.addingReportingOverflow($1).overflow ? Int.max : $0 + $1 } }
    public func bytes(_ c: MemoryCategory) -> Int { used[c] ?? 0 }

    public mutating func add(_ bytes: Int, to c: MemoryCategory) {
        let (sum, overflow) = (used[c] ?? 0).addingReportingOverflow(max(0, bytes))
        used[c] = overflow ? Int.max : sum
    }

    public mutating func remove(_ bytes: Int, from c: MemoryCategory) {
        used[c] = max(0, (used[c] ?? 0) - max(0, bytes))
    }

    public func isOver(_ budget: MemoryBudget, pressure: MemoryPressure = .normal) -> Bool {
        total >= Int.max / 2 || total > budget.ceiling
            || MemoryCategory.allCases.contains { c in
                let cap = (c == .imagery || c == .terrain)
                    ? Int(Double(budget.limit(c)) * pressure.cacheScale) : budget.limit(c)
                return bytes(c) > cap
            }
    }
}
