// SKYFORGE — Apache-2.0
// Keyboard and mouse adapter (Apple platforms). Keyboard: GCKeyboard on iOS, iPadOS and macOS.
// Mouse: GCMouse on iOS and iPadOS; AppKit events on macOS (covers mice and trackpads).
// Turns raw state into SFInput DeviceState once per frame. The maths lives in SFInput.
#if canImport(GameController)
import GameController
import os
import SFInput
#if os(macOS)
import AppKit
import CoreGraphics
#endif

/// Pointer totals written from device callbacks and read once per frame on the main actor.
final class PointerTotals: Sendable {
    struct Frame: Sendable {
        var dx = 0.0
        var dy = 0.0
        var scrollX = 0.0
        var scrollY = 0.0
    }

    private let lock = OSAllocatedUnfairLock(initialState: Frame())
    private let buttonLock = OSAllocatedUnfairLock(initialState: UInt8(0))

    static let leftBit: UInt8 = 1
    static let rightBit: UInt8 = 2
    static let middleBit: UInt8 = 4

    func addMove(dx: Double, dy: Double) {
        lock.withLock { $0.dx += dx; $0.dy += dy }
    }

    func addScroll(x: Double, y: Double) {
        lock.withLock { $0.scrollX += x; $0.scrollY += y }
    }

    func setButton(_ bit: UInt8, down: Bool) {
        buttonLock.withLock { if down { $0 |= bit } else { $0 &= ~bit } }
    }

    var buttons: UInt8 { buttonLock.withLock { $0 } }

    /// Returns the movement and scroll since the last call, then clears them.
    func take() -> Frame {
        lock.withLock { t -> Frame in
            let f = t
            t = Frame()
            return f
        }
    }
}

#if os(macOS)
/// Local AppKit monitor for mice and trackpads. Runs only while the app is active.
@MainActor
final class MacPointerMonitor {
    private var token: Any?

    init(totals: PointerTotals) {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]
        token = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MacPointerMonitor.record(event, into: totals)
            return event
        }
    }

    static func record(_ e: NSEvent, into t: PointerTotals) {
        switch e.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // AppKit deltas are positive up and right.
            t.addMove(dx: Double(e.deltaX), dy: Double(e.deltaY))
        case .scrollWheel:
            // Trackpads report precise points; scale them to roughly one unit per wheel notch.
            let s = e.hasPreciseScrollingDeltas ? 1.0 / 40 : 1.0
            t.addScroll(x: Double(e.scrollingDeltaX) * s, y: Double(e.scrollingDeltaY) * s)
        case .leftMouseDown: t.setButton(PointerTotals.leftBit, down: true)
        case .leftMouseUp: t.setButton(PointerTotals.leftBit, down: false)
        case .rightMouseDown: t.setButton(PointerTotals.rightBit, down: true)
        case .rightMouseUp: t.setButton(PointerTotals.rightBit, down: false)
        case .otherMouseDown: t.setButton(PointerTotals.middleBit, down: true)
        case .otherMouseUp: t.setButton(PointerTotals.middleBit, down: false)
        default: break
        }
    }
}
#endif

