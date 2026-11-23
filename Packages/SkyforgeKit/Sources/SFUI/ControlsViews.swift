// SKYFORGE — Apache-2.0
// Touch yoke/throttle overlay and the press-to-bind bindings screen. The logic lives in SFInput
// (tested on Linux); these views only collect touches and poll devices.
#if canImport(SwiftUI)
import SwiftUI
import SFInput
#if canImport(GameController)
import SFPlatform
#endif
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// On-screen flight controls for iPhone and iPad: stick, throttle, rudder, flap buttons and, when enabled,
/// device tilt. Each control publishes a DeviceState that the flight mapper reads, so the sensitivity in
/// `TouchLayout` and any rebinding apply. Camera gestures are a separate surface (`CameraGestureSurface`).
public struct TouchFlightControls: View {
    public let layout: TouchLayout
    public var onChange: (InputMapper.DeviceState) -> Void
    @State private var stick = TouchStick(centerX: 0, centerY: 0, radius: 1)
    @State private var throttle = TouchThrottle(minY: 0, maxY: 1, value: 0)
    @State private var rudder = 0.0
    @State private var pressed: Set<String> = []
    @State private var tilt: MotionTiltInput?
    private let tick = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    public init(layout: TouchLayout, onChange: @escaping (InputMapper.DeviceState) -> Void) {
        self.layout = layout.clamped
        self.onChange = onChange
    }

    public var body: some View {
        let c = layout
        VStack(spacing: 14 * c.scale) {
            if c.showRudder {
                rudderBar(c).frame(width: 240 * c.scale, height: 44 * c.scale)
            }
            HStack(alignment: .bottom, spacing: 16) {
                if c.stickSide == .right {
                    throttleLever(c)
                    Spacer(minLength: 0)
                    flapColumn(c)
                    Spacer(minLength: 0)
                    stickPad(c)
                } else {
                    stickPad(c)
                    Spacer(minLength: 0)
                    flapColumn(c)
                    Spacer(minLength: 0)
                    throttleLever(c)
                }
            }
        }
        .padding(24)
        .opacity(c.opacity)
        .onAppear { syncTilt() }
        .onDisappear { tilt?.stop() }
        .onReceive(tick) { _ in
            if layout.tiltEnabled { publish() }
        }
    }

    private func syncTilt() {
        guard layout.tiltEnabled else {
            tilt?.stop()
            return
        }
        if tilt == nil { tilt = MotionTiltInput(orientation: .landscapeLeft) }
        tilt?.start()
    }

    private func publish() {
        var state = TouchControls.deviceState(stick: stick, throttle: throttle, rudder: rudder)
        state.pressed = pressed
        if layout.tiltEnabled, let tilt {
            state.analog.merge(tilt.poll().analog) { _, new in new }
        }
        onChange(state)
    }

    private func stickPad(_ c: TouchLayout) -> some View {
        let side = 200 * c.scale
        return GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().fill(.black.opacity(0.35))
                Circle().stroke(.white.opacity(0.4), lineWidth: 2)
                Circle().fill(.white.opacity(0.85)).frame(width: r * 0.5, height: r * 0.5)
                    .offset(x: stick.x * r * 0.75, y: stick.y * r * 0.75)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    stick = TouchStick(centerX: geo.size.width / 2, centerY: geo.size.height / 2, radius: r * 0.75)
                    stick.touch(atX: g.location.x, y: g.location.y)
                    publish()
                }
                .onEnded { _ in
                    if c.stickSpringReturn { stick.release() }
                    publish()
                })
            .accessibilityLabel("Control stick")
        }
        .frame(width: side, height: side)
    }

    private func throttleLever(_ c: TouchLayout) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.35))
                RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.18))
                    .frame(height: geo.size.height * throttle.value)
                Text("\(Int((throttle.value * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                throttle = TouchThrottle(minY: 0, maxY: geo.size.height, value: throttle.value)
                throttle.touch(atY: g.location.y)
                publish()
            })
            .accessibilityLabel("Throttle")
            .accessibilityValue("\(Int((throttle.value * 100).rounded())) percent")
        }
        .frame(width: 70 * c.scale, height: 220 * c.scale)
    }

    /// Spring-return rudder bar: drag left or right, let go to centre.
    private func rudderBar(_ c: TouchLayout) -> some View {
        GeometryReader { geo in
            ZStack {
                Capsule().fill(.black.opacity(0.35))
                Capsule().stroke(.white.opacity(0.4), lineWidth: 2)
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: 26 * c.scale, height: geo.size.height * 0.7)
                    .offset(x: rudder * geo.size.width * 0.4)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let half = geo.size.width / 2
                    rudder = max(-1, min(1, (g.location.x - half) / max(1, half * 0.8)))
                    publish()
                }
                .onEnded { _ in
                    rudder = 0
                    publish()
                })
            .accessibilityLabel("Rudder")
        }
    }

    private func flapColumn(_ c: TouchLayout) -> some View {
        VStack(spacing: 12 * c.scale) {
            if c.showFlapButtons {
                flapButton("Flaps down", control: TouchControls.flapsDown, c)
                flapButton("Flaps up", control: TouchControls.flapsUp, c)
            }
            if c.tiltEnabled {
                Button("Level") {
                    tilt?.calibrate()
                    publish()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// A touch button: held while the finger is down, so the flight sees a pressed control for those frames.
    private func flapButton(_ title: String, control: String, _ c: TouchLayout) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 96 * c.scale, height: 44 * c.scale)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(pressed.contains(control) ? 0.95 : 0.4), lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed.contains(control) else { return }
                    pressed.insert(control)
                    publish()
                }
                .onEnded { _ in
                    pressed.remove(control)
                    publish()
                })
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }
}

