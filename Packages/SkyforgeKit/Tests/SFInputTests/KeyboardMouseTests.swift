import Testing
import Foundation
@testable import SFInput

@Suite struct KeyboardMouseTests {
    @Test func keyIDsAreUniqueAndPrefixed() {
        let ids = KeyboardKeyID.all
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("key.") })
        #expect(ids.count == 26 + 10 + 12 + 27 + 16 + 8)
        #expect(ids.contains("key.w") && ids.contains("key.keypadPlus") && ids.contains("key.f12"))
    }

    @Test func heldAxisClampsAndSteps() {
        var t = HeldAxis(rest: -1)
        #expect(t.value == -1)
        t.hold(rate: 0.8, dt: 1)
        #expect(abs(t.value - (-0.2)) < 1e-9)
        t.hold(rate: 5, dt: 1)
        #expect(t.value == 1)
        t.hold(rate: -5, dt: 1)
        #expect(t.value == -1)
        t.step(0.5)
        #expect(t.value == -0.5)
        t.step(.nan)
        #expect(t.value == -0.5)
        t.reset()
        #expect(t.value == -1)
    }

    @Test func yokeHoldsThenRecentres() {
        var y = MouseYoke()
        y.update(dx: 180, dy: -90, engaged: true, dt: 1.0 / 60)
        #expect(abs(y.x - 1) < 1e-9)
        #expect(abs(y.y + 0.5) < 1e-9)
        var last = abs(y.y)
        for _ in 0..<300 {
            y.update(dx: 0, dy: 0, engaged: false, dt: 1.0 / 60)
            #expect(abs(y.y) <= last + 1e-12)
            last = abs(y.y)
        }
        #expect(y.x == 0 && y.y == 0)
    }

    @Test func scrollRoutesByModifier() {
        #expect(ScrollRouting.route(for: [])?.axis == .throttle)
        #expect(ScrollRouting.route(for: [.option])?.axis == .elevatorTrim)
        #expect(ScrollRouting.route(for: [.shift]) == nil)
    }

    @Test func heldThrottleReachesAxisThroughMapper() {
        var m = InputMapper(profiles: [.defaults, .keyboardMouseDefaults])
        // Trigger convention: -1 is idle, so a held value of 0 is half throttle.
        let out = m.evaluate(.init(analog: [KeyHoldID.throttle: 0]))
        #expect(abs((out.axes[.throttle] ?? -1) - 0.5) < 1e-9)
        let idle = m.evaluate(.init(analog: [KeyHoldID.throttle: -1]))
        #expect(idle.axes[.throttle] == 0)
    }

    @Test func mouseYokeMapsRollAndInvertedPitch() {
        var m = InputMapper(profiles: [.keyboardMouseDefaults])
        let out = m.evaluate(.init(analog: [MouseControlID.yokeX: 1, MouseControlID.yokeY: 1]))
        #expect(out.axes[.roll] == 1)
        #expect(out.axes[.pitch] == -1)
    }

    @Test func keyboardMouseDefaultsHaveNoConflicts() throws {
        #expect(InputMapper.conflicts(in: .keyboardMouseDefaults).isEmpty)
        let data = try BindingProfile.keyboardMouseDefaults.exportJSON()
        #expect(try BindingProfile.importJSON(data) == .keyboardMouseDefaults)
    }

    @Test func keyHoldDefaultsUseKnownKeys() {
        let ids = Set(KeyboardKeyID.all)
        #expect(KeyHold.defaults.allSatisfy { ids.contains($0.key) })
    }
}
