// SKYFORGE — Apache-2.0
// Quick Flight screen: Metal world (sky, terrain, SkyWorld objects, aircraft), the SF-1 Trainer
// flight model at 120 Hz, touch/keyboard/gamepad input and a compact SF-1000 PFD overlay.
#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import MetalKit
import simd
import SFRender
import SFPreview
import SFInput
import SFInstruments
import SFQuickFlight
import SFPerf
import SFPlatform
import SFContent
import SFImagery
import SFAtmosphere
import SFWeather
import SFFlightModel
import SFGameplay
import SFCareer
import SFGameplayUI
import SFTraffic
import SFATC

/// Where Quick Flight takes place.
public enum QuickFlightLocation: Hashable, Sendable {
    /// The procedural SkyWorld airfield (fully offline).
    case skyWorld
    /// A real airport with free orthoimagery and elevation tiles (network once, then cached).
    case realAirport(ident: String, name: String)

    public static let merrittIsland = QuickFlightLocation.realAirport(ident: "KCOI", name: "Merritt Island, Florida")
    /// The default start: the first showcase airport (imagery and elevation ship in the app).
    public static let defaultStart = QuickFlightLocation.realAirport(ident: Showcase.defaultAirport.ident, name: Showcase.defaultAirport.name)

    /// METAR stations for the live sky, nearest first (KCOI itself does not report; Titusville and Melbourne do).
    public var metarStations: [String] {
        switch self {
        case .skyWorld: []
        case .realAirport(let ident, _): Showcase.airports.first { $0.ident == ident }?.metarStations ?? [ident]
        }
    }

    public var title: String {
        switch self {
        case .skyWorld: "SkyWorld airfield (procedural)"
        case .realAirport(let ident, let name): "\(name) (\(ident), real imagery)"
        }
    }
}

@MainActor
final class QuickFlightController: NSObject, ObservableObject, MTKViewDelegate {
    enum Status: Equatable { case loading(String), ready, failed(String) }
    @Published var status: Status = .loading("Building the airfield…")
    @Published var hud = InstrumentData()
    @Published var crashed = false
    /// In-cockpit view (3D panel with a live SF-1000 PFD) instead of the chase camera.
    @Published var cockpit = false
    private var pfdBusy = false
    /// Camera-following sharp imagery (texture streaming): the loaded region, its tile sources and state.
    private var realRegion: RealWorldRegion?
    private var tileTransport: (any HTTPTransport)?
    private var photoCrowns: [ImageryDelighting.Crown] = []
    private var tileCache: KeyedCache?
    private var detailBusy = false
    private var lastDetailPosition: SIMD3<Double>?
    @Published var attribution: [String] = []
    /// SkyWorld detail for this device tier (used directly, or as the offline fallback).
    private var skyWorldDetail: QuickFlightDetail = .phone

    private(set) var world: any FlightWorld
    private(set) var session: QuickFlightSession
    /// Aircraft, AI, weapons and mission logic that run on top of the flight session.
    private(set) var director: GameplayDirector
    @Published var gameplayHUD: GameplayHUD?
    @Published var missionResult: MissionResult?
    @Published var unlockMessage: String?
    /// AI traffic and the tower, for free flight only (missions keep their own rules).
    private(set) var traffic: TrafficSystem?
    private(set) var atc: ATCController?
    private var atcClock = 0.0
    /// The tower's last messages, shown under the HUD.
    @Published var atcLines: [String] = []
    /// Speaks the tower's messages with Apple's on-device voice. Off until the pilot turns it on.
    @Published var atcVoice = false
    private let speaker = AVSpeechATCSpeaker()
    let spec: PlaneSpec
    let mission: MissionDefinition?
    private let controlFilter: ControlFilter?
    private var resultSaved = false
    /// Weapon controls set by the on-screen buttons (cannon is held, launch and cycle are one-shot).
    var fireHeld = false
    private var launchRequested = false
    private var cycleRequested = false
    var touch = InputMapper.DeviceState()
    private var renderer: WorldRenderer?
    private var governor: QualityGovernor?
    private var qualityBase: WorldRenderer.Settings = .high
    private var depth: MTLTexture?
    private var last: CFTimeInterval?
    private var hudCounter = 0
    private let start: QuickFlightStart
    let location: QuickFlightLocation

