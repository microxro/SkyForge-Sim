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
import SFPlatform
import SFContent
import SFAtmosphere

/// Where Quick Flight takes place.
public enum QuickFlightLocation: Hashable, Sendable {
    /// The procedural SkyWorld airfield (fully offline).
    case skyWorld
    /// A real airport with free orthoimagery and elevation tiles (network once, then cached).
    case realAirport(ident: String, name: String)

    public static let merrittIsland = QuickFlightLocation.realAirport(ident: "KCOI", name: "Merritt Island, Florida")

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
    @Published var attribution: [String] = []

    private(set) var world: any FlightWorld = QuickFlightWorld()
    private(set) var session: QuickFlightSession
    var touch = InputMapper.DeviceState()
    private var renderer: WorldRenderer?
    private var depth: MTLTexture?
    private var last: CFTimeInterval?
    private var hudCounter = 0
    private let start: QuickFlightStart
    let location: QuickFlightLocation

    init(start: QuickFlightStart, location: QuickFlightLocation) {
        self.start = start
        self.location = location
        session = QuickFlightSession(world: world, start: start)
        super.init()
    }

    func attach(_ view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { status = .failed("No Metal device."); return }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.delegate = self
        let tier = DeviceTierDetector.detect(device: device)
        let real: Bool
        if case .realAirport = location { real = true } else { real = false }
        let lighting = real ? LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: 300)
                            : LightingSetup.physicalPreset(.goldenHour, azimuthDegrees: 255, cameraHeightMetres: world.runwayElevation + 50)
        do { renderer = try WorldRenderer(device: device, colorFormat: .bgra8Unorm, lighting: lighting) }
        catch { status = .failed("Renderer: \(error)"); return }
        try? renderer?.setCockpit(Cockpit.mesh(), screen: Cockpit.pfdCorners.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) })
        // Fair-weather cumulus; march quality by device tier (the march runs at half resolution).
        renderer?.clouds = .fairWeather
        renderer?.cloudSteps = tier == .low ? 40 : (tier == .medium ? 56 : 80)
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
        Task.detached(priority: .userInitiated) {
            let soup = world.buildEnvironment(detail: detail)
            let aircraft = QuickFlightWorld.aircraftMesh()
            await MainActor.run {
                do {
                    try self.renderer?.setEnvironment(soup)
                    try self.renderer?.setAircraft(aircraft)
                    self.status = .ready
                } catch { self.status = .failed("Upload: \(error)") }
            }
        }
    }

    private func loadRealAirport(ident: String, name: String, detail: RealWorldDetail) {
        status = .loading("Loading \(name)…")
        let start = self.start
        Task.detached(priority: .userInitiated) {
            do {
                let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let cache = try? KeyedCache(root: caches.appendingPathComponent("SkyforgeTiles", isDirectory: true))
                let region = try await RealWorldRegion.load(airport: ident, detail: detail, transport: URLSessionTransport(),
                                                            cache: cache) { msg in
                    Task { @MainActor in self.status = .loading(msg) }
                }
                await MainActor.run { self.status = .loading("Building terrain and trees…") }
                let data = RealWorldRenderData(region: region)
                let aircraft = QuickFlightWorld.aircraftMesh()
                await MainActor.run {
                    do {
                        try self.renderer?.setRealWorld(data)
                        try self.renderer?.setAircraft(aircraft)
                        self.world = region
                        self.session = QuickFlightSession(world: region, start: start)
                        self.attribution = region.attribution
                        self.status = .ready
                    } catch { self.status = .failed("Upload: \(error)") }
                }
            } catch {
                await MainActor.run { self.status = .failed("Could not load \(name): \(error.localizedDescription)") }
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
        session = QuickFlightSession(world: world, start: s)
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
        try? r.encode(cmd: cmd, colour: tex, depth: depth, camera: camera,
                      aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        cmd.present(drawable)
        cmd.commit()
        hudCounter += 1
        if hudCounter % 2 == 0 { hud = session.data; crashed = session.crashed }
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

    public init(start: QuickFlightStart = .runway, location: QuickFlightLocation = .skyWorld) {
        _controller = StateObject(wrappedValue: QuickFlightController(start: start, location: location))
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
                    Spacer()
                    if !controller.cockpit {
                        InstrumentCanvas(PFD.draw(controller.hud, options: PFDOptions()))
                            .frame(maxWidth: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
                Spacer()
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
            if controller.crashed {
                VStack(spacing: 12) {
                    Text("Crashed").font(.title.bold())
                    Button("Restart on the runway") { controller.restart(.runway) }.buttonStyle(.borderedProminent)
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
#endif
