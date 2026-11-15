// SKYFORGE — Apache-2.0
import Testing
@testable import SFPreview

@Suite struct ClearingTests {
    /// Clearings cover a few per cent of the forest in compact meadows, with a soft edge, and are deterministic.
    @Test func clearingsCoverAFewPercentWithSoftEdges() {
        var open = 0, edge = 0, total = 0
        for j in 0..<240 {
            for i in 0..<240 {
                let x = Float(i) * 40 - 4_800, y = Float(j) * 40 - 4_800
                let m = FieldPattern.clearing(x, y)
                #expect(m >= 0 && m <= 1)
                if m > 0.5 { open += 1 }
                if m > 0.05 && m < 0.95 { edge += 1 }
                total += 1
            }
        }
        let f = Double(open) / Double(total)
        #expect(f > 0.02 && f < 0.15, "clearing fraction \(f)")
        #expect(edge > 0, "soft edges")
        #expect(FieldPattern.clearing(123.4, -567.8) == FieldPattern.clearing(123.4, -567.8))
    }
}
