// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
@testable import SFRender

@Suite struct FrameTelemetryTests {
    @Test func startsAtZeroAndKeepsTheLatestSample() {
        let t = FrameTelemetry()
        #expect(t.lastGPUMS == 0)
        t.record(7.5)
        t.record(12.25)
        #expect(t.lastGPUMS == 12.25)
    }

    @Test func recordIsSafeFromConcurrentWriters() async {
        let t = FrameTelemetry()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 { group.addTask { t.record(Double(i)) } }
        }
        #expect((0..<64).map(Double.init).contains(t.lastGPUMS))
    }
}
#endif
