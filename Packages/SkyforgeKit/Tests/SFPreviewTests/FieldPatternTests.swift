// SKYFORGE — Apache-2.0
import Testing
@testable import SFPreview
import SFWorldGen

@Suite struct FieldPatternTests {
    let pattern = FieldPattern(seed: 0x12_3456, autumn: false)

    @Test func parcelsVaryAndRepeatDeterministically() {
        var crops = Set<Int>()
        for i in 0..<40 {
            for j in 0..<40 {
                let x = Float(i) * 53 - 1_000, y = Float(j) * 61 - 1_200
                let f = pattern.factor(x, y, footprint: 0.5)
                #expect(f == pattern.factor(x, y, footprint: 0.5))
                crops.insert(Int((f.x * 4).rounded()) * 100 + Int((f.y * 4).rounded()))
            }
        }
        #expect(crops.count >= 5, "several distinct crop tones: \(crops.count)")
    }

    @Test func hedgerowsAreThinCrispAndFadeWithFootprint() {
        // Walk across many parcels along u; count samples that are hedge-dark at fine footprint.
        var dark = 0, total = 0, maxDarkFar: Float = 0
        for k in 0..<20_000 {
            let x = Float(k) * 0.25 - 2_500, y = Float(k % 97) * 3
            let near = pattern.factor(x, y, footprint: 0.1)
            if near.x < 0.3 { dark += 1 }
            total += 1
            let far = pattern.factor(x, y, footprint: 40)
            maxDarkFar = max(maxDarkFar, 1 - far.x / max(0.3, pattern.factor(x + 20, y + 20, footprint: 40).x))
        }
        let share = Float(dark) / Float(total)
        // 2.4 m strips on 110–170 m parcels cover a few percent of the ground, never a broad band.
        #expect(share > 0.005 && share < 0.06, "hedge share \(share)")
        #expect(maxDarkFar < 0.9)
    }

    @Test func sceneTerrainCarriesFieldWeights() {
        var b = SceneBuilder(generator: WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 3)), origin: .zero)
        b.addTerrain(centre: SIMD2(2_000, -1_500), halfExtent: 1_500, step: 50)
        #expect(b.soup.fieldPattern != nil)
        #expect(b.soup.vertexField.count == 3 * b.soup.triangleCount)
        #expect(b.soup.vertexField.contains { $0 > 0.5 }, "farmland somewhere in a 3 km tile")
    }
}
