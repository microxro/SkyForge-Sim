import Testing
import Foundation
@testable import SFInput

@Suite struct HIDJoystickTests {
    static func stick(instance: Int = 0) -> HIDJoystickLayout {
        HIDJoystickLayout(
            id: HIDDeviceID(vendorID: 0x044F, productID: 0xB10A, instance: instance),
            name: "Test stick",
            axes: [
                HIDAxisDescriptor(index: 0, calibration: HIDAxisCalibration(logicalMin: 0, logicalMax: 255)),
                HIDAxisDescriptor(index: 1, calibration: HIDAxisCalibration(logicalMin: 0, logicalMax: 255)),
                HIDAxisDescriptor(index: 2, calibration: HIDAxisCalibration(logicalMin: 0, logicalMax: 1023), fullRange: true),
            ],
            buttonCount: 12,
            hatCount: 1
        )
    }

    @Test func centredAxisMapsRestToZeroAndEndsToUnit() {
        let c = HIDAxisCalibration(logicalMin: 0, logicalMax: 255)
        #expect(abs(c.centred(127.5)) < 1e-9)
        #expect(abs(c.centred(0) + 1) < 1e-9)
        #expect(abs(c.centred(255) - 1) < 1e-9)
        #expect(c.centred(.nan) == 0)
    }

    @Test func offCentreRestPositionIsCalibrated() {
        let c = HIDAxisCalibration(logicalMin: 0, logicalMax: 255, centre: 100)
        #expect(c.centred(100) == 0)
        #expect(abs(c.centred(50) + 0.5) < 1e-9)
        #expect(abs(c.centred(255) - 1) < 1e-9)
    }

    @Test func fullRangeAxisRunsMinToMax() {
        let c = HIDAxisCalibration(logicalMin: 0, logicalMax: 1023)
        #expect(c.full(0) == -1)
        #expect(c.full(1023) == 1)
        #expect(abs(c.full(511.5)) < 1e-9)
        #expect(c.full(.infinity) == -1)
    }

    @Test func hatDecodesEightWaysAndNeutral() {
        #expect(HIDHat.directions(0) == [.up])
        #expect(HIDHat.directions(2) == [.right])
        #expect(HIDHat.directions(7) == [.up, .left])
        #expect(HIDHat.directions(8).isEmpty)
        #expect(HIDHat.directions(-1).isEmpty)
        #expect(HIDHat.directions(1, logicalMin: 1) == [.up])
    }

    @Test func controlNamesAreStableAndReportsDecode() {
        let layout = HIDJoystickTests.stick()
        #expect(layout.id.controlPrefix == "joystick.044f.b10a.0")
        let out = layout.controls(for: HIDReport(axes: [0: 255, 2: 1023], buttons: [1, 12, 13, 0], hats: [0: 2]))
        #expect(out.analog["joystick.044f.b10a.0.axis.0"] == 1)
        #expect(out.analog["joystick.044f.b10a.0.axis.2"] == 1)
        #expect(out.analog["joystick.044f.b10a.0.axis.1"] == nil)
        #expect(out.pressed == ["joystick.044f.b10a.0.button.1", "joystick.044f.b10a.0.button.12", "joystick.044f.b10a.0.hat.0.right"])
    }

    @Test func hubAssignsAndReusesInstances() {
        var hub = HIDJoystickHub()
        let first = hub.connect(HIDJoystickTests.stick())
        let second = hub.connect(HIDJoystickTests.stick())
        #expect(first.instance == 0 && second.instance == 1)
        #expect(hub.layouts.count == 2)
        hub.disconnect(first)
        #expect(hub.connect(HIDJoystickTests.stick()).instance == 0)
    }

    @Test func twoIdenticalSticksDoNotCollide() {
        var hub = HIDJoystickHub()
        let a = hub.connect(HIDJoystickTests.stick())
        let b = hub.connect(HIDJoystickTests.stick())
        let state = hub.deviceState(reports: [
            a: HIDReport(axes: [0: 255]),
            b: HIDReport(axes: [0: 0], buttons: [3]),
        ])
        #expect(state.analog["joystick.044f.b10a.0.axis.0"] == 1)
        #expect(state.analog["joystick.044f.b10a.1.axis.0"] == -1)
        #expect(state.pressed == ["joystick.044f.b10a.1.button.3"])
    }

    @Test func unknownDeviceReportsAreIgnored() {
        let hub = HIDJoystickHub()
        let state = hub.deviceState(reports: [HIDDeviceID(vendorID: 1, productID: 2): HIDReport(buttons: [1])])
        #expect(state.analog.isEmpty && state.pressed.isEmpty)
    }

    @Test func bindingsReadJoystickControlsThroughInputMapper() {
        var hub = HIDJoystickHub()
        let id = hub.connect(HIDJoystickTests.stick())
        var throttle = Binding(device: .joystick, control: "joystick.044f.b10a.0.axis.2", target: .axis(FlightAxis.throttle))
        throttle.axis.unipolar = true
        var roll = Binding(device: .joystick, control: "joystick.044f.b10a.0.axis.0", target: .axis(FlightAxis.roll))
        roll.axis.innerDeadZone = 0
        let flaps = Binding(device: .joystick, control: "joystick.044f.b10a.0.button.1", target: .action(FlightAction.flapsDown))
        let profile = BindingProfile(name: "stick", layer: .device, bindings: [roll, flaps, throttle])
        var mapper = InputMapper(profiles: [profile])
        let state = hub.deviceState(reports: [id: HIDReport(axes: [0: 255, 2: 1023], buttons: [1])])
        let out: InputMapper.Output = mapper.evaluate(state)
        #expect(out.axes[FlightAxis.roll] == 1)
        #expect(out.axes[FlightAxis.throttle] == 1)
        #expect(out.actions == [FlightAction.flapsDown])
    }
}
