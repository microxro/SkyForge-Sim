// SKYFORGE — Apache-2.0
// Time-of-day presets, sky model and per-pixel shading for the CPU preview.
import Foundation
import SFMath

public enum TimePreset: String, Sendable, CaseIterable {
    case sunrise, goldenHour = "golden", midday, overcast, dusk, night, storm
}

public struct LightingSetup: Sendable {
    public var toSun: SIMD3<Float>
    public var sunColour: SIMD3<Float>
    public var skyZenith: SIMD3<Float>
    public var skyHorizon: SIMD3<Float>
    /// Optional mid-sky colour (avoids mauve when blending blue zenith with an orange horizon).
    public var skyMid: SIMD3<Float>? = nil
    public var ambientSky: SIMD3<Float>
    public var ambientGround: SIMD3<Float>
    public var fogDensity: Float          // per metre at sea level
    public var fogColour: SIMD3<Float>
    public var exposure: Float
    public var cloudCover: Float          // 0…1
    public var sunDisc: Bool

    public static func preset(_ p: TimePreset, azimuthDegrees: Double = 250) -> LightingSetup {
        func dir(_ elevationDeg: Double, _ azDeg: Double) -> SIMD3<Float> {
            let e = elevationDeg * .pi / 180, a = azDeg * .pi / 180
            // Azimuth measured clockwise from north; x east, y north.
            return SIMD3(Float(cos(e) * sin(a)), Float(cos(e) * cos(a)), Float(sin(e)))
        }
        switch p {
        case .goldenHour:
            var g = LightingSetup(toSun: dir(8, azimuthDegrees), sunColour: SIMD3(3.6, 2.3, 1.25),
                                 skyZenith: SIMD3(0.09, 0.17, 0.42), skyHorizon: SIMD3(0.86, 0.56, 0.36),
                                 ambientSky: SIMD3(0.26, 0.32, 0.48), ambientGround: SIMD3(0.18, 0.13, 0.09),
                                 fogDensity: 0.000_06, fogColour: SIMD3(0.70, 0.60, 0.52), exposure: 0.82, cloudCover: 0.18, sunDisc: true)
            g.skyMid = SIMD3(0.50, 0.50, 0.50)
            return g
        case .sunrise:
            var s = LightingSetup(toSun: dir(6, azimuthDegrees - 160), sunColour: SIMD3(3.2, 2.1, 1.3),
                                  skyZenith: SIMD3(0.12, 0.22, 0.46), skyHorizon: SIMD3(0.95, 0.70, 0.52),
                                  ambientSky: SIMD3(0.30, 0.35, 0.48), ambientGround: SIMD3(0.18, 0.14, 0.11),
                                  fogDensity: 0.000_08, fogColour: SIMD3(0.80, 0.70, 0.62), exposure: 0.95, cloudCover: 0.2, sunDisc: true)
            s.skyMid = SIMD3(0.52, 0.55, 0.60)
            return s
        case .midday:
            return LightingSetup(toSun: dir(55, azimuthDegrees - 70), sunColour: SIMD3(3.1, 2.95, 2.75),
                                 skyZenith: SIMD3(0.12, 0.26, 0.62), skyHorizon: SIMD3(0.62, 0.74, 0.90),
                                 ambientSky: SIMD3(0.36, 0.44, 0.60), ambientGround: SIMD3(0.20, 0.18, 0.14),
                                 fogDensity: 0.000_06, fogColour: SIMD3(0.66, 0.76, 0.90), exposure: 0.78, cloudCover: 0.3, sunDisc: true)
        case .overcast:
            return LightingSetup(toSun: dir(40, azimuthDegrees - 60), sunColour: SIMD3(0.45, 0.45, 0.47),
                                 skyZenith: SIMD3(0.55, 0.57, 0.60), skyHorizon: SIMD3(0.70, 0.71, 0.72),
                                 ambientSky: SIMD3(0.85, 0.87, 0.90), ambientGround: SIMD3(0.30, 0.29, 0.27),
                                 fogDensity: 0.000_18, fogColour: SIMD3(0.70, 0.71, 0.72), exposure: 1.0, cloudCover: 1.0, sunDisc: false)
        case .dusk:
            return LightingSetup(toSun: dir(-2, azimuthDegrees), sunColour: SIMD3(0.6, 0.30, 0.20),
                                 skyZenith: SIMD3(0.06, 0.08, 0.20), skyHorizon: SIMD3(0.75, 0.38, 0.28),
                                 ambientSky: SIMD3(0.16, 0.16, 0.26), ambientGround: SIMD3(0.06, 0.05, 0.05),
                                 fogDensity: 0.000_10, fogColour: SIMD3(0.45, 0.28, 0.26), exposure: 1.9, cloudCover: 0.2, sunDisc: false)
        case .night:
            return LightingSetup(toSun: dir(35, azimuthDegrees - 120), sunColour: SIMD3(0.05, 0.06, 0.09),
                                 skyZenith: SIMD3(0.005, 0.008, 0.02), skyHorizon: SIMD3(0.04, 0.035, 0.05),
                                 ambientSky: SIMD3(0.025, 0.03, 0.05), ambientGround: SIMD3(0.01, 0.01, 0.012),
                                 fogDensity: 0.000_08, fogColour: SIMD3(0.06, 0.05, 0.06), exposure: 6.0, cloudCover: 0.1, sunDisc: false)
        case .storm:
            return LightingSetup(toSun: dir(30, azimuthDegrees - 40), sunColour: SIMD3(0.25, 0.26, 0.28),
                                 skyZenith: SIMD3(0.22, 0.24, 0.27), skyHorizon: SIMD3(0.36, 0.38, 0.40),
                                 ambientSky: SIMD3(0.42, 0.45, 0.50), ambientGround: SIMD3(0.14, 0.14, 0.14),
                                 fogDensity: 0.000_40, fogColour: SIMD3(0.34, 0.36, 0.39), exposure: 1.5, cloudCover: 1.0, sunDisc: false)
        }
    }

