// SKYFORGE — Apache-2.0
import Testing
@testable import SFRender

@Suite struct SpatialBinningTests {
    static func grid() -> [SIMD3<Float>] {
        var p: [SIMD3<Float>] = []
        for y in stride(from: Float(-10_000), to: 10_000, by: 400) {
            for x in stride(from: Float(-10_000), to: 10_000, by: 400) {
                p += [SIMD3(x, y, 0), SIMD3(x + 400, y, 10), SIMD3(x, y + 400, 5)]
            }
        }
        return p
    }

    @Test func everyTriangleLandsInExactlyOneCell() {
        let p = Self.grid()
        let (order, cells) = SpatialBinning.bin(positions: p)
        #expect(order.count == p.count / 3)
        #expect(Set(order).count == order.count)
        #expect(cells.reduce(0) { $0 + $1.count } == p.count)
        var next = 0
        for c in cells { #expect(c.start == next); next += c.count }
        #expect(cells.count > 100)
        // Bounds enclose their triangles.
        for c in cells {
            for i in stride(from: c.start / 3, to: (c.start + c.count) / 3, by: 1) {
                let t = order[i]
                for v in 0..<3 { let q = p[3 * t + v]; #expect(all(q .>= c.min) && all(q .<= c.max)) }
            }
        }
    }

    @Test func runsMergeAdjacentVisibleCells() {
        let (_, cells) = SpatialBinning.bin(positions: Self.grid())
        let all = SpatialBinning.runs(cells) { _ in true }
        #expect(all == [0..<cells.last!.start + cells.last!.count])
        let some = SpatialBinning.runs(cells) { $0.min.x < 0 && $0.min.y < 0 }
        #expect(some.count < cells.filter { $0.min.x < 0 && $0.min.y < 0 }.count)
        #expect(SpatialBinning.runs(cells) { _ in false }.isEmpty)
    }
}