    init(start: QuickFlightStart, location: QuickFlightLocation, aircraft: PlaneSpec, mission: MissionDefinition?) {
        self.start = start
        self.location = location
        spec = aircraft
        self.mission = mission
        let filter = GameplayDirector.makeControlFilter(for: aircraft)
        controlFilter = filter
        let provisional = QuickFlightWorld()
        world = provisional
        let built = Self.makeFlight(world: provisional, start: start, spec: aircraft, mission: mission, filter: filter)
        session = built.session
        director = built.director
        let trafficSetup = Self.makeTraffic(world: provisional, mission: mission)
        traffic = trafficSetup?.system
        atc = trafficSetup?.tower
        super.init()
    }

    /// AI traffic and the tower for a free flight at this world's runway. Missions get none.
    private static func makeTraffic(world: any FlightWorld, mission: MissionDefinition?) -> (system: TrafficSystem, tower: ATCController)? {
        guard mission == nil else { return nil }
        let runway = TrafficRunway(threshold: world.runwayThreshold, heading: world.runwayHeading,
                                   length: world.runwayLengthMetres, elevation: world.runwayElevation)
        return (TrafficSystem(runway: runway), ATCController(runwayDesignator: runway.designator))
    }

    /// A flight session and director for a world: the aircraft, its wind and (for missions) the airborne start.
    private static func makeFlight(world: any FlightWorld, start: QuickFlightStart, spec: PlaneSpec,
                                   mission: MissionDefinition?, filter: ControlFilter?) -> (session: QuickFlightSession, director: GameplayDirector) {
        let frame = RunwayFrame(world: world)
        let wind = mission?.wind.windNED(runwayHeading: frame.heading) ?? .zero
        var s = QuickFlightSession(world: world, start: start, aircraft: spec.config, approachSpeed: spec.approachSpeed,
                                   approachFlaps: spec.approachFlaps, wind: wind)
        if let m = mission {
            let (state, inputs) = GameplaySession.makeInitialState(spawn: m.spawn, aircraft: spec, frame: frame, wind: wind,
                                                                   terrain: FlightWorldTerrain(world))
            s.place(state: state, inputs: inputs)
        }
        s.inputFilter = filter
        s.gearDownBelowSpeed = GameplayDirector.gearDownSpeed(for: spec)
        return (s, GameplayDirector(aircraft: spec, frame: frame, mission: mission))
    }

    private func resetFlight(_ start: QuickFlightStart) {
        let built = Self.makeFlight(world: world, start: start, spec: spec, mission: mission, filter: controlFilter)
        session = built.session
        director = built.director
        gameplayHUD = nil; missionResult = nil; unlockMessage = nil; resultSaved = false
        fireHeld = false
        let trafficSetup = Self.makeTraffic(world: world, mission: mission)
        traffic = trafficSetup?.system
        atc = trafficSetup?.tower
        atcClock = 0
        atcLines = []
    }

    func launchMissile() { launchRequested = true }
    func cycleTarget() { cycleRequested = true }