/// Keyboard names to GCKeyCode. Physical positions, so layouts keep the same key positions.
enum KeyboardKeyMap {
    static let table: [(String, GCKeyCode)] = [
        ("key.a", .keyA), ("key.b", .keyB), ("key.c", .keyC), ("key.d", .keyD), ("key.e", .keyE), ("key.f", .keyF),
        ("key.g", .keyG), ("key.h", .keyH), ("key.i", .keyI), ("key.j", .keyJ), ("key.k", .keyK), ("key.l", .keyL),
        ("key.m", .keyM), ("key.n", .keyN), ("key.o", .keyO), ("key.p", .keyP), ("key.q", .keyQ), ("key.r", .keyR),
        ("key.s", .keyS), ("key.t", .keyT), ("key.u", .keyU), ("key.v", .keyV), ("key.w", .keyW), ("key.x", .keyX),
        ("key.y", .keyY), ("key.z", .keyZ),
        ("key.0", .zero), ("key.1", .one), ("key.2", .two), ("key.3", .three), ("key.4", .four), ("key.5", .five),
        ("key.6", .six), ("key.7", .seven), ("key.8", .eight), ("key.9", .nine),
        ("key.f1", .F1), ("key.f2", .F2), ("key.f3", .F3), ("key.f4", .F4), ("key.f5", .F5), ("key.f6", .F6),
        ("key.f7", .F7), ("key.f8", .F8), ("key.f9", .F9), ("key.f10", .F10), ("key.f11", .F11), ("key.f12", .F12),
        ("key.space", .spacebar), ("key.escape", .escape), ("key.return", .returnOrEnter), ("key.tab", .tab),
        ("key.backspace", .deleteOrBackspace), ("key.capsLock", .capsLock), ("key.insert", .insert),
        ("key.delete", .deleteForward), ("key.home", .home), ("key.end", .end),
        ("key.pageUp", .pageUp), ("key.pageDown", .pageDown),
        ("key.up", .upArrow), ("key.down", .downArrow), ("key.left", .leftArrow), ("key.right", .rightArrow),
        ("key.minus", .hyphen), ("key.equal", .equalSign), ("key.leftBracket", .openBracket),
        ("key.rightBracket", .closeBracket), ("key.backslash", .backslash), ("key.semicolon", .semicolon),
        ("key.quote", .quote), ("key.grave", .graveAccentAndTilde), ("key.comma", .comma),
        ("key.period", .period), ("key.slash", .slash),
        ("key.keypad0", .keypad0), ("key.keypad1", .keypad1), ("key.keypad2", .keypad2), ("key.keypad3", .keypad3),
        ("key.keypad4", .keypad4), ("key.keypad5", .keypad5), ("key.keypad6", .keypad6), ("key.keypad7", .keypad7),
        ("key.keypad8", .keypad8), ("key.keypad9", .keypad9),
        ("key.keypadDecimal", .keypadPeriod), ("key.keypadPlus", .keypadPlus), ("key.keypadMinus", .keypadHyphen),
        ("key.keypadMultiply", .keypadAsterisk), ("key.keypadDivide", .keypadSlash), ("key.keypadEnter", .keypadEnter),
        ("key.leftShift", .leftShift), ("key.rightShift", .rightShift),
        ("key.leftControl", .leftControl), ("key.rightControl", .rightControl),
        ("key.leftOption", .leftAlt), ("key.rightOption", .rightAlt),
        ("key.leftCommand", .leftGUI), ("key.rightCommand", .rightGUI),
    ]
}

/// Reads keyboards and mice once per frame and produces SFInput device state.
@MainActor
public final class KeyboardMouseInput {
    public struct Frame: Sendable {
        public var state = InputMapper.DeviceState()
        /// Pointer delta for mouse-look this frame (points, positive up and right). Nil when mouse-look is off.
        public var look: (dx: Double, dy: Double)?
    }

    /// Held throttle (rest -1) and trim (rest 0), moved by held keys and scroll.
    public private(set) var holds: [FlightAxis: HeldAxis] = [
        .throttle: HeldAxis(rest: -1),
        .elevatorTrim: HeldAxis(rest: 0),
    ]
    public private(set) var yoke = MouseYoke()

    /// When true, mouse movement is mouse-look and the yoke is off. On macOS this also hides and
    /// detaches the cursor. On iPadOS it only changes the mode; the system pointer stays visible.
    public var pointerLocked = false {
        // Only act on a real change: CGDisplayHideCursor is reference counted, so repeated
        // hide calls would need as many show calls to bring the cursor back.
        didSet { if oldValue != pointerLocked { applyPointerLock() } }
    }

    private let totals = PointerTotals()
    private var seenMice: Set<ObjectIdentifier> = []
    #if os(macOS)
    private var monitor: MacPointerMonitor?
    #endif

    public init() {
        #if os(macOS)
        monitor = MacPointerMonitor(totals: totals)
        #endif
    }

