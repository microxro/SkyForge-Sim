// SKYFORGE — Apache-2.0
// Platform-neutral sky parameters and a CPU port of `sky_fragment`, used as the oracle for the
// offscreen Metal regression test and runnable on Linux (golden image).
import Foundation

public struct SkyParams: Sendable, Equatable {
    public var sunDirection: SIMD3<Float> = SIMD3(0.35, 0.12, -1.0)
    public var zenithColor: SIMD3<Float> = SIMD3(0.16, 0.32, 0.62)
    public var horizonColor: SIMD3<Float> = SIMD3(0.95, 0.70, 0.48)
    public var exposure: Float = 1.1
    public var time: Float = 0
    public init() {}
}

public enum SkyReference {
    static func saturate(_ x: Float) -> Float { min(1, max(0, x)) }
    static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

    static func aces(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
        let n = x * (a * x + SIMD3(repeating: b))
        let m = x * (c * x + SIMD3(repeating: d)) + SIMD3(repeating: e)
        let r = n / m
        return SIMD3(saturate(r.x), saturate(r.y), saturate(r.z))
    }

    /// Display-encoded colour for texture coordinate (u, v) (v down), matching the MSL exactly.
    public static func shade(u: Float, v: Float, aspect: Float, _ p: SkyParams) -> SIMD3<Float> {
        let ndc = SIMD2<Float>(u * 2 - 1, 1 - v * 2)
        var dir = SIMD3<Float>(ndc.x * aspect, ndc.y * 0.75 + 0.15, -1)
        dir /= (dir * dir).sum().squareRoot()
        let h = saturate(dir.y)
        var sky = mix(p.horizonColor, p.zenithColor, pow(h, 0.45))
        let sd = p.sunDirection / (p.sunDirection * p.sunDirection).sum().squareRoot()
        let sunDot = saturate((dir * sd).sum())
        sky += SIMD3<Float>(1, 0.75, 0.45) * (pow(sunDot, 600) * 20 + pow(sunDot, 8) * 0.35)
        if dir.y < 0 {
            sky = mix(p.horizonColor * 0.55, SIMD3(0.18, 0.20, 0.16), saturate(-dir.y * 3))
        }
        let c = aces(sky * p.exposure)
        return SIMD3(pow(c.x, 1 / 2.2), pow(c.y, 1 / 2.2), pow(c.z, 1 / 2.2))
    }

    /// RGB8 image sampled at pixel centres, as the rasterizer interpolates the fullscreen triangle.
    public static func render(width: Int, height: Int, _ p: SkyParams = SkyParams()) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let aspect = Float(width) / Float(height)
        for y in 0..<height {
            for x in 0..<width {
                let c = shade(u: (Float(x) + 0.5) / Float(width), v: (Float(y) + 0.5) / Float(height), aspect: aspect, p)
                let i = 3 * (y * width + x)
                out[i] = UInt8((saturate(c.x) * 255).rounded())
                out[i + 1] = UInt8((saturate(c.y) * 255).rounded())
                out[i + 2] = UInt8((saturate(c.z) * 255).rounded())
            }
        }
        return out
    }
}