    func attach(_ view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { status = .failed("No Metal device."); return }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.delegate = self
        let tier = DeviceTierDetector.detect(device: device)
        skyWorldDetail = tier == .low ? .phone : (tier == .medium ? .tablet : .desktop)
        let real: Bool
        if case .realAirport = location { real = true } else { real = false }
        let lighting = real ? LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: 300)
                            : LightingSetup.physicalPreset(.goldenHour, azimuthDegrees: 255, cameraHeightMetres: world.runwayElevation + 50)
        do { renderer = try WorldRenderer(device: device, colorFormat: .bgra8Unorm, lighting: lighting) }
        catch { status = .failed("Renderer: \(error)"); return }
        do { try renderer?.setCockpit(Cockpit.mesh(), screen: Cockpit.pfdCorners.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }) }
        catch { attribution.append("Cockpit view unavailable: \(error)") }
        // Fair-weather cumulus; march quality by device tier (the march runs at half resolution).
        renderer?.clouds = .fairWeather
        qualityBase = tier == .low ? .low : (tier == .medium ? .medium : .high)
        renderer?.apply(qualityBase)
        governor = QualityGovernor(tier: PerfTier(deviceTier: tier), targetFPS: 60)
        switch location {
        case .skyWorld:
            let detail: QuickFlightDetail = tier == .low ? .phone : (tier == .medium ? .tablet : .desktop)
            loadSkyWorld(detail: detail)
        case .realAirport(let ident, let name):
            let detail: RealWorldDetail = tier == .low ? .phone : (tier == .medium ? .tablet : .desktop)
            loadRealAirport(ident: ident, name: name, detail: detail)
        }
    }

    private func loadSkyWorld(detail: QuickFlightDetail) {
        let world = QuickFlightWorld()
        let aircraftID = spec.id
        Task.detached(priority: .userInitiated) {
            let env = world.buildEnvironmentInstanced(detail: detail)
            let trees = RealWorldRenderData.trees(env.trees)
            let aircraft = QuickFlightWorld.aircraftMesh(for: aircraftID)
            await MainActor.run {
                do {
                    try self.renderer?.setEnvironment(env.soup)
                    try self.renderer?.setTrees(trees)
                    try self.renderer?.setAircraft(aircraft)
                    self.status = .ready
                } catch { self.status = .failed("Upload: \(error)") }
            }
        }
    }

    private func loadRealAirport(ident: String, name: String, detail: RealWorldDetail) {
        status = .loading("Loading \(name)…")
        let start = self.start
        let aircraftID = spec.id
        let stations = location.metarStations
        Task.detached(priority: .userInitiated) {
            do {
                let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let cache = try? KeyedCache(root: caches.appendingPathComponent("SkyforgeTiles", isDirectory: true))
                // Bundled showcase tiles first (offline), then the network, then the on-disk cache.
                let transport = Showcase.transport(for: ident, fallback: URLSessionTransport())
                let region = try await RealWorldRegion.load(airport: ident, detail: detail, transport: transport,
                                                            cache: cache) { msg in
                    Task { @MainActor in self.status = .loading(msg) }
                }
                await MainActor.run { self.status = .loading("Building terrain and trees…") }
                let data = RealWorldRenderData(region: region)
                // Live sky from the nearest METAR (keyless aviationweather.gov); fair-weather cumulus if none answers.
                let weather = await WeatherClouds.live(stations: stations, fieldElevation: region.runwayElevation,
                                                       service: METARService(transport: URLSessionTransport(), cache: cache))
                let aircraft = QuickFlightWorld.aircraftMesh(for: aircraftID)
                await MainActor.run {
                    do {
                        try self.renderer?.setRealWorld(data)
                        try self.renderer?.setAircraft(aircraft)
                        self.world = region
                        self.realRegion = region
                        self.photoCrowns = data.photoCrowns
                        self.tileTransport = transport
                        self.tileCache = cache
                        self.resetFlight(start)
                        self.attribution = region.attribution + (weather.map { ["Weather: \($0.raw) (aviationweather.gov)"] } ?? [])
                        self.renderer?.clouds = weather?.layer ?? .fairWeather(fieldElevation: Float(region.runwayElevation))
                        self.status = .ready
                    } catch { self.status = .failed("Upload: \(error)") }
                }
            } catch {
                // Offline fallback: fly the procedural SkyWorld airfield instead of stopping.
                await MainActor.run {
                    self.attribution = ["Could not load \(name) (\(error.localizedDescription)); flying the offline SkyWorld airfield instead."]
                    self.loadSkyWorld(detail: self.skyWorldDetail)
                }
            }
        }
    }

    /// Rasterizes the PFD off the main thread (~15 Hz) and uploads it to the cockpit screen.
    private func refreshCockpitPFD() {
        guard !pfdBusy else { return }
        pfdBusy = true
        let d = session.data
        Task.detached(priority: .userInitiated) {
            let w = 512, h = 320
            let img = Raster2D.render(PFD.draw(d, options: PFDOptions(), width: Double(w), height: Double(h)), width: w, height: h)
            let bytes = img.bytes()
            await MainActor.run {
                self.renderer?.updateCockpitScreen(rgb: bytes, width: w, height: h)
                self.pfdBusy = false
            }
        }
    }

    func restart(_ s: QuickFlightStart) {
        resetFlight(mission == nil ? s : start)
        crashed = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { depth = nil }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, last.map { now - $0 } ?? 0)
        last = now
        guard status == .ready, let r = renderer, let drawable = view.currentDrawable,
              let cmd = r.queue.makeCommandBuffer() else { return }
        var device = GameControllerInput.poll()
        device.analog.merge(touch.analog) { a, b in abs(a) > abs(b) ? a : b }
        device.pressed.formUnion(touch.pressed)
        session.update(realDt: dt, device: device)
        stepGameplay(dt: dt)
        stepTraffic(dt: dt)
        let tex = drawable.texture
        if depth == nil || depth!.width != tex.width || depth!.height != tex.height {
            depth = try? r.makeDepth(width: tex.width, height: tex.height)
        }
        guard let depth else { return }
        let camera: WorldCamera
        r.cockpitView = cockpit
        if cockpit {
            let ck = session.cockpitCamera()
            camera = WorldCamera(position: ck.position, target: ck.target, verticalFOVDeg: 62, up: ck.up, near: 0.05)
            if hudCounter % 4 == 0 { refreshCockpitPFD() }
        } else {
            let cam = session.chaseCamera()
            camera = WorldCamera(position: cam.position, target: cam.target)
        }
        let c = session.bodyToENUColumns
        // AI traffic: NED snapshots to ENU poses. Heading is NED (0 = north), so body x is (sin h, cos h, 0) in ENU.
        r.trafficPoses = (traffic?.snapshots ?? []).map { t in
            let h = t.heading
            return WorldRenderer.TrafficPose(position: SIMD3(t.positionNED.y, t.positionNED.x, -t.positionNED.z),
                                             bodyToENU: simd_double3x3(columns: (SIMD3(sin(h), cos(h), 0),
                                                                                 SIMD3(cos(h), -sin(h), 0),
                                                                                 SIMD3(0, 0, -1))))
        }
        let encodeStart = CACurrentMediaTime()
        do {
            try r.encode(cmd: cmd, colour: tex, depth: depth, camera: camera,
                         aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        } catch {
            status = .failed("Rendering stopped: \(error)")   // say so instead of showing a blank view
            return
        }
        cmd.present(drawable)
        cmd.commit()
        // Feed the governor: GPU time from the most recent completed frame, CPU time as this frame's encode cost.
        let encodeMS = (CACurrentMediaTime() - encodeStart) * 1_000
        if let plan = governor?.update(GovernorSample(gpuMS: r.frameTelemetry.lastGPUMS, cpuMS: encodeMS), now: now) {
            r.applyQuality(plan, base: qualityBase)
        }
        hudCounter += 1
        if hudCounter % 2 == 0 {
            hud = session.data; crashed = session.crashed
            if mission != nil || !spec.armament.isEmpty { gameplayHUD = director.hud(mach: machNumber, time: session.time) }
        }
        if hudCounter % 60 == 0 { refreshDetail() }
    }

    private var machNumber: Double {
        EnvelopeMath.mach(trueAirspeed: session.lastOutputs?.trueAirspeed ?? 0, altitudeMSL: session.state.altitude)
    }

    /// Steps AI traffic and the tower, and gives the aircraft the wakes of the heavy traffic near it.
    private func stepTraffic(dt: Double) {
        guard traffic != nil else { return }
        traffic?.step(dt: dt)
        _ = traffic?.drainEvents()   // nothing reads these yet; drain so the buffer stays short
        atcClock += dt
        if atcClock >= GameplaySession.atcInterval {
            atcClock = 0
            let simTime = traffic?.time ?? 0
            let snapshots = traffic?.snapshots ?? []
            let wind = ATCWind(windNED: session.environment.windNED)
            let instructions = atc?.update(time: simTime, traffic: snapshots, wind: wind) ?? []
            for instruction in instructions {
                if let clearance = instruction.clearance { _ = traffic?.issue(clearance, to: instruction.aircraftID) }
                if atcVoice { speaker.speak(instruction.text) }
            }
            atcLines = atc?.recentLines(3) ?? []
        }
        session.setWakes(traffic?.wakesNear(session.state.positionNED) ?? [])
    }

    /// Runs AI, weapons, the envelope monitor and the mission against the flight, once per frame.
    private func stepGameplay(dt: Double) {
        guard !director.isFinished, let outputs = session.lastOutputs else { return }
        let snapshot = FlightSnapshot(time: session.time, state: session.state, outputs: outputs,
                                      flaps: session.inputs.flaps, heightAGL: session.heightAboveGround,
                                      crashed: session.crashed, crashReason: session.crashed ? "Crashed into the ground" : nil)
        director.advance(dt: dt, snapshot: snapshot,
                         weaponInput: WeaponInput(fireGun: fireHeld, launchMissile: launchRequested, cycleTarget: cycleRequested))
        launchRequested = false; cycleRequested = false
        if director.monitor.structuralFailure && !session.crashed { session.markCrashed() }
        if let result = director.runtime?.result, !resultSaved { saveResult(result) }
    }

    /// Records a finished mission in the pilot's progress file and reports anything it unlocked.
    private func saveResult(_ result: MissionResult) {
        resultSaved = true
        missionResult = result
        let store = ProgressStore(url: ProgressStore.defaultURL)
        var progress = store.load()
        let unlocked = progress.record(result)
        do { try store.save(progress) } catch { attribution.append("Could not save mission progress: \(error.localizedDescription)") }
        let report = FlightReport.fromMission(id: result.missionID, aircraftID: result.aircraftID, success: result.success,
                                              score: result.score, elapsed: result.elapsed, kills: result.kills,
                                              crashed: session.crashed, endedAt: Int(Date().timeIntervalSince1970))
        if let outcome = SaveStore(url: SaveStore.defaultURL).record(report), let lvl = outcome.leveledUpTo {
            attribution.append("Career: reached level \(lvl)")
        }
        let names = unlocked.aircraft.map(\.name) + unlocked.missions.map(\.title)
        if result.success && !names.isEmpty { unlockMessage = "Unlocked: " + names.joined(separator: ", ") }
    }

    /// Re-centres the sharp imagery layer ahead of the aircraft once it has drifted 40 % of its half extent:
    /// tiles come from the pack, the cache or the network, and the texture is built off the main thread,
    /// then swapped in (one detail texture at a time, so memory stays bounded).
    private func refreshDetail() {
        guard let region = realRegion, region.detailStreamable, !detailBusy, let r = renderer, let transport = tileTransport else { return }
        let p = session.positionENU
        let heading = lastDetailPosition.map { p - $0 } ?? .zero
        lastDetailPosition = p
        let target = region.detailCentre(position: p, velocity: heading)
        if let cur = r.detailImageryPlacement {
            let d = target - cur.centre
            if (d * d).sum().squareRoot() < cur.half * 0.4 { return }
        }
        detailBusy = true
        let cache = tileCache, crowns = photoCrowns
        nonisolated(unsafe) let builder = r
        Task.detached(priority: .utility) {
            var mosaic = await region.streamDetail(around: target, transport: transport, cache: cache)
            if mosaic != nil { ImageryDelighting.removePhotoTrees(&mosaic!, crowns: crowns) { x, y in region.ground.water(x, y) ?? 0 } }
            let prepared = mosaic.flatMap {
                try? builder.makeImagery(RealWorldRenderData.Imagery(centre: $0.centre, halfExtent: $0.halfExtent, size: $0.size, rgb: $0.rgb))
            }
            await MainActor.run {
                if let prepared { self.renderer?.setDetailImagery(prepared) }
                self.detailBusy = false
            }
        }
    }
}

