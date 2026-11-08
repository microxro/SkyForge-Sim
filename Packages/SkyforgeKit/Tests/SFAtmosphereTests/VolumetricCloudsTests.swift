// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFAtmosphere

@Suite struct VolumetricCloudsTests {
    let sun = SIMD3<Float>(repeating: 1), sky = SIMD3<Float>(0.2, 0.3, 0.5), ground = SIMD3<Float>(0.05, 0.05, 0.04)
    let toSun = SIMD3<Float>(0.5, 0.2, 0.84)

    func march(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ layer: CloudLayer, maxDist: Float = .infinity) -> CloudSample {
        VolumetricClouds.march(origin: o, dir: d, maxDist: maxDist, layer: layer, toSun: toSun / (toSun * toSun).sum().squareRoot(),
                               sun: sun, skyAmbient: sky, groundAmbient: ground, steps: 64, jitter: 0.5)
    }

    @Test func noiseIsDeterministicAndBounded() {
        var lo: Float = 1, hi: Float = 0
        for i in 0..<5_000 {
            let p = SIMD3<Float>(Float(i) * 0.37 - 900, Float(i % 97) * 1.3, Float(i % 13) * 2.1 - 7)
            let n = VolumetricClouds.noise(p)
            lo = min(lo, n); hi = max(hi, n)
            #expect(n == VolumetricClouds.noise(p))
        }
        #expect(lo >= 0 && hi < 1 && hi - lo > 0.8)
    }

    @Test func densityOnlyInsideTheSlab() {
        let c = CloudLayer(coverage: 1)
        for x in stride(from: Float(-5_000), through: 5_000, by: 250) {
            #expect(VolumetricClouds.density(SIMD3(x, 300, c.base - 1), c) == 0)
            #expect(VolumetricClouds.density(SIMD3(x, 300, c.top + 1), c) == 0)
        }
        var inside = 0
        for x in stride(from: Float(-5_000), through: 5_000, by: 50) where VolumetricClouds.density(SIMD3(x, 300, c.base + 300), c) > 0 { inside += 1 }
        #expect(inside > 100, "overcast layer is mostly filled: \(inside)/201")
    }

    @Test func clearSkyIsTransparentAndOvercastIsOpaque() {
        let up = SIMD3<Float>(0, 0, 1)
        #expect(march(SIMD3(0, 0, 100), up, .clear).transmittance == 1)
        let oc = march(SIMD3(0, 0, 100), up, CloudLayer(coverage: 1, extinction: 0.08))
        #expect(oc.transmittance < 0.05, "overcast zenith T \(oc.transmittance)")
        #expect(oc.depth > 1_300 && oc.depth < 2_700)
        // Scenery in front of the layer hides it.
        #expect(march(SIMD3(0, 0, 100), up, CloudLayer(coverage: 1), maxDist: 500).transmittance == 1)
    }

    @Test func coverageControlsCloudAmount() {
        func cover(_ c: Float) -> Float {
            var sum: Float = 0
            for i in 0..<200 {
                let a = Float(i) * 0.031
                sum += 1 - march(SIMD3(Float(i) * 173, 0, 50), SIMD3(cos(a) * 0.5, sin(a) * 0.5, 0.707), CloudLayer(coverage: c)).transmittance
            }
            return sum / 200
        }
        let a = cover(0.2), b = cover(0.45), c = cover(0.8)
        #expect(a < b && b < c, "cover \(a) \(b) \(c)")
        #expect(a < 0.2 && c > 0.6)
    }

    @Test func phaseIsNormalisedAndForwardPeaked() {
        var integral: Float = 0
        let n = 4_000
        for i in 0..<n {
            let mu = -1 + 2 * (Float(i) + 0.5) / Float(n)
            integral += VolumetricClouds.phase(mu) * 2 * .pi * (2 / Float(n))
        }
        #expect(abs(integral - 1) < 0.01, "phase integral \(integral)")
        #expect(VolumetricClouds.phase(1) > 10 * VolumetricClouds.phase(0))
    }

    @Test func radianceIsFiniteAndBounded() {
        let bound = sun * (VolumetricClouds.phase(1) * 4 * .pi + 0.6) + sky + ground
        for i in 0..<300 {
            let a = Float(i) * 0.7, e = Float(i % 17) / 17 * 1.4 - 0.4
            let d = SIMD3<Float>(cos(a) * cos(e), sin(a) * cos(e), sin(e))
            let s = march(SIMD3(Float(i) * 211, Float(i) * -97, Float(i % 5) * 900 + 100), d, CloudLayer(coverage: 0.6))
            #expect(s.transmittance >= 0 && s.transmittance <= 1)
            #expect(all(s.radiance .>= 0) && all(s.radiance .<= bound), "ray \(i): \(s.radiance)")
        }
    }
}
