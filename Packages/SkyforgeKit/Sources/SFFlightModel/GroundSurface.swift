// SKYFORGE — Apache-2.0
// Ground surface types for soft-field and bush-strip operations. Values are engineering-estimate
// figures in the spirit of public-domain textbook tables (rolling resistance and braking traction for
// unpaved surfaces), not measurements of any real airstrip.
import Foundation

public enum GroundSurface: String, Sendable, Codable, CaseIterable, Equatable {
    case paved, grass, gravel, softField, mud

    /// Extra rolling-resistance coefficient added to every wheel on the ground (paved = 0).
    public var rollingCoefficient: Double {
        switch self {
        case .paved: return 0
        case .grass: return 0.04
        case .gravel: return 0.03
        case .softField: return 0.10
        case .mud: return 0.18
        }
    }

    /// Multiplier on the tyre-to-ground friction limit: loose surfaces give less braking grip.
    public var tractionScale: Double {
        switch self {
        case .paved: return 1
        case .grass: return 0.9
        case .gravel: return 0.85
        case .softField: return 0.65
        case .mud: return 0.45
        }
    }
}