#if os(macOS)
struct QuickFlightMetalView: NSViewRepresentable {
    let controller: QuickFlightController
    func makeNSView(context: Context) -> MTKView { let v = MTKView(); controller.attach(v); return v }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}
#else
struct QuickFlightMetalView: UIViewRepresentable {
    let controller: QuickFlightController
    func makeUIView(context: Context) -> MTKView { let v = MTKView(); controller.attach(v); return v }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}
#endif

public struct QuickFlightView: View {
    @StateObject private var controller: QuickFlightController
    @Environment(\.dismiss) private var dismiss

    public init(start: QuickFlightStart = .runway, location: QuickFlightLocation = .skyWorld,
                aircraft: PlaneSpec = AircraftCatalog.sf1Trainer, mission: MissionDefinition? = nil) {
        _controller = StateObject(wrappedValue: QuickFlightController(start: start, location: location,
                                                                      aircraft: aircraft, mission: mission))
    }

    public var body: some View {
        ZStack {
            QuickFlightMetalView(controller: controller).ignoresSafeArea()
            VStack {
                HStack(alignment: .top) {
                    Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                    Menu("Restart") {
                        Button("On the runway") { controller.restart(.runway) }
                        Button("On a 3° final") { controller.restart(.final) }
                    }
                    .buttonStyle(.bordered)
                    Button(controller.cockpit ? "Chase view" : "Cockpit view") { controller.cockpit.toggle() }
                        .buttonStyle(.bordered)
                    if controller.atc != nil {
                        Button(controller.atcVoice ? "Tower voice on" : "Tower voice off") { controller.atcVoice.toggle() }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    if !controller.cockpit {
                        InstrumentCanvas(PFD.draw(controller.hud, options: PFDOptions()))
                            .frame(maxWidth: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
                if let hud = controller.gameplayHUD {
                    HStack(alignment: .top) {
                        MissionHUDView(hud: hud).frame(maxWidth: 380)
                        Spacer()
                    }
                    .padding(.horizontal)
                }
                if !controller.atcLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.atcLines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).foregroundStyle(.white)
                        }
                    }
                    .padding(6)
                    .background(.black.opacity(0.45))
                    .frame(maxWidth: 380, alignment: .leading)
                    .padding(.horizontal)
                }
                Spacer()
                if let hud = controller.gameplayHUD, !controller.spec.armament.isEmpty, hud.status == .inProgress || hud.status == nil {
                    WeaponButtons(controller: controller, hasMissiles: controller.spec.armament.contains(.heatMissile))
                }
                if !controller.attribution.isEmpty {
                    Text(controller.attribution.joined(separator: " · "))
                        .font(.caption2).padding(6).background(.black.opacity(0.45)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                #if os(iOS)
                TouchFlightControls { controller.touch = $0 }
                #else
                Text("W/S pitch · A/D roll · Q/E rudder · gamepad right trigger throttle · F/Shift+F flaps")
                    .font(.caption).padding(8).background(.black.opacity(0.4)).foregroundStyle(.white)
                #endif
            }
            switch controller.status {
            case .loading(let msg): ProgressView(msg).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .failed(let msg): Text(msg).padding().background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            case .ready: EmptyView()
            }
            if let result = controller.missionResult {
                MissionResultCard(result: result, unlock: controller.unlockMessage,
                                  retry: { controller.restart(.runway) }, close: { dismiss() })
            } else if controller.crashed {
                VStack(spacing: 12) {
                    Text("Crashed").font(.title.bold())
                    Button("Restart on the runway") { controller.restart(.runway) }.buttonStyle(.borderedProminent)
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
private extension PerfTier {
    init(deviceTier: DeviceTier) {
        switch deviceTier {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        case .ultra: self = .ultra
        }
    }
}

#endif
