// SKYFORGE — Apache-2.0
import Testing
import simd
@testable import SFRender

@Suite struct OceanWaveTests {
    @Test func fresnelSpansF0ToOne() {
        #expect(abs(OceanWaves.fresnel(cosTheta: 1) - 0.02) < 1e-6)
        #expect(abs(OceanWaves.fresnel(cosTheta: 0) - 1) < 1e-6)
        #expect(OceanWaves.fresnel(cosTheta: 0.3) > OceanWaves.fresnel(cosTheta: 0.6))
    }

    @Test func redIsAbsorbedFirst() {
        let t = OceanWaves.transmittance(depth: 10)
        #expect(t.x < t.y && t.y < t.z)
        #expect(OceanWaves.transmittance(depth: 0) == SIMD3<Float>(1, 1, 1))
    }

    @Test func wavesGrowWithWindAndStayBounded() {
        var calm = OceanParams(); calm.windSpeed = 2
        var storm = OceanParams(); storm.windSpeed = 18
        func peak(_ p: OceanParams) -> Float {
            var m: Float = 0
            for i in 0..<400 { m = max(m, abs(OceanWaves.sample(at: SIMD2(Float(i) * 1.7, Float(i) * 0.9), time: 3, params: p).height)) }
            return m
        }
        #expect(peak(storm) > peak(calm) * 2)
        #expect(peak(storm) < 12)
    }

    @Test func distantWaterCalms() {
        let p = OceanParams()
        let near = OceanWaves.sample(at: SIMD2(10, 4), time: 1, params: p, footprint: 0)
        let far = OceanWaves.sample(at: SIMD2(10, 4), time: 1, params: p, footprint: 500)
        #expect(simd_length(far.slope) <= simd_length(near.slope) + 1e-6)
        #expect(abs(far.height) < 1e-4)
    }

    @Test func tiersAreMonotone() {
        let tiers = OceanTier.allCases
        for (a, b) in zip(tiers, tiers.dropFirst()) { #expect(a.octaves <= b.octaves && a.maxWakes <= b.maxWakes) }
        #expect(OceanTier.ultra.octaves <= 8 && OceanTier.ultra.maxWakes <= 8)
    }

    @Test func wakeOnlyWhenMovingAndPacksEightFloats() {
        #expect(OceanWake.aircraft(position: .zero, heading: 0, speed: 1, wingspan: 11) == nil)
        let w = OceanWake.aircraft(position: SIMD2(1, 2), heading: 0.5, speed: 30, wingspan: 11)
        #expect(w?.packed.count == 8 && w?.intensity == 1)
    }

    @Test func paramsPackToThirtyTwoBytes() {
        #expect(OceanParams().packed(wakeCount: 20).count * 4 == OceanParams.byteSize)
    }
}
