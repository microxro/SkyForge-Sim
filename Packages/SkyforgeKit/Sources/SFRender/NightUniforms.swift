// SKYFORGE — Apache-2.0
// CPU mirror of `NTUniforms` / `NTCone` in NightShaders (16 x float4 / 4 x float4, tightly packed).
import Foundation

public struct NightSkyUniforms: Sendable, Equatable {
    public var camRight = SIMD4<Float>(1, 0, 0, 0)
    public var camUp = SIMD4<Float>(0, 0, 1, 0)
    public var camFwd = SIMD4<Float>(0, 1, 0, 0)
    public var view = SIMD4<Float>(1, 1, 0.001, 0)
    public var moonDir = SIMD4<Float>(0, 1, 0, 0.004_65)
    public var moonParams = SIMD4<Float>(0, 0, 0, 0)
    public var sunDir = SIMD4<Float>(0, 0, -1, 0)
    public var sky = SIMD4<Float>(6.5, 1, 1, 1)
    public var galPole = SIMD4<Float>(0, 0, 1, 0)
    public var galCentre = SIMD4<Float>(1, 0, 0, 0)
    public var eqE = SIMD4<Float>(1, 0, 0, 0)
    public var eqN = SIMD4<Float>(0, 1, 0, 0)
    public var eqU = SIMD4<Float>(0, 0, 1, 0)
    public var twWarm = SIMD4<Float>(0, 0, 0, 1)
    public var twCool = SIMD4<Float>(0, 0, 0, 1)
    public var sprite = SIMD4<Float>(1.6, 40_000, 1000, 0)

    public init() {}

    /// Camera basis in ENU (right, up, forward unit vectors), vertical FOV in radians, viewport in pixels.
    public init(state: NightSkyState, tier: NightTier, right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>,
                verticalFOV: Float, viewport: SIMD2<Float>, time: Float, maxLightDistance: Float = 40_000) {
        let ty = tan(verticalFOV / 2), tx = ty * viewport.x / max(1, viewport.y)
        camRight = SIMD4(right, 0); camUp = SIMD4(up, 0); camFwd = SIMD4(forward, 0)
        view = SIMD4(tx, ty, 2 * ty / max(1, viewport.y), time)
        let m = SIMD3<Float>(Float(state.moonENU.x), Float(state.moonENU.y), Float(state.moonENU.z))
        let phaseBright = Float(pow(max(0.0, state.moonPhase.illuminated), 1.6))
        moonDir = SIMD4(m, 0.004_65)
        moonParams = SIMD4(Float(state.moonPhase.illuminated), phaseBright * Swift.max(state.darkness, 0.2), 0.05 * state.darkness, tier.moonSurfaceDetail ? 1 : 0)
        sunDir = SIMD4(Float(state.sunENU.x), Float(state.sunENU.y), Float(state.sunENU.z), 0)
        let moonWash = 1 - 0.7 * Float(min(1, state.moonlightLux / 0.2))   // bright moon drowns faint stars
        sky = SIMD4(state.limitingMagnitude - 1.5 * (1 - moonWash), state.darkness, 1, tier.milkyWay ? moonWash : 0)
        let g = state.galacticENU()
        galPole = SIMD4(g.pole, 0); galCentre = SIMD4(g.centre, 0)
        (eqE, eqN, eqU) = state.rows
        twWarm = SIMD4(state.twilight.horizonWarm, state.twilight.saturation)
        twCool = SIMD4(state.twilight.antiSolarTint, state.twilight.exposureBoost)
        sprite = SIMD4(tier.minSpritePixels, maxLightDistance, viewport.y / (2 * ty), 0)
    }
}

public struct NightConeUniform: Sendable, Equatable {
    public var posRange: SIMD4<Float>
    public var dirIntensity: SIMD4<Float>
    public var angles: SIMD4<Float>
    public var color: SIMD4<Float>
    public init(_ c: ConeLight) {
        posRange = SIMD4(c.position, c.range)
        dirIntensity = SIMD4(c.direction, c.intensity)
        angles = SIMD4(cos(c.innerHalfAngleDeg * .pi / 180), cos(c.outerHalfAngleDeg * .pi / 180), 0, 0)
        color = SIMD4(c.color, 1)
    }
}
