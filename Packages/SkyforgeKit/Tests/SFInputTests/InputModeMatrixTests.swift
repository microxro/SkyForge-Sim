// SKYFORGE — Apache-2.0
// Input-mode matrix: every device class goes through the same mapper with simulated hardware.
// Covers keyboard, gamepad, touch, tilt, and the pipeline for mouse and joystick (sources land in sibling threads).
// No physical devices are needed. Adapters in SFPlatform are Apple-only, so the frame-level behaviour is tested here.
import Testing
import Foundation
@testable import SFInput

/// Control IDs the app can emit, grouped by device. Sibling threads add their IDs here when they add a source.
/// A binding whose control is not in this list fails the matrix test, so typos do not reach release.
enum InputControlCatalog {
    static let keyLetters = "abcdefghijklmnopqrstuvwxyz".map { "key.\($0)" }
    static let keyDigits = (0...9).map { "key.\($0)" }
    static let keyNamed = ["key.space", "key.escape", "key.return", "key.tab", "key.up", "key.down", "key.left",
                           "key.right", "key.pageUp", "key.pageDown", "key.home", "key.end"]
    static let gamepad = ["gamepad.leftStick.x", "gamepad.leftStick.y", "gamepad.rightStick.x", "gamepad.rightStick.y",
                          "gamepad.leftTrigger", "gamepad.rightTrigger",
                          "gamepad.buttonA", "gamepad.buttonB", "gamepad.buttonX", "gamepad.buttonY",
                          "gamepad.leftShoulder", "gamepad.rightShoulder",
                          "gamepad.dpad.up", "gamepad.dpad.down", "gamepad.dpad.left", "gamepad.dpad.right",
                          "gamepad.leftStickButton", "gamepad.rightStickButton",
                          "gamepad.menu", "gamepad.options", "gamepad.home", "gamepad.share"]
    static let touch = [TouchControls.stickX, TouchControls.stickY, TouchControls.throttle, TouchControls.rudder]
    static let tilt = [TiltMapper.rollControl, TiltMapper.pitchControl]

    static let known: Set<String> = Set(keyLetters + keyDigits + keyNamed + gamepad + touch + tilt)
}

/// A simulated physical device. Its state is merged into one frame, the way the real pollers do.
struct SimulatedDevice: Sendable {
    let id: String
    let device: DeviceClass
    var analog: [String: Double] = [:]
    var pressed: Set<String> = []
    var modifiers: Set<Modifier> = []
}

/// Connected devices by ID. Hot-plug is connect/disconnect; a disconnected device contributes nothing to the frame.
struct SimulatedInputHub: Sendable {
    private(set) var connected: [String: SimulatedDevice] = [:]

    mutating func connect(_ d: SimulatedDevice) { connected[d.id] = d }
    mutating func disconnect(_ id: String) { connected[id] = nil }

    /// Merges every connected device into one frame. IDs are sorted so the result is deterministic.
    func frame() -> InputMapper.DeviceState {
        var s = InputMapper.DeviceState()
        for id in connected.keys.sorted() {
            guard let d = connected[id] else { continue }
            s.analog.merge(d.analog) { _, new in new }
            s.pressed.formUnion(d.pressed)
            s.modifiers.formUnion(d.modifiers)
        }
        return s
    }
}

@Suite struct InputModeMatrixTests {

    // MARK: Catalog

    @Test func everyDefaultControlIsKnownAndOnItsDeviceClass() {
        for profile in [BindingProfile.defaults, BindingProfile.touchDefaults] {
            for b in profile.bindings {
                #expect(InputControlCatalog.known.contains(b.control), "unknown control \(b.control)")
                #expect(BindingCapture.device(for: b.control) == b.device, "\(b.control) is bound as \(b.device)")
            }
        }
    }

