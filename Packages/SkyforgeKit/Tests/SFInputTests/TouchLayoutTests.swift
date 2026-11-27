import Testing
import Foundation
@testable import SFInput

@Suite struct TouchLayoutTests {
    @Test func defaultsKeepTheStickCurveAndSensitivity() {
        let stick = TouchLayout().profile.bindings.first { $0.control == TouchControls.stickX }
        #expect(stick?.axis.curve == .exponential(0.3))
        #expect(stick?.axis.sensitivity == 1)
    }

    @Test func sensitivityScalesFullDeflection() {
        var layout = TouchLayout()
        layout.stickSensitivity = 0.5
        var mapper = InputMapper(profiles: [.defaults, layout.profile])
        let out = mapper.evaluate(InputMapper.DeviceState(analog: [TouchControls.stickX: 1]))
        #expect(abs((out.axes[.roll] ?? 0) - 0.5) < 1e-9)
    }

    @Test func touchButtonsDriveFlapActions() {
        var mapper = InputMapper(profiles: [.defaults, TouchLayout().profile])
        let out = mapper.evaluate(InputMapper.DeviceState(pressed: [TouchControls.flapsDown]))
        #expect(out.actions.contains(.flapsDown))
        #expect(!out.actions.contains(.flapsUp))
    }

    @Test func layoutValuesAreClampedToTheirRanges() {
        var layout = TouchLayout()
        layout.scale = 10
        layout.opacity = .nan
        layout.stickSensitivity = -3
        layout.stickExpo = 2
        let c = layout.clamped
        #expect(c.scale == 1.4)
        #expect(c.opacity == 0.85)
        #expect(c.stickSensitivity == 0.3)
        #expect(c.stickExpo == 1)
    }

    @Test func layoutRoundTripsAndRefusesNewerSchemas() throws {
        var layout = TouchLayout()
        layout.stickSide = .left
        layout.tiltEnabled = true
        let back = try TouchLayout.decode(try layout.encoded())
        #expect(back == layout)
        var future = layout
        future.schemaVersion = TouchLayout.schemaVersion + 1
        let futureData = try JSONEncoder().encode(future)
        #expect(throws: BindingProfile.ImportError.unsupportedSchema(TouchLayout.schemaVersion + 1)) {
            try TouchLayout.decode(futureData)
        }
    }

    @Test func pinchZoomsWithinLimitsAndDragOrbits() {
        var cam = ChaseCameraControl()
        cam.pinch(scale: 2)
        #expect(cam.distance == 11)
        cam.pinch(scale: 0.01)
        #expect(cam.distance == ChaseCameraControl.maxDistance)
        cam.pinch(scale: .nan)
        #expect(cam.distance == ChaseCameraControl.maxDistance)
        cam.drag(points: 10)
        #expect(abs(cam.orbit - 0.08) < 1e-9)
        cam.drag(points: 2 * Double.pi / 0.008)
        #expect(abs(cam.orbit - 0.08) < 1e-6)
    }
}
