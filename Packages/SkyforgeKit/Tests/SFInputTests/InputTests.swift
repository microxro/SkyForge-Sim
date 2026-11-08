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

@Suite struct TouchTiltTests {
    @Test func stickMapsToUnitDiscAndSpringsBack() {
        var s = TouchStick(centerX: 100, centerY: 100, radius: 50)
        s.touch(atX: 125, y: 100)
        #expect(s.x == 0.5 && s.y == 0)
        s.touch(atX: 100, y: 200)              // finger far below: full back stick, clamped
        #expect(s.y == 1 && s.x == 0)
        s.touch(atX: 200, y: 200)
        #expect(abs(s.x * s.x + s.y * s.y - 1) < 1e-12)
        s.release()
        #expect(s.x == 0 && s.y == 0 && !s.active)
    }

    @Test func throttleHoldsAndClamps() {
        var t = TouchThrottle(minY: 100, maxY: 300)
        t.touch(atY: 150)
        #expect(abs(t.value - 0.75) < 1e-12)
        t.touch(atY: 400)
        #expect(t.value == 0)
    }

    @Test func touchDefaultsDriveTheFlightAxes() {
        var mapper = InputMapper(profiles: [.defaults, .touchDefaults])
        var stick = TouchStick(centerX: 0, centerY: 0, radius: 100)
        stick.touch(atX: 0, y: 100)            // pull back
        let out = mapper.evaluate(TouchControls.deviceState(stick: stick, throttle: TouchThrottle(minY: 0, maxY: 100, value: 0.7)))
        #expect((out.axes[.pitch] ?? 0) > 0.95)
        #expect(abs((out.axes[.throttle] ?? 0) - 0.7) < 1e-9)
    }

    @Test func tiltNeutralAndDirections() {
        var m = TiltMapper(orientation: .landscapeLeft)
        func g(rollDeg: Double, backDeg: Double) -> (x: Double, y: Double, z: Double) {
            // Held landscape-left, screen tilted back by backDeg, right side lowered by rollDeg.
            let r = rollDeg * .pi / 180, b = backDeg * .pi / 180
            let screenX = sin(r), screenDown = -cos(r) * cos(b), z = -cos(r) * sin(b)
            return (x: screenDown, y: -screenX, z: z)   // inverse of the landscape-left mapping
        }
        m.calibrate(gravity: g(rollDeg: 0, backDeg: 40))
        let n = m.axes(gravity: g(rollDeg: 0, backDeg: 40))
        #expect(n.roll == 0 && n.pitch == 0)
        let right = m.axes(gravity: g(rollDeg: 20, backDeg: 40))
        #expect(right.roll > 0.4 && right.roll < 0.6 && abs(right.pitch) < 0.05)
        let back = m.axes(gravity: g(rollDeg: 0, backDeg: 60))
        #expect(back.pitch > 0.7 && back.roll == 0)
        #expect(m.axes(gravity: g(rollDeg: 80, backDeg: 40)).roll == 1)
        let small = m.axes(gravity: g(rollDeg: 1, backDeg: 41))   // inside the 2° dead zone
        #expect(small.roll == 0 && small.pitch == 0)
    }

    @Test func captureBindsANewKeyAndReportsConflicts() {
        var cap = BindingCapture(target: .action(.gearToggle), existing: BindingProfile.defaults.bindings)
        #expect(cap.feed(.init(pressed: ["key.f"]), dt: 0.016) == .waiting)          // held at start: ignored
        #expect(cap.feed(.init(pressed: ["key.f"]), dt: 0.016) == .waiting)
        let out = cap.feed(.init(pressed: ["key.f", "key.g"]), dt: 0.016)
        guard case let .captured(b, conflicts) = out else { Issue.record("not captured: \(out)"); return }
        #expect(b.control == "key.g" && b.device == .keyboard && conflicts.isEmpty)

        var cap2 = BindingCapture(target: .action(.gearToggle), existing: BindingProfile.defaults.bindings)
        _ = cap2.feed(.init(), dt: 0.016)
        guard case let .captured(_, c2) = cap2.feed(.init(pressed: ["key.c"]), dt: 0.016) else { Issue.record("no capture"); return }
        #expect(c2.count == 1 && c2[0].target == .action(.cameraNext))
    }

    @Test func captureIgnoresStickDriftAndBindsRealMovement() {
        var cap = BindingCapture(target: .axis(.yaw))
        _ = cap.feed(.init(analog: ["gamepad.rightStick.x": 0.08]), dt: 0.016)
        #expect(cap.feed(.init(analog: ["gamepad.rightStick.x": 0.3]), dt: 0.016) == .waiting)
        #expect(cap.feed(.init(pressed: ["gamepad.buttonA"]), dt: 0.016) == .waiting)    // buttons cannot drive an axis
        guard case let .captured(b, _) = cap.feed(.init(analog: ["gamepad.rightStick.x": -0.9]), dt: 0.016) else {
            Issue.record("no capture"); return
        }
        #expect(b.control == "gamepad.rightStick.x" && b.target == .axis(.yaw))
        #expect(abs(b.axis.calibrationCentre - 0.08) < 1e-12)
    }

    @Test func captureCancelsAndTimesOut() {
        var c = BindingCapture(target: .action(.pause))
        _ = c.feed(.init(), dt: 0)
        #expect(c.feed(.init(pressed: [BindingCapture.cancelControl]), dt: 0.1) == .cancelled)
        var t = BindingCapture(target: .action(.pause), devices: [.gamepad])
        t.timeout = 1
        _ = t.feed(.init(), dt: 0)
        #expect(t.feed(.init(pressed: ["key.p"]), dt: 0.6) == .waiting)   // keyboard filtered out
        #expect(t.feed(.init(), dt: 0.6) == .timedOut)
    }
}
