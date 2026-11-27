// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFAudio
import SFFlightModel

@Suite struct EngineProfileTests {
    @Test func firingAndBladeFrequenciesFollowCylinderAndBladeCount() {
        // 2400 rpm = 40 rev/s. Four cylinders fire every second revolution: 80 Hz.
        #expect(abs(EngineProfile.inline4.firingHz(2_400) - 80) < 1e-9)
        // Two blades: 80 Hz blade pass.
        #expect(abs(EngineProfile.inline4.bladePassHz(2_400) - 80) < 1e-9)
        // Nine cylinders: 180 Hz firing. Three blades: 120 Hz.
        #expect(abs(EngineProfile.radial9.firingHz(2_400) - 180) < 1e-9)
        #expect(abs(EngineProfile.radial9.bladePassHz(2_400) - 120) < 1e-9)
    }

    @Test func constructorClampsBadValues() {
        let p = EngineProfile(cylinders: 0, bladeCount: -3, exhaustBrightness: .nan)
        #expect(p.cylinders == 1)
        #expect(p.bladeCount == 1)
        #expect(p.exhaustBrightness == 1)
        #expect(EngineProfile(cylinders: 4, bladeCount: 2, exhaustBrightness: 5).exhaustBrightness == 1)
    }

    @Test func aircraftPowerPicksProfile() {
        var c = AircraftConfig.sf1Trainer
        c.maxPower = 150_000
        #expect(EngineProfile.forAircraft(c) == .inline4)
        c.maxPower = 350_000
        #expect(EngineProfile.forAircraft(c) == .inline6)
        c.maxPower = 700_000
        #expect(EngineProfile.forAircraft(c) == .radial9)
        c.maxPower = .nan
        #expect(EngineProfile.forAircraft(c) == .inline4)
    }

    @Test func audioModelCarriesProfileIntoParameters() {
        var c = AircraftConfig.sf1Trainer
        c.maxPower = 700_000
        var m = AudioModel(config: c)
        _ = m.update(dt: 0.02, time: 0, state: AudioModelTests.state(), outputs: AudioModelTests.outputs(), inputs: ControlInputs(), weather: .clear)
        #expect(m.params.profile == .radial9)
        #expect(m.params.bladePassHz == EngineProfile.radial9.bladePassHz(m.params.engineRPM))
    }

    @Test func radialSynthStaysFiniteAndInRange() {
        var s = ProceduralSynth()
        var p = AudioParameters()
        p.engineRPM = 2_400; p.engineGain = 1; p.engineLoad = 1; p.profile = .radial9
        var out = [Float](repeating: 0, count: 4_800)
        out.withUnsafeMutableBufferPointer { s.render($0.baseAddress!, frames: 4_800, params: p) }
        #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(out.contains { abs($0) > 0.01 })
    }
}
