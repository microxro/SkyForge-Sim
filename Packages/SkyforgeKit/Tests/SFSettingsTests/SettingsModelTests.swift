// SKYFORGE — Apache-2.0
import Foundation
import Testing
@testable import SFSettings

@Suite("SkySettings model")
struct SettingsModelTests {
    @Test func defaultsRoundTripThroughCodec() throws {
        let original = SkySettings()
        let data = try SettingsCodec.encode(original)
        #expect(SettingsCodec.decode(data) == original)
    }

    @Test func outOfRangeValuesAreClamped() {
        var s = SkySettings()
        s.graphics.resolutionScale = 3.0
        s.audio.masterVolume = -1
        s.controls.touchSensitivity = 99
        s.accessibility.textScale = .nan
        let c = s.clamped()
        #expect(c.graphics.resolutionScale == 1.0)
        #expect(c.audio.masterVolume == 0)
        #expect(c.controls.touchSensitivity == 3.0)
        #expect(c.accessibility.textScale == 0.75)
    }

    @Test func rayTracingIsOffInEveryPreset() {
        for preset in [GraphicsPreset.low, .medium, .high, .ultra] {
            var s = SkySettings()
            s.applyPreset(preset)
            #expect(s.graphics.rayTracing == .off)
            #expect(s.graphics.preset == preset)
        }
    }

    @Test func customPresetKeepsCurrentValues() {
        var s = SkySettings()
        s.applyPreset(.low)
        let before = s.graphics
        s.applyPreset(.custom)
        #expect(s.graphics.preset == .custom)
        #expect(s.graphics.shadows == before.shadows)
        #expect(s.graphics.resolutionScale == before.resolutionScale)
    }

    @Test func corruptOrNewerDataFallsBackToDefaults() throws {
        #expect(SettingsCodec.decode(nil) == SkySettings())
        #expect(SettingsCodec.decode(Data("not json".utf8)) == SkySettings())

        var future = SkySettings()
        future.schemaVersion = SkySettings.schemaVersion + 1
        let data = try JSONEncoder().encode(future)
        #expect(SettingsCodec.decode(data) == SkySettings())
    }

    @Test func qualityLevelsOrder() {
        #expect(QualityLevel.off < QualityLevel.low)
        #expect(QualityLevel.high < QualityLevel.ultra)
    }
}
