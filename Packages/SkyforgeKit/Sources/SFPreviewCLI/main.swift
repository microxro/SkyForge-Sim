// SKYFORGE — Apache-2.0
// sfpreview: CPU preview renderer CLI (§8.6).
//   sfpreview --version
//   sfpreview icon <out.png> <size>
//   sfpreview instruments <sixpack|pfd> <out.png> [width]
//   sfpreview sky <out.png> <sunElevationDeg> [width] [yawDeg] [viewHeightKm]
//   sfpreview --scene <name> [--time <preset>] [--seed <n>] [--width W --height H] [--ss N] --out <file.png>
import Foundation
import SFPreview
import SFInstruments
import SFAtmosphere
import SFQuickFlight
import SFImagery
import SFContent
import SFTerrainCore

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--version" {
    print("sfpreview \(SFPreviewInfo.moduleVersion)")
    exit(0)
}
if args.first == "icon" {
    guard args.count == 3, let size = Int(args[2]), size >= 16, size <= 2048 else { fail("usage: sfpreview icon <out.png> <size>") }
    let px = IconRenderer.render(size: size)
    do { try PNGEncoder.encodeRGB(width: size, height: size, rgb: px).write(to: URL(fileURLWithPath: args[1])) }
    catch { fail("sfpreview: cannot write \(args[1]): \(error)", code: 1) }
    exit(0)
}

if args.first == "instruments" {
    guard args.count >= 3, ["sixpack", "pfd"].contains(args[1]) else { fail("usage: sfpreview instruments <sixpack|pfd> <out.png> [width]") }
    let start = Date()
    let data = InstrumentScenario.climbingTurn()
    let list: DrawList
    let aspect: Double
    if args[1] == "sixpack" { list = SteamGauges.sixPack(data); aspect = 1_000.0 / 1_500 }
    else { list = PFD.draw(data, options: PFDOptions(selectedAltitudeFt: 3_500, selectedHeadingDeg: 90)); aspect = 800.0 / 1_280 }
    let w = args.count > 3 ? Int(args[3]) ?? 1_500 : 1_500
    let h = Int((Double(w) * aspect).rounded())
    let img = Raster2D.render(list, width: w, height: h)
    do { try PNGEncoder.encodeRGB(width: w, height: h, rgb: img.bytes()).write(to: URL(fileURLWithPath: args[2])) }
    catch { fail("sfpreview: cannot write \(args[2]): \(error)", code: 1) }
    print(String(format: "sfpreview: instruments %@ -> %@ (%d primitives, %.2fs) IAS %.1f ALT %.0f VS %.0f pitch %.1f roll %.1f hdg %.0f turn %.2f ball %.2f rpm %.0f",
                 args[1], args[2], list.primitiveCount, Date().timeIntervalSince(start), data.indicatedAirspeedKt, data.indicatedAltitudeFt,
                 data.verticalSpeedFpm, data.pitchDeg, data.rollDeg, data.headingDeg, data.turnRateDegPerSec, data.slipBall, data.rpm))
    exit(0)
}

if args.first == "sky" {
    guard args.count >= 3, let el = Double(args[2]) else { fail("usage: sfpreview sky <out.png> <sunElevationDeg> [width] [yawDeg] [viewHeightKm]") }
    let w = args.count > 3 ? Int(args[3]) ?? 1_280 : 1_280
    let yaw = args.count > 4 ? Double(args[4]) ?? 0 : 0
    let hKm = args.count > 5 ? Double(args[5]) ?? 0.3 : 0.3
    let h = w * 9 / 16
    let start = Date()
    let model = SkyModel(sunElevationDeg: el, viewHeightKm: hKm)
    let lutTime = Date().timeIntervalSince(start)
    let rgb = SkyPreview.render(model, width: w, height: h, yawDeg: yaw)
    do { try PNGEncoder.encodeRGB(width: w, height: h, rgb: rgb).write(to: URL(fileURLWithPath: args[1])) }
    catch { fail("sfpreview: cannot write \(args[1]): \(error)", code: 1) }
    print(String(format: "sfpreview: sky el %.1f° -> %@ (LUTs %.2fs, total %.2fs, exposure %.1f)", el, args[1], lutTime,
                 Date().timeIntervalSince(start), SkyPreview.autoExposure(model)))
    exit(0)
}

