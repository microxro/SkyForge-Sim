// SKYFORGE — Apache-2.0
// CPU reference for OceanShaders: the same Gerstner constants (so tests and physics, e.g. float-plane
// bobbing, agree with what the GPU draws), tier knobs, Fresnel/absorption helpers and the wake-source list.

import Foundation
import simd

public enum OceanTier: String, CaseIterable, Sendable {
    case low, medium, high, ultra
    /// Gerstner octaves the shader evaluates.
    public var octaves: Int { switch self { case .low: 3; case .medium: 5; case .high: 7; case .ultra: 8 } }
    /// Maximum simultaneous wake sources.
    public var maxWakes: Int { switch self { case .low: 1; case .medium: 3; case .high: 6; case .ultra: 8 } }
    /// Whether capillary ripples and fbm foam lace are worth their cost (shader reads `octaves` only; hosts may skip ripples).
    public var ripples: Bool { self != .low }
}

/// Mirrors `OWWake` in the shader (two float4s).
public struct OceanWake: Sendable, Equatable {
    public var position: SIMD2<Float>
    public var heading: Float        // radians, direction of travel
    public var halfWidth: Float      // m
    public var speed: Float          // m/s
    public var length: Float         // m of trail behind
    public var intensity: Float      // 0...1
    public var ageFade: Float        // 0...1
    public init(position: SIMD2<Float>, heading: Float, halfWidth: Float, speed: Float, length: Float, intensity: Float = 1, ageFade: Float = 1) {
        self.position = position; self.heading = heading; self.halfWidth = halfWidth; self.speed = speed
        self.length = length; self.intensity = intensity; self.ageFade = ageFade
    }
    /// Layout matching `OWWake`: posRadius then params.
    public var packed: [Float] { [position.x, position.y, heading, halfWidth, speed, length, intensity, ageFade] }
    /// Wake for a floating aircraft: foam appears once planing speed is reached.
    public static func aircraft(position: SIMD2<Float>, heading: Float, speed: Float, wingspan: Float) -> OceanWake? {
        guard speed > 2 else { return nil }
        let planing = min(1, speed / 25)
        return OceanWake(position: position, heading: heading, halfWidth: max(1, wingspan * 0.08),
                         speed: speed, length: 40 + speed * 4, intensity: 0.3 + 0.7 * planing)
    }
}

/// Mirrors `OWParams` (time, windSpeed, windDir, choppy, octaves, wakeCount, pad×2).
public struct OceanParams: Sendable, Equatable {
    public var time: Float = 0
    public var windSpeed: Float = 8
    public var windDirection: Float = 0
    public var choppy: Float = 0.6
    public var tier: OceanTier = .high
    public init() {}
    public static let byteSize = 32
    public func packed(wakeCount: Int) -> [Float] {
        let oct = Float(bitPattern: UInt32(tier.octaves)), wk = Float(bitPattern: UInt32(min(wakeCount, tier.maxWakes)))
        return [time, windSpeed, windDirection, choppy, oct, wk, 0, 0]
    }
    /// Beaufort-ish sea state 0...1 from the wind.
    public var seaState: Float { min(1, max(0, windSpeed / 20)) }
}

public enum OceanWaves {
    public static let g: Float = 9.81

    public static func dominantWavelength(wind: Float) -> Float { min(220, max(12, 0.14 * 2 * .pi * wind * wind / g)) }
    static func waveAngle(_ i: Int) -> Float {
        let s = sin(Float(i) * 12.9898) * 43758.5453
        return (s - floor(s) - 0.5) * 1.9
    }

    /// Height (m) and slope at `p`, evaluating the same octaves as the shader (`footprint` in m fades short waves).
    public static func sample(at p: SIMD2<Float>, time t: Float, params: OceanParams, footprint: Float = 0)
        -> (height: Float, slope: SIMD2<Float>, crest: Float) {
        let L0 = dominantWavelength(wind: params.windSpeed)
        let amp0 = min(2.2, max(0.05, 0.0036 * params.windSpeed * params.windSpeed / 10))
        var h: Float = 0, slope = SIMD2<Float>(0, 0), pinch: Float = 0
        let n = params.tier.octaves
        for i in 0..<n {
            let L = L0 * pow(0.62, Float(i))
            let fade = max(0, min(1, 1 - footprint * 2.5 / L))
            if fade <= 0 { continue }
            let k = 2 * .pi / L
            let ang = params.windDirection + waveAngle(i) * (0.55 + 0.15 * Float(i))
            let d = SIMD2<Float>(cos(ang), sin(ang))
            let w = (g * k).squareRoot()
            let A = amp0 * pow(L / L0, 1.2) * fade
            let ph = k * simd_dot(d, p) - w * t + Float(i) * 1.7
            h += A * sin(ph)
            slope += d * (A * k * cos(ph))
            let q = min(params.choppy / max(k * A * Float(n), 1e-3), 1)
            pinch += q * k * A * sin(ph)
        }
        return (h, slope, max(0, min(1, pinch * 1.4 + 0.5)))
    }

    /// Schlick Fresnel for water.
    public static func fresnel(cosTheta: Float) -> Float {
        let x = max(0, min(1, 1 - cosTheta)); let x2 = x * x
        return 0.02 + 0.98 * x2 * x2 * x
    }

    /// Beer-Lambert transmittance per channel (matches `owTransmittance`).
    public static func transmittance(depth: Float) -> SIMD3<Float> {
        let sigma = SIMD3<Float>(0.45, 0.075, 0.032)
        let d = max(depth, 0)
        return SIMD3(exp(-sigma.x * d), exp(-sigma.y * d), exp(-sigma.z * d))
    }
}
