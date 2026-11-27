import Foundation
import Testing
import SFMath
@testable import SFOriginalWorld

@Suite struct OriginalWorldTests {
    static let spec = OriginalWorldSpec(seed: 42, erosionParticles: 4_000)

    @Test func chunkIsDeterministic() {
        let g = OriginalWorldGenerator(spec: Self.spec)
        let a = g.chunk(cx: 3, cy: -2), b = g.chunk(cx: 3, cy: -2)
        #expect(a.contentHash == b.contentHash)
        #expect(a.heights == b.heights)
        #expect(a.biomes == b.biomes)
    }

    @Test func differentSeedsDiffer() {
        let a = OriginalWorldGenerator(spec: Self.spec).chunk(cx: 0, cy: 0)
        let b = OriginalWorldGenerator(spec: OriginalWorldSpec(seed: 43, erosionParticles: 4_000)).chunk(cx: 0, cy: 0)
        #expect(a.contentHash != b.contentHash)
    }

    @Test func outputsAreFiniteAndSized() {
        let c = OriginalWorldGenerator(spec: Self.spec).chunk(cx: -1, cy: 4)
        let n = Self.spec.cellsPerSide
        #expect(c.heights.count == n * n)
        #expect(c.biomes.count == n * n)
        #expect(c.water.count == n * n)
        #expect(c.heights.allSatisfy { $0.isFinite })
    }

    @Test func decimationKeepsCornersAndCount() {
        let c = OriginalWorldGenerator(spec: Self.spec).chunk(cx: 0, cy: 0)
        let lod = c.decimated(step: 4)
        let m = (Self.spec.cellsPerSide - 1) / 4 + 1
        #expect(lod.count == m * m)
        #expect(lod.first == c.height(0, 0))
        #expect(lod.last == c.height(Self.spec.cellsPerSide - 1, Self.spec.cellsPerSide - 1))
    }

    @Test func filledSurfaceNeverBelowRawAndReceiversDescend() {
        let w = 24
        var h = [Double](repeating: 0, count: w * w)
        for j in 0..<w {
            for i in 0..<w {
                // A basin with a noisy rim, so there are real pits to fill.
                let dx = Double(i - 12), dy = Double(j - 12)
                h[j * w + i] = 0.5 * (dx * dx + dy * dy).squareRoot() + Double((i * 7 + j * 13) % 5)
            }
        }
        let r = Hydrology.analyse(h, width: w, seaLevel: -1, riverThreshold: 4)
        for k in 0..<(w * w) {
            #expect(r.filled[k] >= h[k])
            let target = r.receiver[k]
            if target >= 0 {
                #expect(r.filled[target] < r.filled[k])
            }
        }
    }

    @Test func outletsSitOnWindowEdge() {
        let w = 16
        // A plane falling to the west: all water ends at the western edge.
        let h = (0..<(w * w)).map { Double($0 % w) }
        let r = Hydrology.analyse(h, width: w, seaLevel: -100, riverThreshold: 1_000)
        let outlets = (0..<(w * w)).filter { r.receiver[$0] < 0 }
        #expect(!outlets.isEmpty)
        #expect(outlets.allSatisfy { $0 % w == 0 || $0 / w == 0 || $0 / w == w - 1 || $0 % w == w - 1 })
    }

    @Test func erosionIsDeterministic() {
        let w = 40
        let base = (0..<(w * w)).map { k -> Double in
            let x = Double(k % w), y = Double(k / w)
            return 50 + 3 * x + 2 * sin(y / 3)
        }
        var a = base, b = base
        var ra = Xoshiro256(seed: 9), rb = Xoshiro256(seed: 9)
        HydraulicErosion.run(&a, width: w, seaLevel: -1_000, particles: 2_000, rng: &ra)
        HydraulicErosion.run(&b, width: w, seaLevel: -1_000, particles: 2_000, rng: &rb)
        #expect(a == b)
        #expect(a.allSatisfy { $0.isFinite })
    }

    @Test func biomeRulesAreOrdered() {
        #expect(OriginalBiomeRules.classify(height: 0, slope: 0, moisture: 0.5, temperatureC: 14,
                                            water: .sea, seaLevel: 0) == .water)
        #expect(OriginalBiomeRules.classify(height: 1, slope: 0.01, moisture: 0.5, temperatureC: 14,
                                            water: .none, seaLevel: 0) == .beach)
        #expect(OriginalBiomeRules.classify(height: 3_000, slope: 0.1, moisture: 0.5, temperatureC: 1,
                                            water: .none, seaLevel: 0) == .snow)
        #expect(OriginalBiomeRules.classify(height: 1_000, slope: 0.1, moisture: 0.2, temperatureC: 5,
                                            water: .none, seaLevel: 0) == .shrub)
    }
}
