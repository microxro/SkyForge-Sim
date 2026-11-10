// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery

@Suite struct LandCoverTests {
    /// A 4 × 4 grid over ±40 m: the east half is water.
    static let grid = LandCoverGrid(size: 4, halfExtent: 40, classes: [30, 30, 80, 80, 30, 30, 80, 80, 30, 30, 80, 80, 30, 30, 80, 80])

    @Test func waterFractionIsBilinearAcrossTheShore() {
        let g = Self.grid
        #expect(g.water(-30, 0) == 0 && g.water(30, 0) == 1)
        #expect(abs(g.water(0, 0) - 0.5) < 1e-6, "the shore sits on the boundary between cells")
        #expect(g.water(500, 0) == 0, "outside the grid")
        #expect(g.cls(-30, 30) == LandCoverGrid.grass && g.cls(30, -30) == LandCoverGrid.water && g.cls(500, 0) == 0)
    }

    @Test func waterRangeSeparatesOpenWaterShoreAndLand() {
        let g = Self.grid
        #expect(g.waterRange(35, 0) == (1, 1), "open water")
        #expect(g.waterRange(-35, 0) == (0, 0), "land away from water")
        let shore = g.waterRange(5, 0)
        #expect(shore.min == 0 && shore.max == 1)
    }

    @Test func noDataCountsAsOpenOcean() {
        let g = LandCoverGrid(size: 2, halfExtent: 10, classes: [0, 0, 0, 0])
        #expect(g.water(0, 0) == 1)
    }

    /// Every showcase pack carries a grid, and the ones on a coast or a lake have water in it.
    @Test(arguments: ["KMRY", "KBFI", "KASE", "LSZS", "NZQN", "KCOI"])
    func showcasePacksCarryLandCover(ident: String) throws {
        let g = try #require(Showcase.landCover(for: ident))
        #expect(g.size == 4_096 && g.halfExtent == 40_000)
        let wet = g.classes.reduce(0) { $0 + (($1 == LandCoverGrid.water || $1 == 0) ? 1 : 0) }
        let share = Double(wet) / Double(g.classes.count)
        if ["KMRY", "KBFI", "KCOI"].contains(ident) { #expect(share > 0.15, "\(ident) water share \(share)") }
        if ident == "NZQN" { #expect(share > 0.03 && share < 0.15, "Lake Wakatipu: \(share)") }
        // The runway itself is never water.
        #expect(g.water(0, 0) == 0)
    }
}
