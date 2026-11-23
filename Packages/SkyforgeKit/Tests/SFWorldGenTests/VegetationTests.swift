import Testing
import SFMath
@testable import SFWorldGen

@Suite struct VegetationTests {
    @Test(arguments: SpeciesKind.allCases)
    func speciesMeshesAreSane(kind: SpeciesKind) {
        for detail in 0...1 {
            let m = VegetationModels.build(kind, detail: detail)
            #expect(m.count > 0 && m.count % 3 == 0)
            #expect(m.count < 24_000)
            let top = m.map { $0.position.z }.max() ?? 0
            #expect(abs(top - 1) < 1e-4)
            for v in m {
                #expect(v.position.x.isFinite && v.position.y.isFinite && v.position.z.isFinite)
                #expect(v.normal.x.isFinite && v.normal.y.isFinite && v.normal.z.isFinite)
                #expect(v.sway >= 0 && v.sway <= 1.001)
                #expect(v.shade >= -1 && v.shade <= 1)
                #expect((v.position.x * v.position.x + v.position.y * v.position.y).squareRoot() < 1.2)
            }
            #expect(m.contains { $0.card > 0.5 })
        }
    }

    @Test func cardLODIsLighter() {
        for k in SpeciesKind.allCases {
            #expect(VegetationModels.build(k, detail: 1).count < VegetationModels.build(k, detail: 0).count)
        }
    }

    @Test func buildDeterministic() {
        #expect(VegetationModels.build(.willow, detail: 0) == VegetationModels.build(.willow, detail: 0))
        #expect(VegetationModels.build(.palm, detail: 1) == VegetationModels.build(.palm, detail: 1))
    }

    @Test func tierBudgetsScale() {
        let lo = VegetationModels.build(.birch, detail: 0, tier: .low).count
        let hi = VegetationModels.build(.birch, detail: 0, tier: .ultra).count
        #expect(lo < hi)
        #expect(VegetationTier.low.grassRadius == 0 && !VegetationTier.low.swayEnabled)
        for t in VegetationTier.allCases.dropLast() {
            let n = VegetationTier(rawValue: t.rawValue + 1)!
            #expect(n.cardStart >= t.cardStart && n.billboardStart >= t.billboardStart && n.farCull >= t.farCull)
        }
    }

    @Test func speciesChoiceDeterministicAndClimateAware() {
        #expect(VegetationModels.species(x: 10, y: 20, climate: 0) == VegetationModels.species(x: 10, y: 20, climate: 0))
        for i in 0..<50 {
            #expect(VegetationModels.species(x: Float(i) * 7, y: Float(i) * 3, climate: 2) != .birch)
            #expect([SpeciesKind.cypress, .acacia].contains(VegetationModels.species(x: Float(i), y: Float(i * 5), climate: 1)))
        }
    }

    @Test(arguments: VegetationTier.allCases)
    func lodWeightsPartitionUnity(tier: VegetationTier) {
        var prevBoard: Float = 0
        for d in stride(from: Float(0), through: tier.farCull, by: 10) {
            let w = VegetationLOD.weights(distance: d, tier: tier)
            #expect(abs(w.full + w.card + w.billboard - 1) < 1e-4)
            #expect(w.full >= 0 && w.card >= -1e-6 && w.billboard >= 0)
            #expect(w.billboard >= prevBoard - 1e-5)      // monotone handover to the billboard
            prevBoard = w.billboard
        }
        #expect(VegetationLOD.weights(distance: 0, tier: tier).full == 1)
        #expect(VegetationLOD.weights(distance: tier.farCull, tier: tier).billboard == 1)
    }

    @Test func ditherExactlyOneRepresentationKeepsEachPixel() {
        let w = VegetationLOD.weights(distance: VegetationTier.high.cardStart, tier: .high)
        for i in 0..<400 {
            let n = VegetationLOD.dither(x: Float(i % 20), y: Float(i / 20))
            #expect(n >= 0 && n < 1)
            let kept = (0...2).filter { VegetationLOD.keeps(weights: w, rep: $0, dither: n) }
            #expect(kept.count == 1)
        }
    }

    @Test func impostorViewsWrapAndBlend() {
        let l = ImpostorLayout(tier: .high)
        let a = l.views(forBearing: 0.0)
        #expect(a.first == 0 && a.second == 1 && abs(a.blend) < 1e-5)
        let step = 2 * Float.pi / Float(l.views)
        let b = l.views(forBearing: -0.25 * step)
        #expect(b.first == l.views - 1 && b.second == 0 && abs(b.blend - 0.75) < 1e-4)
        #expect(l.slice(species: 2, view: -1) == 2 * l.views + l.views - 1)
        let ax = l.bakeAxes(view: 0)
        #expect(abs(ax.forward.x + 1) < 1e-5 && abs(ax.right.y - 1) < 1e-5)
    }