    @Test func flightAxesAreReachableFromTheDefaultProfiles() {
        let axes = Set([BindingProfile.defaults, BindingProfile.touchDefaults].flatMap(\.bindings).compactMap { b -> FlightAxis? in
            if case .axis(let a) = b.target { return a }
            return nil
        })
        // Pitch, roll, yaw and throttle are the core four. Everything else is tracked below as a known gap.
        for core in [FlightAxis.pitch, .roll, .yaw, .throttle] {
            #expect(axes.contains(core), "\(core) has no default binding")
        }
        let missing = FlightAxis.allCases.filter { !axes.contains($0) }
        withKnownIssue("Default profiles leave these axes unbound: \(missing.map(\.rawValue).joined(separator: ", "))") {
            #expect(missing.isEmpty)
        }
    }

    @Test func flightActionsHaveDefaultBindings() {
        let bound = Set(BindingProfile.defaults.bindings.compactMap { b -> FlightAction? in
            if case .action(let a) = b.target { return a }
            return nil
        })
        let missing = FlightAction.allCases.filter { !bound.contains($0) }
        // Gear, parking brake, trim and reset have no default key or button yet.
        withKnownIssue("Default profile leaves these actions unbound: \(missing.map(\.rawValue).joined(separator: ", "))") {
            #expect(missing.isEmpty)
        }
    }

    // MARK: Single devices

    @Test func keyboardAloneFliesWithNoController() {
        var m = InputMapper(profiles: [.defaults])
        #expect(m.evaluate(.init(pressed: ["key.w"])).axes[.pitch] == -0.6)
        #expect(m.evaluate(.init(pressed: ["key.s"])).axes[.pitch] == 0.6)
        #expect(m.evaluate(.init(pressed: ["key.a"])).axes[.roll] == -0.6)
        #expect(m.evaluate(.init(pressed: ["key.e"])).axes[.yaw] == 0.6)
        #expect(m.evaluate(.init(pressed: ["key.f"])).actions == [.flapsDown])
        #expect(m.evaluate(.init(pressed: ["key.f"], modifiers: [.shift])).actions == [.flapsUp])
        #expect(m.evaluate(.init(pressed: ["key.space"])).actions == [.pause])
    }

    @Test func gamepadAloneFliesWithNoKeyboard() {
        var m = InputMapper(profiles: [.defaults])
        let out = m.evaluate(.init(analog: ["gamepad.leftStick.y": 1, "gamepad.leftStick.x": -1, "gamepad.rightStick.x": 1]))
        #expect(out.axes[.pitch] == -1)     // inverted stick
        #expect(out.axes[.roll] == -1)
        #expect(out.axes[.yaw] == 1)
        #expect(m.evaluate(.init(pressed: ["gamepad.buttonB"])).actions == [.flapsDown])
        #expect(m.evaluate(.init(pressed: ["gamepad.buttonX"])).actions == [.flapsUp])
    }

    @Test func touchAloneFliesWithNoController() {
        var m = InputMapper(profiles: [.defaults, .touchDefaults])
        var stick = TouchStick(centerX: 0, centerY: 0, radius: 100)
        stick.touch(atX: 100, y: 0)                        // full right roll
        let st = TouchControls.deviceState(stick: stick, throttle: TouchThrottle(minY: 0, maxY: 100, value: 0.4))
        let out = m.evaluate(st)
        #expect((out.axes[.roll] ?? 0) > 0.95)
        #expect(abs((out.axes[.throttle] ?? 0) - 0.4) < 1e-9)
    }

    @Test func touchReleaseCentresTheStick() {
        var m = InputMapper(profiles: [.defaults, .touchDefaults])
        var stick = TouchStick(centerX: 0, centerY: 0, radius: 100)
        stick.touch(atX: 0, y: 100)
        #expect((m.evaluate(TouchControls.deviceState(stick: stick, throttle: TouchThrottle(minY: 0, maxY: 100))).axes[.pitch] ?? 0) > 0.95)
        stick.release()
        #expect(m.evaluate(TouchControls.deviceState(stick: stick, throttle: TouchThrottle(minY: 0, maxY: 100))).axes[.pitch] == 0)
    }

