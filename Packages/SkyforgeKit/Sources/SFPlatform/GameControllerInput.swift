// SKYFORGE — Apache-2.0
// Polls GameController gamepads and keyboards into SFInput device state (Apple platforms only).
#if canImport(GameController)
import GameController
import SFInput

public enum GameControllerInput {
    static let keys: [(String, GCKeyCode)] = [
        ("key.a", .keyA), ("key.b", .keyB), ("key.c", .keyC), ("key.d", .keyD), ("key.e", .keyE), ("key.f", .keyF),
        ("key.g", .keyG), ("key.h", .keyH), ("key.i", .keyI), ("key.j", .keyJ), ("key.k", .keyK), ("key.l", .keyL),
        ("key.m", .keyM), ("key.n", .keyN), ("key.o", .keyO), ("key.p", .keyP), ("key.q", .keyQ), ("key.r", .keyR),
        ("key.s", .keyS), ("key.t", .keyT), ("key.u", .keyU), ("key.v", .keyV), ("key.w", .keyW), ("key.x", .keyX),
        ("key.y", .keyY), ("key.z", .keyZ),
        ("key.1", .one), ("key.2", .two), ("key.3", .three), ("key.4", .four), ("key.5", .five),
        ("key.6", .six), ("key.7", .seven), ("key.8", .eight), ("key.9", .nine), ("key.0", .zero),
        ("key.space", .spacebar), ("key.escape", .escape), ("key.return", .returnOrEnter), ("key.tab", .tab),
        ("key.up", .upArrow), ("key.down", .downArrow), ("key.left", .leftArrow), ("key.right", .rightArrow),
        ("key.pageUp", .pageUp), ("key.pageDown", .pageDown), ("key.home", .home), ("key.end", .end),
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
            if pad.leftShoulder.isPressed { state.pressed.insert("gamepad.leftShoulder") }
            if pad.rightShoulder.isPressed { state.pressed.insert("gamepad.rightShoulder") }
            if pad.dpad.up.isPressed { state.pressed.insert("gamepad.dpad.up") }
            if pad.dpad.down.isPressed { state.pressed.insert("gamepad.dpad.down") }
            if pad.dpad.left.isPressed { state.pressed.insert("gamepad.dpad.left") }
            if pad.dpad.right.isPressed { state.pressed.insert("gamepad.dpad.right") }
        }
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            for (name, code) in keys where kb.button(forKeyCode: code)?.isPressed == true { state.pressed.insert(name) }
            if kb.button(forKeyCode: .leftShift)?.isPressed == true || kb.button(forKeyCode: .rightShift)?.isPressed == true {
                state.modifiers.insert(.shift)
            }
            if kb.button(forKeyCode: .leftControl)?.isPressed == true || kb.button(forKeyCode: .rightControl)?.isPressed == true {
                state.modifiers.insert(.control)
            }
            if kb.button(forKeyCode: .leftAlt)?.isPressed == true || kb.button(forKeyCode: .rightAlt)?.isPressed == true {
                state.modifiers.insert(.option)
            }
            if kb.button(forKeyCode: .leftGUI)?.isPressed == true || kb.button(forKeyCode: .rightGUI)?.isPressed == true {
                state.modifiers.insert(.command)
            }
        }
        return state
    }
}
#endif
