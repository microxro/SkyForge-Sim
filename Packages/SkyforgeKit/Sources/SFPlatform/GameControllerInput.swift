// SKYFORGE — Apache-2.0
// Polls GameController gamepads and keyboards into SFInput device state (Apple platforms only).
#if canImport(GameController)
import GameController
import SFInput

public enum GameControllerInput {
    static let keys: [(String, GCKeyCode)] = [
        ("key.w", .keyW), ("key.s", .keyS), ("key.a", .keyA), ("key.d", .keyD),
        ("key.q", .keyQ), ("key.e", .keyE), ("key.f", .keyF), ("key.c", .keyC), ("key.space", .spacebar),
    ]

    /// Reads the current state of the first extended gamepad and the system keyboard.
    @MainActor
    public static func poll() -> InputMapper.DeviceState {
        var state = InputMapper.DeviceState()
        if let pad = GCController.controllers().first?.extendedGamepad {
            state.analog["gamepad.leftStick.x"] = Double(pad.leftThumbstick.xAxis.value)
            state.analog["gamepad.leftStick.y"] = Double(pad.leftThumbstick.yAxis.value)
            state.analog["gamepad.rightStick.x"] = Double(pad.rightThumbstick.xAxis.value)
            state.analog["gamepad.rightStick.y"] = Double(pad.rightThumbstick.yAxis.value)
            state.analog["gamepad.rightTrigger"] = Double(pad.rightTrigger.value) * 2 - 1
            state.analog["gamepad.leftTrigger"] = Double(pad.leftTrigger.value) * 2 - 1
            if pad.buttonA.isPressed { state.pressed.insert("gamepad.buttonA") }
            if pad.buttonB.isPressed { state.pressed.insert("gamepad.buttonB") }
            if pad.buttonX.isPressed { state.pressed.insert("gamepad.buttonX") }
            if pad.buttonY.isPressed { state.pressed.insert("gamepad.buttonY") }
        }
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            for (name, code) in keys where kb.button(forKeyCode: code)?.isPressed == true { state.pressed.insert(name) }
            if kb.button(forKeyCode: .leftShift)?.isPressed == true || kb.button(forKeyCode: .rightShift)?.isPressed == true {
                state.modifiers.insert(.shift)
            }
        }
        return state
    }
}
#endif
