// SKYFORGE — Apache-2.0
// Pure Swift (Linux-testable). Ray tracing quality option: which RT passes may run on this device.
// The Metal probe (`MTLDevice.supportsRaytracing`) lives in the renderer; this file only decides.
import Foundation

/// Which ray traced passes are on. `off` is the default and runs no RT work at all.
public enum RayTracingMode: Int, Sendable, CaseIterable, Codable {
    case off = 0
    /// Ray traced reflections on water, glass and paint.
    case reflections
    /// Ray traced sun shadows and ambient occlusion.
    case shadowsAndAO
    /// Both reflections and shadows/AO.
    case full

    public var reflections: Bool { self == .reflections || self == .full }
    public var shadowsAndAO: Bool { self == .shadowsAndAO || self == .full }
    public var isEnabled: Bool { self != .off }

    /// Lowest adaptive-quality ladder level this mode needs. RT costs GPU time, so the governor
    /// starts no cheaper than this (0 = no floor). See `QualityLadder` in QualityGovernor.swift.
    public var minimumQualityLevel: Int {
        switch self {
        case .off: 0
        case .reflections, .shadowsAndAO: 1
        case .full: 2
        }
    }
}

/// What the device can run. Built from `MTLDevice.supportsRaytracing` by the renderer.
/// Apple GPUs with hardware ray tracing are A17 Pro / M3 and later. Other devices get no RT option.
public struct RayTracingCapability: Sendable, Equatable {
    public var hardwareRT: Bool

    public init(hardwareRT: Bool) { self.hardwareRT = hardwareRT }

    public static let unsupported = RayTracingCapability(hardwareRT: false)
}

/// Full RT setting as the settings menu stores it. Sample counts are clamped to supported ranges
/// on every write and on decode, so a corrupt or hand-edited settings file cannot ask for an unbounded ray count.
public struct RayTracingSettings: Sendable, Equatable, Codable {
    public static let reflectionSampleRange = 1...2
    public static let aoRayRange = 4...16
    public static let shadowSampleRange = 1...2

    public var mode: RayTracingMode
    public var reflectionSamples: Int { didSet { reflectionSamples = Self.clamp(reflectionSamples, Self.reflectionSampleRange) } }
    public var aoRays: Int { didSet { aoRays = Self.clamp(aoRays, Self.aoRayRange) } }
    public var shadowSamples: Int { didSet { shadowSamples = Self.clamp(shadowSamples, Self.shadowSampleRange) } }

    public static let off = RayTracingSettings(mode: .off, reflectionSamples: 1, aoRays: 4, shadowSamples: 1)

    public init(mode: RayTracingMode = .off, reflectionSamples: Int = 1, aoRays: Int = 4, shadowSamples: Int = 1) {
        self.mode = mode
        self.reflectionSamples = Self.clamp(reflectionSamples, Self.reflectionSampleRange)
        self.aoRays = Self.clamp(aoRays, Self.aoRayRange)
        self.shadowSamples = Self.clamp(shadowSamples, Self.shadowSampleRange)
    }

    /// Decodes through the clamping initialiser: synthesized Codable would skip the `didSet` clamps.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try c.decode(RayTracingMode.self, forKey: .mode),
                  reflectionSamples: try c.decode(Int.self, forKey: .reflectionSamples),
                  aoRays: try c.decode(Int.self, forKey: .aoRays),
                  shadowSamples: try c.decode(Int.self, forKey: .shadowSamples))
    }

    /// The settings the renderer may actually run on `cap`. Unsupported hardware always gets `off`,
    /// so the menu can hide the option and nothing RT-related is encoded.
    public func resolved(for cap: RayTracingCapability) -> RayTracingSettings {
        guard cap.hardwareRT else {
            var s = self
            s.mode = .off
            return s
        }
        return self
    }

    /// Whether the settings menu should show the option on this device.
    public static func isOfferable(on cap: RayTracingCapability) -> Bool { cap.hardwareRT }

    private static func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(max(v, r.lowerBound), r.upperBound) }
}