if args.first == "clouds" {
    guard args.count >= 3, let el = Double(args[2]) else { fail("usage: sfpreview clouds <out.png> <sunElevationDeg> [width] [yawDeg] [viewHeightKm] [coverage] [pitchDeg]") }
    let w = args.count > 3 ? Int(args[3]) ?? 960 : 960
    let yaw = args.count > 4 ? Double(args[4]) ?? 0 : 0
    let hKm = args.count > 5 ? Double(args[5]) ?? 0.3 : 0.3
    let cov = args.count > 6 ? Float(args[6]) ?? 0.42 : 0.42
    let pitch = args.count > 7 ? Double(args[7]) ?? 10 : 10
    let start = Date()
    let model = SkyModel(sunElevationDeg: el, viewHeightKm: hKm)
    var layer = CloudLayer.fairWeather; layer.coverage = cov
    let rgb = SkyPreview.renderClouds(model, layer: layer, width: w, height: w * 9 / 16, pitchDeg: pitch, yawDeg: yaw)
    do { try PNGEncoder.encodeRGB(width: w, height: w * 9 / 16, rgb: rgb).write(to: URL(fileURLWithPath: args[1])) }
    catch { fail("sfpreview: cannot write \(args[1]): \(error)", code: 1) }
    print(String(format: "sfpreview: clouds el %.1f° cov %.2f -> %@ (%.2fs)", el, cov, args[1], Date().timeIntervalSince(start)))
    exit(0)
}

if args.first == "pfd-bench" {
    // Time the CPU PFD rasterizer at the cockpit texture size (Apple builds update it at ~15 Hz).
    let w = args.count > 1 ? Int(args[1]) ?? 512 : 512, h = w * 5 / 8
    var d = InstrumentData(); d.indicatedAirspeedKt = 92; d.indicatedAltitudeFt = 2_350; d.pitchDeg = 4; d.rollDeg = -12; d.headingDeg = 109
    let t0 = Date()
    for _ in 0..<20 { _ = Raster2D.render(PFD.draw(d, width: Double(w), height: Double(h)), width: w, height: h) }
    print(String(format: "pfd %dx%d: %.1f ms per frame", w, h, Date().timeIntervalSince(t0) / 20 * 1_000))
    exit(0)
}

if args.first == "quickflight-stats" {
    let world = QuickFlightWorld()
    for (name, d) in [("phone", QuickFlightDetail.phone), ("tablet", .tablet), ("desktop", .desktop)] {
        let t0 = Date()
        let soup = world.buildEnvironment(detail: d)
        let mb = Double(soup.triangleCount * 3 * 20) / 1_048_576
        print(String(format: "quickflight %@: %d triangles, %.0f MB at 20 B/vertex, built in %.1fs", name, soup.triangleCount, mb, Date().timeIntervalSince(t0)))
    }
    exit(0)
}

