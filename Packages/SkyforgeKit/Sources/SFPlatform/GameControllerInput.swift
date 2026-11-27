// SKYFORGE — Apache-2.0
// Reads every connected GameController pad (Xbox, DualSense/DualShock, 8BitDo, MFi, micro gamepads)
// and the system keyboard into SFInput device state, and reports connect/disconnect (Apple platforms only).
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

    /// Combined state of every connected controller plus the keyboard, for one frame.
    @MainActor
    public static func poll() -> InputMapper.DeviceState {
        var state = InputMapper.DeviceState()
        for pad in GCController.controllers() {
            state.merge(padState(pad))
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

    /// State of one controller. Full gamepads use the extended profile; micro gamepads (A, X, menu,
    /// d-pad) feed the left stick from the d-pad so they can still fly.
    @MainActor
    public static func padState(_ pad: GCController) -> InputMapper.DeviceState {
        var s = InputMapper.DeviceState()
        func axis(_ v: Float, _ c: GamepadControl) { s.analog[c.rawValue] = Double(v) }
        func press(_ b: GCControllerButtonInput?, _ c: GamepadControl) {
            if b?.isPressed == true { s.pressed.insert(c.rawValue) }
        }
        if let g = pad.extendedGamepad {
            axis(g.leftThumbstick.xAxis.value, .leftStickX)
            axis(g.leftThumbstick.yAxis.value, .leftStickY)
            axis(g.rightThumbstick.xAxis.value, .rightStickX)
            axis(g.rightThumbstick.yAxis.value, .rightStickY)
            s.analog[GamepadControl.leftTrigger.rawValue] = GamepadControl.triggerFromUnit(Double(g.leftTrigger.value))
            s.analog[GamepadControl.rightTrigger.rawValue] = GamepadControl.triggerFromUnit(Double(g.rightTrigger.value))
            press(g.buttonA, .buttonA)
            press(g.buttonB, .buttonB)
            press(g.buttonX, .buttonX)
            press(g.buttonY, .buttonY)
            press(g.leftShoulder, .leftShoulder)
            press(g.rightShoulder, .rightShoulder)
            press(g.leftThumbstickButton, .leftStickButton)
            press(g.rightThumbstickButton, .rightStickButton)
            press(g.dpad.up, .dpadUp)
            press(g.dpad.down, .dpadDown)
            press(g.dpad.left, .dpadLeft)
            press(g.dpad.right, .dpadRight)
            press(g.buttonMenu, .menu)
            press(g.buttonOptions, .options)
            press(g.buttonHome, .home)
        } else if let m = pad.microGamepad {
            axis(m.dpad.xAxis.value, .leftStickX)
            axis(m.dpad.yAxis.value, .leftStickY)
            press(m.buttonA, .buttonA)
            press(m.buttonX, .buttonX)
            press(m.buttonMenu, .menu)
            press(m.dpad.up, .dpadUp)
            press(m.dpad.down, .dpadDown)
            press(m.dpad.left, .dpadLeft)
            press(m.dpad.right, .dpadRight)
        }
        return s
    }

    /// Calls `onChange` on the main actor whenever a controller connects or disconnects.
    /// Keep the returned tokens alive for as long as you want the callbacks.
    @MainActor
    public static func observeConnections(_ onChange: @escaping @Sendable @MainActor () -> Void) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let names: [NSNotification.Name] = [.GCControllerDidConnect, .GCControllerDidDisconnect]
        return names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in onChange() }
            }
        }
    }
}
#endif
