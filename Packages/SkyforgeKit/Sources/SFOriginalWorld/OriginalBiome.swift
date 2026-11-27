// SKYFORGE — Apache-2.0
// Biome classification for the original world's terrain. Rules are plain and ordered; no randomness here.
import Foundation

public enum OriginalBiome: UInt8, Sendable, CaseIterable {
    case water, beach, wetland, grassland, farmland, forest, shrub, rock, snow
}

public enum OriginalBiomeRules {
    /// Classifies one terrain sample.
    /// - Parameters:
    ///   - height: metres above sea level.
    ///   - slope: rise over run, from central differences.
    ///   - moisture: 0...1, regional wetness plus drainage.
    ///   - temperatureC: sea-level temperature lapsed by height.
    public static func classify(height h: Double, slope: Double, moisture: Double, temperatureC t: Double,
                                water: WaterKind, seaLevel: Double) -> OriginalBiome {
        if water != .none { return .water }
        if h - seaLevel < 3 && slope < 0.12 { return .beach }
        if t < -2 || h > 2_300 { return .snow }
        if slope > 0.85 || (h > 1_500 && slope > 0.45) { return .rock }
        if moisture > 0.72 && slope < 0.06 && h < 400 { return .wetland }
        if h > 900 { return moisture > 0.45 ? .forest : .shrub }
        if moisture > 0.6 { return .forest }
        if moisture < 0.38 { return .shrub }
        return slope < 0.08 ? .farmland : .grassland
    }
}
