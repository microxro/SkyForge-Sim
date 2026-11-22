// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFTerrainCore

@Suite struct CDLODLayoutTests {
    @Test func rootIsExactlyTheSquareAndStepsNearTheRequest() throws {
        for (half, step) in [(40_000.0, 16.0), (40_000.0, 8.0), (12_000.0, 12.0)] {
            let l = try #require(CDLODLayout.covering(halfExtent: half, nearStep: step))
            #expect(l.rootSize == 2 * half)
            #expect(abs(l.leafSize * pow(2, Double(l.levels - 1)) - l.rootSize) < 1e-6, "leaves tile the root")
            #expect(l.levels >= 2, "the root is never a leaf")
            #expect(l.finestStep / step > 0.7 && l.finestStep / step < 1.5, "finest step \(l.finestStep) for request \(step)")
        }
    }

    @Test func rejectsNonPositiveInputs() {
        #expect(CDLODLayout.covering(halfExtent: 0, nearStep: 8) == nil)
        #expect(CDLODLayout.covering(halfExtent: 1_000, nearStep: 0) == nil)
        #expect(CDLODLayout.covering(halfExtent: .nan, nearStep: 8) == nil)
        #expect(CDLODLayout.covering(halfExtent: 1_000, nearStep: 8, quads: 3) == nil)
    }
}