if args.first == "real" {
    // sfpreview real <out.png> [width] [time]   (fetches imagery/elevation once, cached in .skyforge/cache)
    guard args.count >= 2 else { fail("usage: sfpreview real <out.png> [width] [time]") }
    let w = args.count > 2 ? Int(args[2]) ?? 1_280 : 1_280
    let tp = args.count > 3 ? TimePreset(rawValue: args[3]) : nil
    let site = RealWorldSite.merrittIsland
    let cacheRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SKYFORGE_CACHE"] ?? ".skyforge/cache")
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var inputs: RealWorldScenes.Inputs?
    let t0 = Date()
    Task.detached {   // detached: top-level code runs on the main actor, which sem.wait() blocks
        let transport = CurlTransport()
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let cache = try? KeyedCache(root: cacheRoot)
        let dem = try? GlobalDEM.bundled()
        let ts = TerrainStreamer(transport: transport, cache: cache, baseline: dem)
        let fwd = SIMD2(site.camera.forward.x, site.camera.forward.y)
        let fl = (fwd * fwd).sum().squareRoot()
        let focus = SIMD2(site.camera.position.x, site.camera.position.y) + fwd / fl * 2_500
        let provider: any ImageryProvider = USGSImageryProvider().covers(latitude: site.origin.latitude, longitude: site.origin.longitude)
            ? USGSImageryProvider() : Sentinel2CloudlessProvider()
        let farProvider = Sentinel2CloudlessProvider()
        let isNear = ImageryStreamer(provider: provider, transport: transport, cache: cache)
        let isFar = ImageryStreamer(provider: farProvider, transport: transport, cache: cache)
        async let near = ImageryMosaic.build(origin: site.origin, centre: focus, halfExtent: 3_200, size: 3_072, provider: provider, streamer: isNear)
        async let far = ImageryMosaic.build(origin: site.origin, centre: focus, halfExtent: 40_000, size: 2_048, provider: farProvider, streamer: isFar)
        async let hNear = HeightMosaic.build(origin: site.origin, centre: focus, halfExtent: 3_200, size: 400, zoom: 14, streamer: ts)
        async let hFar = HeightMosaic.build(origin: site.origin, centre: focus, halfExtent: 40_000, size: 400, zoom: 10, streamer: ts)
        inputs = RealWorldScenes.Inputs(heights: await hNear, farHeights: await hFar, near: await near, far: await far)
        sem.signal()
    }
    sem.wait()
    let fetch = Date().timeIntervalSince(t0)
    let h = w * 9 / 16
    let (img, stats, counts) = RealWorldScenes.render(site: site, inputs: inputs!, width: w, height: h, time: tp)
    do { try img.png().write(to: URL(fileURLWithPath: args[1])) } catch { fail("sfpreview: cannot write \(args[1]): \(error)", code: 1) }
    let nearCov = inputs!.near.coverage.filter { $0 > 0 }.count * 100 / inputs!.near.coverage.count
    print(String(format: "sfpreview: real %@ -> %@ (fetch %.1fs, build %.1fs, raster %.1fs, shade %.1fs; %d tris; near imagery z%d %d%% covered) %@",
                 site.name, args[1], fetch, stats.buildSeconds, stats.rasterSeconds, stats.shadeSeconds, stats.triangles,
                 inputs!.near.zoom, nearCov, counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))
    exit(0)
}

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let sceneName = value("--scene") else {
    fail("usage: sfpreview --scene <\(PreviewScene.allCases.map(\.rawValue).joined(separator: "|"))> [--time <\(TimePreset.allCases.map(\.rawValue).joined(separator: "|"))>] [--seed n] --out file.png")
}
guard let scene = PreviewScene(rawValue: sceneName) else {
    fail("sfpreview: scene '\(sceneName)' is not available yet. Available: \(PreviewScene.allCases.map(\.rawValue).joined(separator: ", "))")
}
let time = value("--time").map { name -> TimePreset in
    guard let t = TimePreset(rawValue: name) else { fail("sfpreview: unknown time preset \(name)") }
    return t
}
let seed = value("--seed").flatMap(UInt64.init) ?? 1
let width = value("--width").flatMap(Int.init) ?? 1280
let height = value("--height").flatMap(Int.init) ?? 720
let ss = value("--ss").flatMap(Int.init) ?? 3
guard let out = value("--out") else { fail("sfpreview: --out <file.png> is required") }

let start = Date()
let (img, stats, counts) = PreviewScenes.render(scene, time: time, seed: seed, width: width, height: height, supersample: ss)
do { try img.png().write(to: URL(fileURLWithPath: out)) } catch { fail("sfpreview: cannot write \(out): \(error)", code: 1) }
let total = Date().timeIntervalSince(start)
print(String(format: "sfpreview: %@ %@ seed %llu -> %@ (%d tris; build %.1fs shadow %.1fs raster %.1fs shade %.1fs; total %.1fs) %@",
             scene.rawValue, (time ?? scene.defaultTime).rawValue, seed, out, stats.triangles,
             stats.buildSeconds, stats.shadowSeconds, stats.rasterSeconds, stats.shadeSeconds, total,
             counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))


/// Developer-tool transport that shells out to curl, so the CLI honours the host's proxy and CA
/// configuration on Linux (the app uses URLSessionTransport). Tests never use either.
struct CurlTransport: HTTPTransport {
    func get(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                p.arguments = ["-sS", "-f", "--max-time", "60", "-A", "SKYFORGE-sfpreview/0.1", url.absoluteString]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: TransportError.offline); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { cont.resume(returning: data) } else { cont.resume(throwing: TransportError.status(Int(p.terminationStatus))) }
            }
        }
    }
}
