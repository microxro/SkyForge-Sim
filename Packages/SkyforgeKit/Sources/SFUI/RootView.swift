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
    /// Set when the tutorial is finished, so the Discovery Flight opens once the tutorial screen has closed.
    @State private var startDiscoveryFlight = false
    /// Remembered per device so the tutorial opens automatically only for a new player.
    @AppStorage("skyforge.tutorial.completed") private var tutorialCompleted = false

    public init() {}

    private var tutorialScreen: some View {
        QuickFlightView(location: .defaultStart, aircraft: AircraftCatalog.sf1Trainer, tutorial: true,
                        onTutorialFinished: { tutorialCompleted = true; startDiscoveryFlight = true })
    }

    /// Hands the finished tutorial to the flight school: the first lesson is the Discovery Flight.
    private func startDiscoveryIfRequested() {
        guard startDiscoveryFlight else { return }
        startDiscoveryFlight = false
        guard let lesson = FlightSchoolCurriculum.lesson(id: "fs-discovery"),
              let mission = MissionCatalog.mission(id: lesson.missionID) else { return }
        flightAircraft = AircraftCatalog.sf1Trainer
        flightMission = mission
        flightLocation = .defaultStart
        showingFlight = true
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    SFHubSection(title: "Fly") {
                        Button {
                            showingTutorial = true
                        } label: {
                            SFHubRowLabel(title: "Learn to fly", subtitle: "Interactive tutorial, then a Discovery Flight", symbol: "graduationcap")
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 60)
                        NavigationLink {
                            AirportPickerView { location in flightLocation = location; showingFlight = true }
                        } label: {
                            SFHubRowLabel(title: "Choose an airport", subtitle: "Search every airport in the bundled data", symbol: "globe.americas")
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 60)
                        Button {
                            flightLocation = .skyWorld; showingFlight = true
                        } label: {
                            SFHubRowLabel(title: "SkyWorld airfield", subtitle: "Procedural, works offline", symbol: "sparkles")
                        }
                        .buttonStyle(.plain)
                    }
                    SFHubSection(title: "Career and missions") {
                        NavigationLink {
                            CareerScreen()
                        } label: {
                            SFHubRowLabel(title: "Pilot career", subtitle: "Ranks, hangar, campaigns and awards", symbol: "trophy")
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 60)
                        NavigationLink {
                            GameplayMenuView { aircraft, mission in
                                flightAircraft = aircraft; flightMission = mission
                                flightLocation = .defaultStart; showingFlight = true
                            }
                        } label: {
                            SFHubRowLabel(title: "Aircraft and missions", subtitle: "Pick a plane, then fly free or a mission", symbol: "scope")
                        }
                        .buttonStyle(.plain)
                    }
                    SFHubSection(title: "Tools") {
                        Button {
                            showingSky = true
                        } label: {
                            SFHubRowLabel(title: "Sky preview", subtitle: "Physically based sky, day to twilight", symbol: "sun.horizon")
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 60)
                        Button {
                            showingInstruments = true
                        } label: {
                            SFHubRowLabel(title: "Instruments", subtitle: "Steam gauges and the SF-1000 PFD", symbol: "gauge.with.dots.needle.67percent")
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 60)
                        NavigationLink {
                            BindingsView()
                        } label: {
                            SFHubRowLabel(title: "Controls and bindings", symbol: "gamepad")
                        }
                        .buttonStyle(.plain)
                    }
                    SFHubSection(title: "Coming soon") {
                        SFHubRowLabel(title: "World map", subtitle: "Plan routes across the whole Earth", symbol: "map", showsChevron: false)
                            .opacity(0.6)
                        Divider().padding(.leading, 60)
                        SFHubRowLabel(title: "Settings", subtitle: "Graphics, controls and accessibility", symbol: "slider.horizontal.3", showsChevron: false)
                            .opacity(0.6)
                    }
                    SFHubSection(title: "About") {
                        Text("SKYFORGE is free and open source (Apache-2.0). No ads, no paid unlocks.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(16)
                        Divider().padding(.leading, 16)
                        NavigationLink {
                            AcknowledgementsView()
                        } label: {
                            SFHubRowLabel(title: "Acknowledgements and data attribution", symbol: "doc.text")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("SKYFORGE")
            #if os(iOS)
            .fullScreenCover(isPresented: $showingFlight) { QuickFlightView(location: flightLocation, aircraft: flightAircraft, mission: flightMission) }
            #else
            .sheet(isPresented: $showingFlight) { QuickFlightView(location: flightLocation, aircraft: flightAircraft, mission: flightMission).frame(minWidth: 1100, minHeight: 700) }
            #endif
            .onAppear { if !tutorialCompleted { showingTutorial = true } }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingTutorial, onDismiss: startDiscoveryIfRequested) { tutorialScreen }
            #else
            .sheet(isPresented: $showingTutorial, onDismiss: startDiscoveryIfRequested) { tutorialScreen.frame(minWidth: 1100, minHeight: 700) }
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

    /// The first thing a pilot sees: the promise of the game and one big button to fly now.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fly the real world")
                .font(.largeTitle.weight(.heavy))
            Text("Real airports, real weather and real terrain, free and open source.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                flightLocation = .defaultStart; showingFlight = true
            } label: {
                Label("Fly now from \(Showcase.defaultAirport.name)", systemImage: "airplane.departure")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Text("Works offline. Scenery is bundled.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SFHubStyle.cornerRadius + 6))
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
        let db: NavDatabase
        do { db = try BundledNavData.load() } catch {
            message = "The bundled airport database could not be read (\(error.localizedDescription))."; return
        }
        guard let apt = db.airport(code) else {
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
