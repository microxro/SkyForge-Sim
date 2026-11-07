// SKYFORGE — Apache-2.0
/// Device quality tier used by the quality governor (§11).
public enum DeviceTier: String, Sendable, CaseIterable {
    case low, medium, high, ultra
}

#if canImport(Metal)
import Foundation
import Metal

public enum DeviceTierDetector {
    /// Classifies a GPU by its Apple GPU family and physical memory.
    public static func detect(device: MTLDevice?) -> DeviceTier {
        guard let device else { return .low }
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if device.supportsFamily(.apple9) {
            return memGB >= 32 ? .ultra : .high
        }
        if device.supportsFamily(.apple7) { return .medium }
        return .low
    }
}
#endif
