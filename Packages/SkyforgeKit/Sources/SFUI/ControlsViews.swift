// SKYFORGE — Apache-2.0
// Touch yoke/throttle overlay and the press-to-bind bindings screen. The logic lives in SFInput
// (tested on Linux); these views only collect touches and poll devices.
#if canImport(SwiftUI)
import SwiftUI
import SFInput
#if canImport(GameController)
import SFPlatform
#endif

/// On-screen stick (right) and throttle lever (left). Reports a DeviceState every change.
public struct TouchFlightControls: View {
    public var onChange: (InputMapper.DeviceState) -> Void
    @State private var stick = TouchStick(centerX: 0, centerY: 0, radius: 1)
    @State private var throttle = TouchThrottle(minY: 0, maxY: 1, value: 0)

    public init(onChange: @escaping (InputMapper.DeviceState) -> Void) { self.onChange = onChange }

    public var body: some View {
        HStack(alignment: .bottom) {
            throttleLever.frame(width: 70, height: 220)
            Spacer()
            stickPad.frame(width: 200, height: 200)
        }
        .padding(24)
    }

    private var throttleLever: some View {
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
    }

    private var stickPad: some View {
        GeometryReader { geo in
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
                .onEnded { _ in stick.release(); publish() })
            .accessibilityLabel("Control stick")
        }
    }

    private func publish() { onChange(TouchControls.deviceState(stick: stick, throttle: throttle)) }
}

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
                    BindingsStore.save(profile)
                    status = "User bindings cleared; defaults apply."
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
            BindingsStore.save(profile)
            status = conflicts.isEmpty ? "Bound \(b.control)."
                : "Bound \(b.control). Also used by: \(conflicts.map { title($0.target) }.joined(separator: ", "))."
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

    public static func save(_ p: BindingProfile) {
        guard let url, let d = try? p.exportJSON() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}
#endif