    @Test func everyDeviceClassResolvesThroughTheSameMapper() {
        // Mouse and joystick sources are built in sibling threads. The generic pipeline must already accept them.
        let probes: [(DeviceClass, String, FlightAxis)] = [
            (.keyboard, "key.w", .pitch),
            (.gamepad, "gamepad.rightStick.x", .yaw),
            (.touch, TouchControls.stickX, .roll),
            (.tilt, TiltMapper.pitchControl, .pitch),
            (.mouse, "mouse.x", .roll),
            (.joystick, "joystick.axis.z", .throttle),
        ]
        for (dev, control, axis) in probes {
            let profile = BindingProfile(name: "probe", layer: .device, bindings: [
                Binding(device: dev, control: control, target: .axis(axis), digitalValue: 0.5),
            ])
            var m = InputMapper(profiles: [profile])
            let state = InputMapper.DeviceState(analog: [control: 0.8], pressed: [control])
            #expect(m.evaluate(state).axes[axis] != nil, "\(dev) did not reach \(axis)")
        }
    }

    // MARK: Multiple devices together

    @Test func keyboardAndGamepadCombineOnTheSameAxis() {
        var hub = SimulatedInputHub()
        hub.connect(SimulatedDevice(id: "kb", device: .keyboard, pressed: ["key.w"]))
        hub.connect(SimulatedDevice(id: "pad", device: .gamepad, analog: ["gamepad.leftStick.y": 1]))
        var m = InputMapper(profiles: [.defaults])
        // Analog wins by magnitude (-1); the digital key adds -0.6; the sum clamps to -1.
        #expect(m.evaluate(hub.frame()).axes[.pitch] == -1)
    }

    @Test func touchStickWorksWhileAGamepadIsConnectedButIdle() {
        var hub = SimulatedInputHub()
        var stick = TouchStick(centerX: 0, centerY: 0, radius: 100)
        stick.touch(atX: 0, y: 100)
        hub.connect(SimulatedDevice(id: "touch", device: .touch, analog: [
            TouchControls.stickY: stick.y, TouchControls.stickX: stick.x,
        ]))
        hub.connect(SimulatedDevice(id: "pad", device: .gamepad, analog: [
            "gamepad.leftStick.y": 0, "gamepad.leftStick.x": 0, "gamepad.rightStick.x": 0,
            "gamepad.rightStick.y": 0, "gamepad.leftTrigger": -1, "gamepad.rightTrigger": -1,
        ]))
        var m = InputMapper(profiles: [.defaults, .touchDefaults])
        #expect((m.evaluate(hub.frame()).axes[.pitch] ?? 0) > 0.95)
    }

    @Test func restingGamepadTriggerDoesNotOverrideTouchThrottle() {
        var hub = SimulatedInputHub()
        hub.connect(SimulatedDevice(id: "touch", device: .touch, analog: [TouchControls.throttle: 0.7]))
        hub.connect(SimulatedDevice(id: "pad", device: .gamepad, analog: ["gamepad.rightTrigger": -1]))
        var m = InputMapper(profiles: [.defaults, .touchDefaults])
        let throttle = m.evaluate(hub.frame()).axes[.throttle] ?? 0
        // Known bug: the released trigger reads -1 and, having the larger magnitude, overrides the touch lever.
        // Fix: mark the trigger binding `unipolar` so rest maps to 0. Remove this wrapper when fixed.
        withKnownIssue("Released gamepad trigger (-1) overrides touch throttle (0.7)") {
            #expect(abs(throttle - 0.7) < 1e-9)
        }
    }

    // MARK: Hot-plug

    @Test func unpluggingAGamepadMidHoldStopsItsInput() {
        var hub = SimulatedInputHub()
        var m = InputMapper(profiles: [.defaults])
        #expect(m.evaluate(hub.frame()).axes[.pitch] == nil)              // nothing connected yet

        hub.connect(SimulatedDevice(id: "pad", device: .gamepad, analog: ["gamepad.leftStick.y": 1], pressed: ["gamepad.buttonB"]))
        let held = m.evaluate(hub.frame())
        #expect(held.axes[.pitch] == -1)
        #expect(held.actions == [.flapsDown])

        hub.disconnect("pad")
        let gone = m.evaluate(hub.frame())
        #expect(gone.axes[.pitch] == nil)
        #expect(gone.actions.isEmpty)
    }

