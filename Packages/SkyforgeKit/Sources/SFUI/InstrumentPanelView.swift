// SKYFORGE — Apache-2.0
// SwiftUI Canvas renderer for SFInstruments draw lists, plus a live demo screen that flies the
// real flight model. The GPU path for in-flight use (Metal 2D) consumes the same DrawList.
#if canImport(SwiftUI)
import SwiftUI
import SFInstruments

/// Draws a DrawList scaled to the view.
public struct InstrumentCanvas: View {
    public let list: DrawList
    public init(_ list: DrawList) { self.list = list }

    public var body: some View {
        Canvas { context, size in
            var ctx = context
            ctx.scaleBy(x: size.width / list.width, y: size.height / list.height)
            var stack: [GraphicsContext] = []
            for cmd in list.commands {
                switch cmd {
                case let .fill(pts, c):
                    ctx.fill(path(pts, close: true), with: .color(color(c)))
                case let .stroke(pts, w, c):
                    ctx.stroke(path(pts, close: false), with: .color(color(c)),
                               style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                case let .pushClip(shape):
                    stack.append(ctx)
                    switch shape {
                    case let .rect(x0, y0, x1, y1):
                        ctx.clip(to: Path(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)))
                    case let .circle(c, r):
                        ctx.clip(to: Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
                    }
                case .popClip:
                    if let prev = stack.popLast() { ctx = prev }
                }
            }
        }
        .aspectRatio(list.width / list.height, contentMode: .fit)
    }

    private func path(_ pts: [Point2], close: Bool) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: CGPoint(x: first.x, y: first.y))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
        if close { p.closeSubpath() }
        return p
    }

    private func color(_ c: RGBA) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

/// Live instrument demo: the SF-1 Trainer flown by a bank/pitch hold, shown on steam gauges or the SF-1000 PFD.
public struct InstrumentDemoView: View {
    public enum Layout: String, CaseIterable, Identifiable { case steam = "Steam gauges", pfd = "SF-1000 PFD"; public var id: String { rawValue } }
    @State private var layout: Layout = .pfd
    @State private var scenario = InstrumentScenario(bankDeg: 20, reverseEvery: 40)
    @State private var lastTick: Date?

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Picker("Layout", selection: $layout) {
                ForEach(Layout.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            TimelineView(.animation) { timeline in
                let list = layout == .pfd
                    ? PFD.draw(scenario.data, options: PFDOptions(selectedAltitudeFt: 3_500))
                    : SteamGauges.sixPack(scenario.data)
                InstrumentCanvas(list)
                    .onChange(of: timeline.date) { _, now in advance(to: now) }
            }
            Text("Simulated: SF-1 Trainer flight model in a climbing turn that reverses every 40 s.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical)
        .background(Color.black)
    }

    private func advance(to now: Date) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let steps = min(30, Int((now.timeIntervalSince(last) * 120).rounded()))
        for _ in 0..<steps { scenario.step() }
    }
}
#endif
