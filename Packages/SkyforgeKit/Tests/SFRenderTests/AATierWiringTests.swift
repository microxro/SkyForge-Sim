// SKYFORGE — Apache-2.0
import Testing
@testable import SFRender

/// Round 5 wiring: the quality presets must carry an AA tier, or the TAA, SMAA-lite and tier-cascade paths never run.
@Suite struct AATierWiringTests {
    @Test func presetsCarryTheirAATier() {
        #expect(WorldRenderer.Settings.low.aaTier == .low)
        #expect(WorldRenderer.Settings.medium.aaTier == .medium)
        #expect(WorldRenderer.Settings.high.aaTier == .high)
        #expect(WorldRenderer.Settings.ultra.aaTier == .ultra)
    }

    @Test func tierCascadeCountsAreFourOnHighAndUltra() {
        #expect(AAShadowTier.high.cascadeCount == 4)
        #expect(AAShadowTier.ultra.cascadeCount == 4)
        #expect(AAShadowTier.low.cascadeCount < 4)
    }

    @Test func settingsDefaultLeavesTheExistingPath() {
        let s = WorldRenderer.Settings(renderScale: 1, cloudSteps: 40, cloudDownsample: 2, bloomIntensity: 0.04, ssaoStrength: 0.5)
        #expect(s.aaTier == nil)
    }
}
