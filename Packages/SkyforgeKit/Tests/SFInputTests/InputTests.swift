import Testing
import Foundation
@testable import SFInput

@Suite struct InputTests {
    @Test func deadZonesAndInvert() {
        var s = AxisSettings()
        s.innerDeadZone = 0.1; s.outerDeadZone = 0.1
        #expect(s.process(0.05) == 0)
        #expect(s.process(0.95) == 1)
        #expect(abs(s.process(0.5) - 0.5) < 1e-9)
        s.invert = true
        #expect(abs(s.process(0.5) + 0.5) < 1e-9)
        #expect(s.process(.nan) == 0)
        s.invert = false; s.unipolar = true
        #expect(s.process(-1) == 0 && s.process(1) == 1)
    }

    @Test func curvesAreOddMonotoneAndHitEndpoints() {
        let curves: [ResponseCurve] = [.linear, .exponential(0.7), .spline([0, 0.1, 0.3, 0.6, 1])]
        for c in curves {
            #expect(abs(c.apply(1) - 1) < 1e-9 && abs(c.apply(0)) < 1e-12)
            var prev = -2.0
            for i in 0...100 {
                let x = Double(i) / 100
                let y = c.apply(x)
                #expect(y >= prev - 1e-12)
                #expect(abs(c.apply(-x) + y) < 1e-12)
                prev = y
            }
        }
        #expect(abs(ResponseCurve.spline([0, 0.1, 0.3, 0.6, 1]).apply(0.5) - 0.3) < 1e-12)
        #expect(ResponseCurve.exponential(1).apply(0.5) == 0.125)
    }

    @Test func layerPrecedence() {
        let global = BindingProfile(name: "g", layer: .global, bindings: [
            Binding(device: .keyboard, control: "key.w", target: .axis(.pitch), digitalValue: -0.5)])
        let aircraft = BindingProfile(name: "a", layer: .aircraft, bindings: [
            Binding(device: .keyboard, control: "key.w", aircraftID: "org.skyforge.sf1", target: .axis(.pitch), digitalValue: -1)])
        var m = InputMapper(profiles: [aircraft, global])
        let st = InputMapper.DeviceState(pressed: ["key.w"])
        #expect(m.evaluate(st, aircraftID: "org.skyforge.sf1").axes[.pitch] == -1)
        #expect(m.evaluate(st, aircraftID: "other").axes[.pitch] == -0.5)
    }

    @Test func modifiersDistinguishActions() {
        var m = InputMapper(profiles: [.defaults])
        #expect(m.evaluate(.init(pressed: ["key.f"])).actions == [.flapsDown])
        #expect(m.evaluate(.init(pressed: ["key.f"], modifiers: [.shift])).actions == [.flapsUp])
    }

    @Test func conflictDetection() {
        #expect(InputMapper.conflicts(in: .defaults).isEmpty)
        var p = BindingProfile.defaults
        p.bindings.append(Binding(device: .keyboard, control: "key.w", target: .axis(.roll)))
        #expect(InputMapper.conflicts(in: p).count == 1)
    }

    @Test func gamepadAxesAndSmoothing() {
        var p = BindingProfile.defaults
        p.bindings[10].axis.smoothing = 0.1
        var m = InputMapper(profiles: [p])
        let out = m.evaluate(.init(analog: ["gamepad.leftStick.y": 1, "gamepad.rightTrigger": 1]), dt: 1.0 / 60)
        #expect(out.axes[.pitch] == -1)          // inverted stick, first frame starts at target
        #expect(out.axes[.throttle] == 1)
        let next = m.evaluate(.init(analog: ["gamepad.leftStick.y": 0]), dt: 1.0 / 60)
        #expect((next.axes[.pitch] ?? 0) < 0 && (next.axes[.pitch] ?? 0) > -1)   // smoothing lags
    }

    @Test func jsonRoundTripAndSchemaGuard() throws {
        let data = try BindingProfile.defaults.exportJSON()
        #expect(try BindingProfile.importJSON(data) == .defaults)
        var future = BindingProfile.defaults
        future.schemaVersion = 99
        #expect(throws: BindingProfile.ImportError.unsupportedSchema(99)) { try BindingProfile.importJSON(try future.exportJSON()) }
    }
}