    /// Advances held positions and the yoke by `dt` seconds and reports this frame's state.
    public func poll(dt: Double) -> Frame {
        attachMice()
        var pressed = Set<String>()
        var mods = Set<Modifier>()
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            for (name, code) in KeyboardKeyMap.table where kb.button(forKeyCode: code)?.isPressed == true {
                pressed.insert(name)
            }
            mods = Self.modifiers(from: kb)
        }
        let frame = totals.take()
        #if os(macOS)
        let buttons = totals.buttons
        if buttons & PointerTotals.leftBit != 0 { pressed.insert(MouseControlID.left) }
        if buttons & PointerTotals.rightBit != 0 { pressed.insert(MouseControlID.right) }
        if buttons & PointerTotals.middleBit != 0 { pressed.insert(MouseControlID.middle) }
        #else
        for mouse in GCMouse.mice() {
            guard let input = mouse.mouseInput else { continue }
            if input.leftButton.isPressed { pressed.insert(MouseControlID.left) }
            if input.rightButton?.isPressed == true { pressed.insert(MouseControlID.right) }
            if input.middleButton?.isPressed == true { pressed.insert(MouseControlID.middle) }
        }
        #endif

        for hold in KeyHold.defaults where pressed.contains(hold.key) {
            holds[hold.axis]?.hold(rate: hold.rate, dt: dt)
        }
        if let route = ScrollRouting.route(for: mods), frame.scrollY != 0 {
            holds[route.axis]?.step(frame.scrollY * route.step)
        }

        let lookOn = pointerLocked || pressed.contains(MouseControlID.middle)
        yoke.update(dx: frame.dx, dy: frame.dy, engaged: pressed.contains(MouseControlID.right) && !pointerLocked, dt: dt)

        var out = Frame()
        out.state.pressed = pressed
        out.state.modifiers = mods
        out.state.analog[MouseControlID.yokeX] = yoke.x
        out.state.analog[MouseControlID.yokeY] = yoke.y
        for (axis, held) in holds {
            if let id = KeyHoldID.analogID(for: axis) { out.state.analog[id] = held.value }
        }
        out.look = lookOn ? (frame.dx, frame.dy) : nil
        return out
    }

    /// Resets held throttle to idle and trim to zero, for example when a flight restarts.
    public func resetHolds() {
        for axis in holds.keys { holds[axis]?.reset() }
        yoke = MouseYoke()
    }

    private func attachMice() {
        #if !os(macOS)
        for mouse in GCMouse.mice() {
            let id = ObjectIdentifier(mouse)
            guard !seenMice.contains(id), let input = mouse.mouseInput else { continue }
            seenMice.insert(id)
            let totals = totals
            input.mouseMovedHandler = { _, dx, dy in
                totals.addMove(dx: Double(dx), dy: Double(dy))
            }
            input.scroll.valueChangedHandler = { _, x, y in
                totals.addScroll(x: Double(x), y: Double(y))
            }
        }
        #endif
    }

    private func applyPointerLock() {
        #if os(macOS)
        _ = CGAssociateMouseAndMouseCursorPosition(pointerLocked ? 0 : 1)
        if pointerLocked {
            _ = CGDisplayHideCursor(CGMainDisplayID())
        } else {
            _ = CGDisplayShowCursor(CGMainDisplayID())
        }
        #endif
    }

    private static func modifiers(from kb: GCKeyboardInput) -> Set<Modifier> {
        var mods = Set<Modifier>()
        if kb.button(forKeyCode: .leftShift)?.isPressed == true || kb.button(forKeyCode: .rightShift)?.isPressed == true {
            mods.insert(.shift)
        }
        if kb.button(forKeyCode: .leftControl)?.isPressed == true || kb.button(forKeyCode: .rightControl)?.isPressed == true {
            mods.insert(.control)
        }
        if kb.button(forKeyCode: .leftAlt)?.isPressed == true || kb.button(forKeyCode: .rightAlt)?.isPressed == true {
            mods.insert(.option)
        }
        if kb.button(forKeyCode: .leftGUI)?.isPressed == true || kb.button(forKeyCode: .rightGUI)?.isPressed == true {
            mods.insert(.command)
        }
        return mods
    }
}
#endif
