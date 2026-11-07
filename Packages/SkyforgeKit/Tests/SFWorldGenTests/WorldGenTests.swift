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

@Suite struct AircraftMeshTests {
    @Test func meshIsFiniteAndMatchesDimensions() {
        let spec = AircraftMeshSpec()
        let tris = AircraftMesh.build(spec)
        #expect(tris.count > 500)
        var minY = 0.0, maxY = 0.0, minX = 0.0, maxX = 0.0
        for t in tris {
            for p in [t.a, t.b, t.c] {
                #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite)
                minY = min(minY, p.y); maxY = max(maxY, p.y); minX = min(minX, p.x); maxX = max(maxX, p.x)
            }
        }
        #expect(abs((maxY - minY) - spec.span) < 0.1)                 // wingspan
        #expect(abs((maxX - minX) - (spec.fuselageLength + 0.45)) < 0.6) // length incl. spinner/prop
        // Wheels touch down at z ≈ 1.25 below the CG, matching the flight model's gear contact points.
        let lowest = tris.flatMap { [$0.a.z, $0.b.z, $0.c.z] }.max() ?? 0
        #expect(abs(lowest - 1.25) < 0.05)
    }
}

@Suite struct RunwayGeometryTests {
    @Test func markingsInsideRunwayAndDesignators() {
        let spec = RunwaySpec(threshold: SIMD2(100, 200), heading: 0, length: 1_500, width: 30, lowDesignator: "36", highDesignator: "18")
        let quads = RunwayGeometry.build(spec)
        let whites = quads.filter { $0.paint == .white }
        #expect(whites.count > 40)
        for q in whites {
            for c in q.corners {
                #expect(abs(c.x - 100) <= 15 + 1e-9)            // within the runway width
                #expect(c.y >= 200 - 1e-9 && c.y <= 1_700 + 1e-9) // within the runway length
            }
        }
        #expect(RunwaySpec.designator(headingDegrees: 2) == "36")
        #expect(RunwaySpec.designator(headingDegrees: 118) == "12")
        #expect(RunwaySpec.designator(headingDegrees: 47) == "05")
    }

    @Test func flattenZoneIsLevelAndBlocksSettlement() {
        var r = TerrainRecipe(kind: .suburbanPlain, seed: 1)
        r.flattenZones = [(centre: SIMD2(5_000, 0), halfLength: 800, halfWidth: 80, heading: 0, elevation: 42)]
        #expect(abs(r.height(5_000, 500) - 42) < 1e-9)
        #expect(abs(r.height(5_050, -700) - 42) < 1e-9)
        let g = WorldGenerator(terrain: r)
        #expect(g.settlementDensity(5_000, 0) == 0)
        let chunk = g.generateChunk(cx: 5, cy: 0)
        #expect(chunk.trees.allSatisfy { !r.isAirport($0.position.x, $0.position.y) })
    }
}
