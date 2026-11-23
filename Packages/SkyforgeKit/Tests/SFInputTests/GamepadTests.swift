import Testing
import Foundation
@testable import SFInput

@Suite struct GamepadTests {
    @Test func defaultGamepadBindingsUseCanonicalNames() {
        let canonical = Set(GamepadControl.allCases.map(\.rawValue))
        for b in BindingProfile.defaults.bindings where b.device == .gamepad {
            #expect(canonical.contains(b.control))
        }
    }

    @Test func canonicalNamesArePrefixedAndUnique() {
        let names = GamepadControl.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        for n in names { #expect(n.hasPrefix("gamepad.")) }
    }

    @Test func triggersRestAtMinusOneAndConvert() {
        #expect(GamepadControl.rightTrigger.restValue == -1)
        #expect(GamepadControl.leftStickX.restValue == 0)
        #expect(GamepadControl.triggerFromUnit(0) == -1)
        #expect(GamepadControl.triggerFromUnit(1) == 1)
        #expect(GamepadControl.triggerFromUnit(0.5) == 0)
        #expect(GamepadControl.triggerFromUnit(.nan) == -1)
    }

    @Test func mergeKeepsDeflectedValuesNotRestingTriggers() {
        var a = InputMapper.DeviceState(analog: ["gamepad.rightTrigger": -1, "gamepad.leftStick.x": 0.2],
                                        pressed: ["gamepad.buttonA"])
        let b = InputMapper.DeviceState(analog: ["gamepad.rightTrigger": 0.6, "gamepad.leftStick.x": -0.9],
                                        pressed: ["gamepad.buttonB"], modifiers: [.shift])
        a.merge(b)
        #expect(a.analog["gamepad.rightTrigger"] == 0.6)
        #expect(a.analog["gamepad.leftStick.x"] == -0.9)
        #expect(a.pressed == ["gamepad.buttonA", "gamepad.buttonB"])
        #expect(a.modifiers == [.shift])
    }

    @Test func mergedSecondPadDrivesFlightAxes() {
        var merged = InputMapper.DeviceState(analog: ["gamepad.leftStick.y": 0])
        merged.merge(InputMapper.DeviceState(analog: ["gamepad.leftStick.y": 1]))
        var mapper = InputMapper(profiles: [.defaults])
        let out = mapper.evaluate(merged)
        #expect(out.axes[.pitch] == -1)   // stick y is inverted in the defaults
    }

    @Test func slotsAssignLowestFreeAndReuse() {
        var s = ControllerSlots<String>()
        #expect(s.connect("a") == 1)
        #expect(s.connect("b") == 2)
        #expect(s.connect("a") == 1)
        #expect(s.disconnect("a") == 1)
        #expect(s.disconnect("a") == nil)
        #expect(s.connect("c") == 1)
        #expect(s.slot(for: "b") == 2)
    }
}
