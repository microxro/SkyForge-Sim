// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFPerf

@Suite struct RayTracingPlanTests {
    @Test func defaultIsOffAndRunsNothing() {
        let s = RayTracingSettings.off
        #expect(s.mode == .off)
        #expect(!s.mode.isEnabled && !s.mode.reflections && !s.mode.shadowsAndAO)
        #expect(s.mode.minimumQualityLevel == 0)
    }

    @Test func modesSelectPasses() {
        #expect(RayTracingMode.reflections.reflections && !RayTracingMode.reflections.shadowsAndAO)
        #expect(!RayTracingMode.shadowsAndAO.reflections && RayTracingMode.shadowsAndAO.shadowsAndAO)
        #expect(RayTracingMode.full.reflections && RayTracingMode.full.shadowsAndAO)
    }

    @Test func governorFloorRisesWithCost() {
        #expect(RayTracingMode.reflections.minimumQualityLevel == 1)
        #expect(RayTracingMode.shadowsAndAO.minimumQualityLevel == 1)
        #expect(RayTracingMode.full.minimumQualityLevel == 2)
        #expect(RayTracingMode.full.minimumQualityLevel <= QualityLadder.maxLevel)
    }

    @Test func unsupportedHardwareResolvesToOffAndIsHidden() {
        let wanted = RayTracingSettings(mode: .full, reflectionSamples: 2, aoRays: 16, shadowSamples: 2)
        let resolved = wanted.resolved(for: .unsupported)
        #expect(resolved.mode == .off)
        #expect(resolved.reflectionSamples == 2)   // sample counts are kept, only the mode is forced off
        #expect(!RayTracingSettings.isOfferable(on: .unsupported))
    }

    @Test func supportedHardwareKeepsRequestedMode() {
        let cap = RayTracingCapability(hardwareRT: true)
        let wanted = RayTracingSettings(mode: .reflections)
        #expect(wanted.resolved(for: cap) == wanted)
        #expect(RayTracingSettings.isOfferable(on: cap))
    }

    @Test func sampleCountsClampOnWriteAndInit() {
        var s = RayTracingSettings(mode: .full, reflectionSamples: 99, aoRays: -3, shadowSamples: 0)
        #expect(s.reflectionSamples == 2 && s.aoRays == 4 && s.shadowSamples == 1)
        s.aoRays = 1_000_000
        s.reflectionSamples = 0
        #expect(s.aoRays == 16 && s.reflectionSamples == 1)
    }

    @Test func decodedSettingsAreClamped() throws {
        let json = #"{"mode":3,"reflectionSamples":50,"aoRays":2,"shadowSamples":-1}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RayTracingSettings.self, from: json)
        #expect(s.mode == .full)
        #expect(s.reflectionSamples == 2 && s.aoRays == 4 && s.shadowSamples == 1)
    }
}
