// SKYFORGE — Apache-2.0
/// SFUI: SwiftUI front end (product `SkyforgeUI`).
public enum SFUIInfo { public static let moduleVersion = "0.1.0" }

#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import MetalKit
import SFRender
import SFQuickFlight
import SFNavData

/// Root view shown by the app. Items that are not implemented yet are labelled honestly.
public struct SkyforgeRootView: View {
    @State private var showingSky = false
    @State private var showingFlight = false
    @State private var flightLocation: QuickFlightLocation = .defaultStart
    @State private var showingInstruments = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Fly now: \(Showcase.defaultAirport.name) (real world, works offline)") {
                        flightLocation = .defaultStart; showingFlight = true
                    }
                    .font(.headline)
                    NavigationLink("Choose an airport…") {
                        AirportPickerView { location in flightLocation = location; showingFlight = true }
                    }
                    Button("SkyWorld airfield (procedural, offline)") { flightLocation = .skyWorld; showingFlight = true }
                } header: {
                    Text("Quick Flight")
                }
                Section {
                    Button("Renderer preview (physically based sky, day to twilight)") { showingSky = true }
                    Button("Instruments demo (steam gauges and SF-1000 PFD)") { showingInstruments = true }
                    NavigationLink("Controls and bindings") { BindingsView() }
                } header: {
                    Text("Available")
                }
                Section {
                    Text("World map: not yet available")
                    Text("Settings: not yet available")
                } header: {
                    Text("Coming in later phases")
                }
                Section {
                    Text("SKYFORGE is free and open source (Apache-2.0).")
                        .font(.footnote)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("SKYFORGE")
            #if os(iOS)
            .fullScreenCover(isPresented: $showingFlight) { QuickFlightView(location: flightLocation) }
            #else
            .sheet(isPresented: $showingFlight) { QuickFlightView(location: flightLocation).frame(minWidth: 1100, minHeight: 700) }
            #endif
            .sheet(isPresented: $showingInstruments) {
                InstrumentDemoView()
            }
            .sheet(isPresented: $showingSky) {
                SkyPreviewView()
                    .ignoresSafeArea()
            }
        }
    }
}

#if os(macOS)
struct SkyPreviewView: NSViewRepresentable {
    final class Coordinator { var renderer: PhysicalSkyViewDelegate? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.renderer = try? PhysicalSkyViewDelegate(view: view)
        view.delegate = context.coordinator.renderer
        view.preferredFramesPerSecond = 60
        return view
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}
#else
struct SkyPreviewView: UIViewRepresentable {
    final class Coordinator { var renderer: PhysicalSkyViewDelegate? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.renderer = try? PhysicalSkyViewDelegate(view: view)
        view.delegate = context.coordinator.renderer
        view.preferredFramesPerSecond = 60
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}
#endif

/// Showcase airports (bundled, offline) and any other airport in the bundled OurAirports data
/// (imagery and elevation download once, after the user agrees; App Review Guideline 4.2.3).
struct AirportPickerView: View {
    let onPick: (QuickFlightLocation) -> Void
    @State private var ident = ""
    @State private var pending: (ident: String, name: String)?
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(Showcase.airports, id: \.ident) { a in
                    Button {
                        onPick(.realAirport(ident: a.ident, name: a.name)); dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(a.name) (\(a.ident))")
                            Text("\(a.kind) · included, works offline").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Included airports") }
            Section {
                TextField("ICAO code, e.g. KSFO", text: $ident)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .onSubmit(lookUp)
                Button("Fly from this airport", action: lookUp).disabled(ident.trimmingCharacters(in: .whitespaces).count < 3)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Any airport") } footer: {
                Text("Free imagery (USGS, Sentinel-2) and elevation (Terrarium) download once, about 5–15 MB, and are cached.")
            }
        }
        .navigationTitle("Choose an airport")
        .alert("Download scenery?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Download and fly") {
                if let p = pending { onPick(.realAirport(ident: p.ident, name: p.name)); dismiss() }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("\(pending?.name ?? "") needs about 5–15 MB of free imagery and elevation tiles. They are cached for next time.")
        }
    }

    private func lookUp() {
        let code = ident.trimmingCharacters(in: .whitespaces).uppercased()
        if let a = Showcase.airports.first(where: { $0.ident == code }) {
            onPick(.realAirport(ident: a.ident, name: a.name)); dismiss(); return
        }
        guard let db = try? BundledNavData.load(), let apt = db.airport(code) else {
            message = "\(code) is not in the bundled OurAirports data."; return
        }
        guard db.runways(at: code).contains(where: { $0.hasGeometry && !$0.closed }) else {
            message = "\(apt.name) has no runway geometry in OurAirports."; return
        }
        message = nil
        pending = (code, apt.name)
    }
}
#endif