/// Camera gestures for the flight view: a pinch sets the chase distance, a two-finger drag orbits the camera
/// and a double tap toggles the cockpit view. It sits under the controls, so the controls keep their touches.
struct CameraGestureSurface: UIViewRepresentable {
    var onPinch: (Double) -> Void
    var onDrag: (Double) -> Void
    var onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.numberOfTapsRequired = 2
        pinch.delegate = context.coordinator
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CameraGestureSurface

        init(_ parent: CameraGestureSurface) { self.parent = parent }

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            guard g.state == .changed else { return }
            parent.onPinch(Double(g.scale))
            g.scale = 1
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            guard g.state == .changed else { return }
            parent.onDrag(Double(g.translation(in: g.view).x))
            g.setTranslation(.zero, in: g.view)
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            parent.onDoubleTap()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

/// Bindings screen: lists every axis and action with its current bindings; "Bind" waits for the
/// next key, button or stick movement (Esc cancels, 10 s timeout) and warns about conflicts.
public struct BindingsView: View {
    @State private var profile: BindingProfile = BindingsStore.load()
    @State private var capture: BindingCapture?
    @State private var status = "Choose Bind, then press a key or button, or move a stick. Esc cancels."
    @State private var lastTick: Date?

    public init() {}

    private var rows: [BindingTarget] { FlightAxis.allCases.map { .axis($0) } + FlightAction.allCases.map { .action($0) } }

    public var body: some View {
        List {
            Section { Text(status).font(.footnote) }
            Section("Controls") {
                ForEach(rows, id: \.self) { target in
                    HStack {
                        Text(title(target))
                        Spacer()
                        Text(bound(target)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        Button(capture?.target == target ? "Waiting…" : "Bind") { begin(target) }
                            .disabled(capture != nil)
                    }
                }
            }
            Section {
                Button("Restore defaults", role: .destructive) {
                    profile = BindingProfile(name: "User", layer: .device, bindings: [])
                    status = "User bindings cleared; defaults apply." + BindingsStore.saveNote(profile)
                }
            }
        }
        .navigationTitle("Controls")
        .background(TimelineView(.animation(paused: capture == nil)) { tl in
            Color.clear.onChange(of: tl.date) { _, now in tick(now) }
        })
    }

    private func title(_ t: BindingTarget) -> String {
        switch t { case .axis(let a): return a.rawValue.capitalized + " (axis)"; case .action(let a): return a.rawValue }
    }

    private func bound(_ t: BindingTarget) -> String {
        let mapper = InputMapper(profiles: [.defaults, .touchDefaults, profile])
        let list = mapper.effectiveBindings(context: .flight, aircraftID: nil).filter { $0.target == t }
        return list.isEmpty ? "—" : list.map { b in (b.modifiers.map(\.rawValue).sorted() + [b.control]).joined(separator: "+") }.joined(separator: ", ")
    }

    private func begin(_ t: BindingTarget) {
        let existing = InputMapper(profiles: [.defaults, .touchDefaults, profile]).effectiveBindings(context: .flight, aircraftID: nil)
        capture = BindingCapture(target: t, existing: existing)
        lastTick = nil
        status = "Waiting for input for \(title(t))…"
    }

    private func tick(_ now: Date) {
        guard var c = capture else { return }
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        #if canImport(GameController)
        let state = GameControllerInput.poll()
        #else
        let state = InputMapper.DeviceState()
        #endif
        let outcome = c.feed(state, dt: dt)
        capture = c
        switch outcome {
        case .waiting: return
        case .cancelled: status = "Cancelled."
        case .timedOut: status = "No input within 10 s."
        case let .captured(b, conflicts):
            profile.bindings.removeAll { $0.target == b.target && $0.device == b.device }
            profile.bindings.append(b)
            let note = BindingsStore.saveNote(profile)
            status = (conflicts.isEmpty ? "Bound \(b.control)."
                : "Bound \(b.control). Also used by: \(conflicts.map { title($0.target) }.joined(separator: ", ")).") + note
        }
        capture = nil
    }
}

/// User binding layer persisted as JSON in Application Support.
public enum BindingsStore {
    static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SKYFORGE", isDirectory: true).appendingPathComponent("bindings.json")
    }

    public static func load() -> BindingProfile {
        guard let url, let d = try? Data(contentsOf: url), let p = try? BindingProfile.importJSON(d) else {
            return BindingProfile(name: "User", layer: .device, bindings: [])
        }
        return p
    }

    public enum SaveError: Error { case noApplicationSupport }

    /// Writes the user layer; throws when it could not be stored (the UI says so instead of implying it was kept).
    public static func save(_ p: BindingProfile) throws {
        guard let url else { throw SaveError.noApplicationSupport }
        let d = try p.exportJSON()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url, options: .atomic)
    }

    /// Saves and returns "" on success, or a sentence saying the change applies to this session only.
    static func saveNote(_ p: BindingProfile) -> String {
        do { try save(p); return "" } catch { return " Not saved (\(error.localizedDescription)): applies until the app quits." }
    }
}
/// Touch layout persisted as JSON in Application Support, next to the bindings file.
public enum TouchSettingsStore {
    static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SKYFORGE", isDirectory: true).appendingPathComponent("touch.json")
    }

    /// The stored layout, or the defaults when nothing valid is stored.
    public static func load() -> TouchLayout {
        guard let url, let d = try? Data(contentsOf: url), let layout = try? TouchLayout.decode(d) else { return TouchLayout() }
        return layout
    }

    public static func save(_ layout: TouchLayout) throws {
        guard let url else { throw BindingsStore.SaveError.noApplicationSupport }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try layout.encoded().write(to: url, options: .atomic)
    }
}
#endif
