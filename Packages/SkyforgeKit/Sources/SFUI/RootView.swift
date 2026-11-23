// SKYFORGE — Apache-2.0
/// SFUI: SwiftUI front end (product `SkyforgeUI`).
public enum SFUIInfo { public static let moduleVersion = "0.1.0" }

#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import MetalKit
import SFRender
import SFQuickFlight
import SFNavData
import SFGameplay
import SFCareer

/// Root view shown by the app. Items that are not implemented yet are labelled honestly.
public struct SkyforgeRootView: View {
    @State private var showingSky = false
    @State private var showingFlight = false
    @State private var flightLocation: QuickFlightLocation = .defaultStart
    @State private var showingInstruments = false
    @State private var flightAircraft = AircraftCatalog.sf1Trainer
    @State private var flightMission: MissionDefinition?
    @State private var showingTutorial = false
    /// Remembered per device so the tutorial opens automatically only for a new player.
    @AppStorage("skyforge.tutorial.completed") private var tutorialCompleted = false

    public init() {}

    private var tutorialScreen: some View {
        QuickFlightView(location: .defaultStart, aircraft: AircraftCatalog.sf1Trainer, tutorial: true,
                        onTutorialFinished: { tutorialCompleted = true })
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Learn to fly: interactive tutorial") { showingTutorial = true }
                        .font(.headline)
                    Button("Fly now: \(Showcase.defaultAirport.name) (real world, works offline)") {
                        flightLocation = .defaultStart; showingFlight = true
                    }
                    .font(.headline)
                    NavigationLink("Choose an airport…") {
                        AirportPickerView { location in flightLocation = location; showingFlight = true }
                    }
                    Button("SkyWorld airfield (procedural, offline)") { flightLocation = .skyWorld; showingFlight = true }
                    NavigationLink("Pilot career: ranks, hangar, campaigns, awards") { CareerScreen() }
                    NavigationLink("Aircraft, missions and military flight") {
                        GameplayMenuView { aircraft, mission in
                            flightAircraft = aircraft; flightMission = mission
                            flightLocation = .defaultStart; showingFlight = true
                        }
                    }
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
                    NavigationLink("Acknowledgements and Data Attribution") { AcknowledgementsView() }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("SKYFORGE")
            #if os(iOS)
            .fullScreenCover(isPresented: $showingFlight) { QuickFlightView(location: flightLocation, aircraft: flightAircraft, mission: flightMission) }
            #else
            .sheet(isPresented: $showingFlight) { QuickFlightView(location: flightLocation, aircraft: flightAircraft, mission: flightMission).frame(minWidth: 1100, minHeight: 700) }
            #endif
            .onAppear { if !tutorialCompleted { showingTutorial = true } }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingTutorial) { tutorialScreen }
            #else
            .sheet(isPresented: $showingTutorial) { tutorialScreen.frame(minWidth: 1100, minHeight: 700) }
            #endif
            .onChange(of: showingFlight) { _, isShowing in
                if !isShowing { flightAircraft = AircraftCatalog.sf1Trainer; flightMission = nil }   // plain Quick Flight buttons fly the SF-1
            }
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
    @State private var query = ""
    @State private var db: NavDatabase?
    @State private var results: [AirportHit] = []
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
                TextField("Name, city or code, e.g. Heathrow, Tokyo, KSFO", text: $query)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { if let first = results.first { choose(first.airport.ident, first.airport.name) } }
                if db == nil {
                    ProgressView("Loading worldwide airports…")
                }
                ForEach(results) { hit in
                    Button {
                        choose(hit.airport.ident, hit.airport.name)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(hit.airport.name) (\(hit.airport.ident))")
                            Text(Self.subtitle(hit)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if db != nil, results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No airport with an open runway matches \"\(query)\".").font(.footnote).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Any airport in the world") } footer: {
                Text("Airports from OurAirports (public domain). Only airports with an open runway are listed. Free imagery (USGS, Sentinel-2) and elevation (Terrarium) download once, about 5–15 MB, and are cached.")
            }
        }
        .navigationTitle("Choose an airport")
        .task { await loadDatabase() }
        .onChange(of: query) { _, q in refresh(q) }
        .alert("Download scenery?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Download and fly") {
                if let p = pending { onPick(.realAirport(ident: p.ident, name: p.name)); dismiss() }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("\(pending?.name ?? "") needs about 5–15 MB of free imagery and elevation tiles. They are cached for next time.")
        }
    }

    /// Parses the bundled OurAirports snapshot off the main thread, once.
    private func loadDatabase() async {
        guard db == nil else { return }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try BundledNavData.load() }.value
            db = loaded
            refresh(query)
        } catch {
            message = "The bundled airport database could not be read (\(error.localizedDescription))."
        }
    }

    /// Re-ranks the worldwide search off the main thread. Stale results are dropped if the query has moved on.
    private func refresh(_ q: String) {
        guard let db else { return }
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let hits = await Task.detached(priority: .userInitiated) {
                AirportSearch.search(text, in: db, limit: 60)
            }.value
            if text == query.trimmingCharacters(in: .whitespacesAndNewlines) { results = hits }
        }
    }

    /// Showcase airports fly straight away from the bundle; any other airport asks before downloading scenery.
    private func choose(_ ident: String, _ name: String) {
        message = nil
        if let a = Showcase.airports.first(where: { $0.ident == ident }) {
            onPick(.realAirport(ident: a.ident, name: a.name)); dismiss(); return
        }
        pending = (ident, name)
    }

    private static func subtitle(_ hit: AirportHit) -> String {
        let a = hit.airport
        let place = [a.municipality, a.country].filter { !$0.isEmpty }.joined(separator: ", ")
        let kind = a.type.replacingOccurrences(of: "_", with: " ")
        let runways = hit.flyableRunways == 1 ? "1 runway" : "\(hit.flyableRunways) runways"
        return [place, kind, runways].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
#endif
