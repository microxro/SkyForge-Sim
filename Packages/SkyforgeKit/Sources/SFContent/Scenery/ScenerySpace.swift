// SKYFORGE — Apache-2.0
// Storage rules for whole-Earth scenery (docs/MASTER_PROMPT.md section 9.7): a user quota of 1–500 GB,
// and the device must keep max(5 GB, 10% of capacity) free after the download.
import Foundation

public enum ScenerySpace {
    public static let gigabyte: Int64 = 1_000_000_000
    public static let quotaRange: ClosedRange<Int64> = (1 * gigabyte)...(500 * gigabyte)
    public static let defaultQuota: Int64 = 10 * gigabyte
    public static let minimumReserve: Int64 = 5 * gigabyte

    /// Free space the device must keep after any write: 10% of capacity, at least 5 GB.
    public static func reserve(totalCapacity: Int64) -> Int64 {
        max(minimumReserve, totalCapacity / 10)
    }

    /// Clamps a user-chosen quota into the allowed range.
    public static func clampQuota(_ bytes: Int64) -> Int64 {
        min(max(bytes, quotaRange.lowerBound), quotaRange.upperBound)
    }
}

public enum SceneryStorageAssessment: Equatable, Sendable {
    case ok
    case overQuota(overBy: Int64)
    case insufficientDevice(shortBy: Int64)
}

public struct ScenerySpaceAdvisor: Sendable {
    public var quotaBytes: Int64

    public init(quotaBytes: Int64 = ScenerySpace.defaultQuota) {
        self.quotaBytes = ScenerySpace.clampQuota(quotaBytes)
    }

    /// Checks whether `requiredBytes` more can be written. `installedBytes` counts toward the quota.
    public func assess(requiredBytes: Int64, installedBytes: Int64,
                       availableCapacity: Int64, totalCapacity: Int64) -> SceneryStorageAssessment {
        let afterWrite = installedBytes + requiredBytes
        if afterWrite > quotaBytes { return .overQuota(overBy: afterWrite - quotaBytes) }
        let needed = requiredBytes + ScenerySpace.reserve(totalCapacity: totalCapacity)
        if needed > availableCapacity { return .insufficientDevice(shortBy: needed - availableCapacity) }
        return .ok
    }
}

/// Which catalog segments still need downloading, and how much they weigh.
public enum ScenerySelection {
    public static func missing(in catalog: SceneryCatalog, installed: Set<String>) -> [ScenerySegment] {
        catalog.segments.filter { !installed.contains($0.id) }
    }

    public static func missingBytes(in catalog: SceneryCatalog, installed: Set<String>) -> Int64 {
        missing(in: catalog, installed: installed).reduce(0) { $0 + $1.bytes }
    }
}