    @Test func swayZeroAtRootAndBoundedAndWindwardDirected() {
        let wind = WindState(direction: SIMD2(1, 0), speed: 12, gustiness: 0.4)
        let root = WindSway.offset(local: SIMD3(0, 0, 0), weight: 0, treeHeight: 10, time: 3, phase: 1, wind: wind, stiffness: 1)
        #expect(abs(root.x) < 1e-6 && abs(root.y) < 1e-6)
        var maxX: Float = 0
        for i in 0..<200 {
            let o = WindSway.offset(local: SIMD3(0, 0, 1), weight: 1, treeHeight: 10, time: Float(i) * 0.1, phase: 0.5, wind: wind, stiffness: 1)
            #expect(o.x.isFinite && abs(o.y) < 1e-6)
            maxX = max(maxX, abs(o.x))
        }
        #expect(maxX > 0.005 && maxX < 0.1)
        let calm = WindSway.offset(local: SIMD3(0, 0, 1), weight: 1, treeHeight: 10, time: 1, phase: 0, wind: WindState(speed: 0), stiffness: 1)
        #expect(calm.x == 0 && calm.y == 0)
        let stiff = WindSway.offset(local: SIMD3(0, 0, 1), weight: 1, treeHeight: 10, time: 1, phase: 0, wind: wind, stiffness: 2.2)
        let soft = WindSway.offset(local: SIMD3(0, 0, 1), weight: 1, treeHeight: 10, time: 1, phase: 0, wind: wind, stiffness: 0.6)
        #expect(abs(stiff.x) < abs(soft.x))
    }

    @Test func seasonsFollowHemispheresAndTropics() {
        let nSummer = VegetationSeason.state(dayOfYear: 200, latitude: 45)
        #expect(nSummer.autumn < 0.01 && nSummer.leafDrop < 0.01)
        let nOct = VegetationSeason.state(dayOfYear: 295, latitude: 45)
        #expect(nOct.autumn > 0.3)
        let nJan = VegetationSeason.state(dayOfYear: 15, latitude: 45)
        #expect(nJan.leafDrop > 0.8)
        let sJan = VegetationSeason.state(dayOfYear: 15, latitude: -45)
        #expect(sJan.leafDrop < 0.05)
        let tropics = VegetationSeason.state(dayOfYear: 15, latitude: 5)
        #expect(tropics.leafDrop == 0 && tropics.autumn == 0)
        #expect(VegetationSeason.leafTint(nOct, treeHash: 0.5, deciduous: false) == SIMD3(1, 1, 1))
        let t = VegetationSeason.leafTint(nOct, treeHash: 0.1, deciduous: true)
        #expect(t.x > t.z)
        #expect(VegetationSeason.cardDropped(nJan, hash: 0.1) && !VegetationSeason.cardDropped(nSummer, hash: 0.1))
    }

    @Test func grassScatterDeterministicInCellAndExcludes() {
        let a = GroundCover.scatter(cellX: 3, cellY: -2, cellSize: 4, density: 20)
        #expect(a == GroundCover.scatter(cellX: 3, cellY: -2, cellSize: 4, density: 20))
        #expect(a.count == 320)
        for b in a { #expect(b.x >= 12 && b.x < 16 && b.y >= -8 && b.y < -4 && b.height > 0.1 && b.height < 0.4) }
        let none = GroundCover.scatter(cellX: 3, cellY: -2, cellSize: 4, density: 20, exclude: { _, _ in true })
        #expect(none.isEmpty)
        #expect(GroundCover.scatter(cellX: 0, cellY: 0, cellSize: 4, density: 0).isEmpty)
    }

    @Test func grassBladeAndKeepFraction() {
        let m = GroundCover.bladeMesh()
        #expect(m.count == 15 && m.count % 3 == 0)
        #expect(m.allSatisfy { $0.position.z >= 0 && $0.position.z <= 1 })
        #expect(GroundCover.keepFraction(distance: 5, tier: .high) == 1)
        #expect(GroundCover.keepFraction(distance: 60, tier: .high) == 0)
        #expect(GroundCover.keepFraction(distance: 1, tier: .low) == 0)
    }

    @Test func gpuPacking() {
        let m = VegetationModels.build(.cypress, detail: 1)
        #expect(VegVertex.gpuBuffer(m).count * 4 == m.count * VegVertex.gpuStride)
    }

    @Test func gpuLayoutMatchesMSL() {
        // MSL VegVertexGPU: packed_float3 + packed_float3 + 3 floats + packed_float2 = 44 bytes, 4-byte aligned.
        #expect(MemoryLayout<VegVertexGPU>.stride == 44 && MemoryLayout<VegVertexGPU>.size == 44)
        #expect(MemoryLayout<VegVertexGPU>.alignment == 4)
        #expect(VegVertex.gpuStride == 44 && VegVertex.gpuFloatCount * 4 == VegVertex.gpuStride)
        // The SIMD3-based CPU vertex is NOT the GPU layout (48 B or more); it must not be uploaded directly.
        #expect(MemoryLayout<VegVertex>.stride != VegVertex.gpuStride)
        let m = VegetationModels.build(.palm, detail: 1)
        let g = VegVertex.gpuVertices(m)
        #expect(g.count == m.count)
        #expect(g[0].px == m[0].position.x && g[0].nz == m[0].normal.z && g[0].v == m[0].uv.y)
        #expect(Array(VegVertex.gpuBuffer(m).prefix(11)) == m[0].gpuFloats)
    }
}
