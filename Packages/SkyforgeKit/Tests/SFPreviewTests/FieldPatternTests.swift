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
            let near = pattern.factor(x, y, footprint: 0.8)
            let dh = near - FieldPattern.hedge
            if (dh * dh).sum() < 0.0004 { dark += 1 }
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

@Suite struct TownImpostorTests {
    let pattern = FieldPattern(seed: 99, autumn: false)
    let lawn = SIMD3<Float>(0.10, 0.12, 0.06)

    @Test func nearDetailHasRoofsStreetsAndLawnAndFarIsTheMean() {
        var roofs = 0, streets = 0, lawns = 0
        var sum = SIMD3<Float>.zero
        let n = 200
        for i in 0..<n {
            for j in 0..<n {
                let c = pattern.town(Float(i) * 1.7, Float(j) * 2.3, footprint: 0.3, lawn: lawn)
                sum += c
                if c == lawn { lawns += 1 } else if c == FieldPattern.street { streets += 1 } else if FieldPattern.roofs.contains(c) { roofs += 1 }
            }
        }
        let total = Float(n * n)
        #expect(Float(roofs) / total > 0.04 && Float(roofs) / total < 0.15, "roof share \(roofs)")
        #expect(Float(streets) / total > 0.08 && Float(streets) / total < 0.22, "street share \(streets)")
        #expect(Float(lawns) / total > 0.5)
        // The far-field colour is close to the area average of the detailed pattern.
        let far = pattern.town(10, 10, footprint: 40, lawn: lawn), avg = sum / total
        #expect(abs(far.x - avg.x) < 0.012 && abs(far.y - avg.y) < 0.012 && abs(far.z - avg.z) < 0.012, "far \(far) avg \(avg)")
    }

    @Test func impostorOnlyBeyondTheBuildingRadius() {
        var b = SceneBuilder(generator: WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 1)), origin: .zero)
        b.townImpostor = (SIMD2(0, 0), 1_000)
        b.addTerrain(centre: SIMD2(0, 0), halfExtent: 3_000, step: 60, far: true)
        var inside = 0, outside = 0
        for t in 0..<b.soup.triangleCount {
            let p = b.soup.positions[3 * t]
            let d = (p.x * p.x + p.y * p.y).squareRoot()
            if b.soup.field(t, 0) < -0.5 { if d < 850 { inside += 1 } else { outside += 1 } }
        }
        #expect(inside == 0)
        #expect(outside > 0, "suburb impostor beyond 1 km")
    }
}

@Suite struct ParcelGridTests {
    @Test func farmedParcelsAreWholeAndClipStillCuts() {
        var b = SceneBuilder(generator: WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 3)), origin: .zero)
        b.addTerrain(centre: SIMD2(2_000, -1_500), halfExtent: 1_500, step: 50)
        let p = try! #require(b.soup.fieldPattern)
        let grid = try! #require(p.parcels)
        #expect(grid.on.contains(255) && grid.on.contains(0), "some parcels farmed, some not")
        // Inside a farmed parcel with full clip, coverage is 1 everywhere; in an unfarmed one it is 0.
        var checked = 0
        for iv in 0..<grid.height {
            for iu in 0..<grid.width where checked < 40 {
                let idx = SIMD2(grid.iu0 + Int32(iu), grid.iv0 + Int32(iv))
                let c = p.parcelCentre(idx)
                guard p.parcelIndex(c.x, c.y) == idx else { continue }       // warp moved the centre out
                let cov = p.coverage(c.x, c.y, weight: 1)
                #expect(cov == (grid.isOn(idx) ? 1 : 0))
                #expect(p.coverage(c.x, c.y, weight: 0) == 0, "a full clip removes the field")
                checked += 1
            }
        }
        #expect(checked > 10)
    }
}