    /// Sky radiance for a view direction (z up).
    public func sky(_ d: SIMD3<Float>, cloudNoise: GradientNoise2D) -> SIMD3<Float> {
        let h = max(0, d.z)
        var c: SIMD3<Float>
        if let mid = skyMid {
            let t = powf(h, 0.5)
            c = t < 0.35 ? skyHorizon + (mid - skyHorizon) * (t / 0.35) : mid + (skyZenith - mid) * ((t - 0.35) / 0.65)
        } else {
            c = skyHorizon + (skyZenith - skyHorizon) * powf(h, 0.42)
        }
        if d.z < 0 { c = skyHorizon * (0.8 + 0.2 * (1 + d.z)) }
        let s = max(0, fdot(d, simd_normalize(toSun)))
        c += sunColour * (0.06 * powf(s, 6) + 0.25 * powf(s, 60))
        if sunDisc && s > 0.99985 { c += sunColour * 18 }
        // Cloud layer: project onto a plane 2.5 km up.
        if d.z > 0.02 && cloudCover > 0 {
            let t = 2_500 / Double(d.z)
            let px = Double(d.x) * t, py = Double(d.y) * t
            let n = cloudNoise.fbm(px / 2_200, py / 2_200, octaves: 5) * 0.5 + 0.5
            let cover = Double(cloudCover)
            // Sparse cumulus at low cover, closing to a deck as cover -> 1.
            let lo = 0.62 - cover * 0.55, hi = lo + 0.12 + cover * 0.1
            let density = Float(smoothstep(lo, hi, n))
            let lit = sunColour * (0.20 + 0.30 * powf(s, 4)) + skyHorizon * 0.35 + ambientSky * 0.25
            let fade = min(1, d.z * 6)
            c = c + (lit - c) * (density * fade * 0.9)
        }
        return c
    }
}

@inline(__always) func aces(_ x: SIMD3<Float>) -> SIMD3<Float> {
    let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
    let r = (x * (a * x + b)) / (x * (c * x + d) + e)
    return SIMD3(min(1, max(0, r.x)), min(1, max(0, r.y)), min(1, max(0, r.z)))
}

@inline(__always) func linearToSRGB(_ v: Float) -> Float {
    v <= 0.003_130_8 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
}
