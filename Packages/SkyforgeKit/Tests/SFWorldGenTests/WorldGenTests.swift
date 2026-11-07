import Testing
import SFMath
@testable import SFWorldGen

@Suite struct WorldGenTests {
    @Test func versionPositive() { #expect(SFWorldGenInfo.worldgenVersion >= 1) }

    @Test(arguments: TerrainKind.allCases)
    func terrainFiniteEverywhere(kind: TerrainKind) {
        let r = TerrainRecipe(kind: kind, seed: 5)
        for x in stride(from: -40_000.0, through: 40_000, by: 4_000) {
            for y in stride(from: -40_000.0, through: 40_000, by: 4_000) {
                #expect(r.height(x, y).isFinite)
                _ = r.riverDistance(x, y)   // must not trap far outside the river's extent
            }
        }
    }

    @Test func chunkDeterministic() {
        let g = WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 11))
        let a = g.generateChunk(cx: 0, cy: 0), b = g.generateChunk(cx: 0, cy: 0)
        #expect(a.contentHash == b.contentHash)
        #expect(!a.buildings.isEmpty && !a.roads.isEmpty && !a.trees.isEmpty)
        let other = WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 12)).generateChunk(cx: 0, cy: 0)
        #expect(other.contentHash != a.contentHash)
    }

    @Test func noTreesOnRoadsOrInBuildingsOrWater() {
        let g = WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 11))
        let c = g.generateChunk(cx: 0, cy: 0)
        for t in c.trees {
            #expect(g.roadDistance(t.position.x, t.position.y) >= 7)
            #expect(!WorldGenerator.insideBuilding(SIMD2(t.position.x, t.position.y), c.buildings, margin: 2))
            #expect(!g.terrain.isWater(t.position.x, t.position.y))
            #expect(t.height.isFinite && t.crownRadius > 0)
        }
    }

    @Test func buildingsOffRoadsAndNeighbourColoursDiffer() {
        let g = WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 11))
        let c = g.generateChunk(cx: 0, cy: 0)
        var lastHouse: Building?
        var sameColourRuns = 0
        for b in c.buildings {
            // Footprint centre clear of street centre-lines by at least half a road plus half the building depth.
            #expect(g.streetDistance(b.center.x, b.center.y).distance > 4)
            #expect(b.wallHeight > 2 && b.wallHeight < 40)
            if b.kind == .house, let l = lastHouse, l.kind == .house, l.wallColour == b.wallColour { sameColourRuns += 1 }
            lastHouse = b
        }
        #expect(sameColourRuns == 0)
    }

    @Test func biomesFollowClimate() {
        let lowland = BiomeClassifier.classify(ClimateInputs(latitude: 47, elevation: 100, slope: 0.05, moisture: 0.6, distanceToWater: 1_000))
        #expect(lowland == .temperateForest)
        let alpine = BiomeClassifier.classify(ClimateInputs(latitude: 47, elevation: 3_000, slope: 0.2, moisture: 0.6, distanceToWater: 1_000))
        #expect(alpine == .snow)
        let desert = BiomeClassifier.classify(ClimateInputs(latitude: 22, elevation: 300, slope: 0.05, moisture: 0.1, distanceToWater: 50_000))
        #expect(desert == .desert)
    }
}

@Suite struct RiverTests {
    @Test(arguments: [TerrainKind.forestRiver, .mountainValley])
    func riverSurfaceAboveBed(kind: TerrainKind) {
        let r = TerrainRecipe(kind: kind, seed: 1)
        for p in r.river!.points where abs(p.y) < 6_000 {
            #expect(r.height(p.x, p.y) < r.waterHeight(p.x, p.y), "river bed above water at \(p)")
        }
    }
}