    @Test func reconnectingAGamepadResumesWithoutReconfiguring() {
        var hub = SimulatedInputHub()
        var m = InputMapper(profiles: [.defaults])
        let profilesBefore = m.profiles
        hub.connect(SimulatedDevice(id: "pad", device: .gamepad, analog: ["gamepad.rightStick.x": 1]))
        _ = m.evaluate(hub.frame())
        hub.disconnect("pad")
        _ = m.evaluate(hub.frame())
        hub.connect(SimulatedDevice(id: "pad", device: .gamepad, analog: ["gamepad.rightStick.x": 1]))
        #expect(m.evaluate(hub.frame()).axes[.yaw] == 1)
        #expect(m.profiles == profilesBefore)
    }

    // MARK: Rebinding

    @Test func capturedKeyConflictsAreReportedThenResolvedByReplacement() {
        var cap = BindingCapture(target: .action(.gearToggle), existing: BindingProfile.defaults.bindings)
        _ = cap.feed(.init(), dt: 0.016)
        guard case let .captured(b, conflicts) = cap.feed(.init(pressed: ["key.f"]), dt: 0.016) else {
            Issue.record("F was not captured"); return
        }
        #expect(conflicts.count == 1 && conflicts[0].target == .action(.flapsDown))

        // The UI removes the conflicting binding, then adds the new one.
        let kept = BindingProfile.defaults.bindings.filter { !conflicts.contains($0) }
        let player = BindingProfile(name: "Player", layer: .device, bindings: kept + [b])
        var m = InputMapper(profiles: [player])
        let out = m.evaluate(.init(pressed: ["key.f"]))
        #expect(out.actions == [.gearToggle])
        #expect(InputMapper.conflicts(in: player).isEmpty)
    }

    @Test func rebindingSurvivesAJSONRoundTrip() throws {
        var cap = BindingCapture(target: .action(.cameraNext))
        _ = cap.feed(.init(), dt: 0.016)
        guard case let .captured(b, _) = cap.feed(.init(pressed: ["key.v"]), dt: 0.016) else {
            Issue.record("V was not captured"); return
        }
        let profile = BindingProfile(name: "Player", layer: .device, bindings: [b])
        let restored = try BindingProfile.importJSON(try profile.exportJSON())
        #expect(restored == profile)
        var m = InputMapper(profiles: [restored])
        #expect(m.evaluate(.init(pressed: ["key.v"])).actions == [.cameraNext])
    }

    @Test func capturedChordOnlyFiresWithTheSameModifiers() {
        var cap = BindingCapture(target: .action(.cameraNext))
        _ = cap.feed(.init(), dt: 0.016)
        guard case let .captured(b, _) = cap.feed(.init(pressed: ["key.k"], modifiers: [.shift]), dt: 0.016) else {
            Issue.record("Shift+K was not captured"); return
        }
        #expect(b.modifiers == [.shift])
        var m = InputMapper(profiles: [BindingProfile(name: "p", layer: .device, bindings: [b])])
        #expect(m.evaluate(.init(pressed: ["key.k"])).actions.isEmpty)
        #expect(m.evaluate(.init(pressed: ["key.k"], modifiers: [.shift])).actions == [.cameraNext])
    }

    @Test func rebindingATriggerDoesNotCalibrateFromItsRestValue() {
        // Triggers rest at -1 (released). The captured binding must not treat that rest as a centre offset.
        var cap = BindingCapture(target: .axis(.throttle))
        _ = cap.feed(.init(analog: ["gamepad.rightTrigger": -1]), dt: 0.016)
        guard case let .captured(b, _) = cap.feed(.init(analog: ["gamepad.rightTrigger": 1]), dt: 0.016) else {
            Issue.record("trigger was not captured"); return
        }
        #expect(b.control == "gamepad.rightTrigger" && b.target == .axis(.throttle))
        #expect(b.axis.calibrationCentre == 0)
    }
}
