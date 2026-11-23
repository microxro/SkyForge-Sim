// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
import Foundation
import Metal
import simd
@testable import SFRender
import SFQuickFlight
import SFContent
import SFPreview
import SFInstruments

/// Metal frames of the bundled showcase airports, loaded fully offline from their tile packs
/// (review frames; logged as SKYFORGE_PNG in CI). The ultra frames are the look review: best detail and
/// render settings, several cameras per airport (final approach, aircraft close-up, a high view, the
/// cockpit). The phone frames check that the packed phone tier still renders.
/// `SKYFORGE_FRAMES` (comma-separated airport idents) limits which airports render.
@Suite(.serialized) struct ShowcaseRenderTests {
    static let width = 1280, height = 720

    static func wanted(_ ident: String) -> Bool {
        guard let f = ProcessInfo.processInfo.environment["SKYFORGE_FRAMES"], !f.isEmpty else { return true }
        return f.split(separator: ",").contains { $0 == ident }
    }

    /// Aircraft pose for a review shot: position (region metres, z AMSL) and attitude.
    struct Pose {
        var position: SIMD3<Double>
        var heading: Double                  // rad, clockwise from north
        var pitch = 0.035, roll = 0.0
        /// Columns: body x (forward), y (right), z (down) in ENU.
        var bodyToENU: simd_double3x3 {
            let f = SIMD3(sin(heading) * cos(pitch), cos(heading) * cos(pitch), sin(pitch))
            let r0 = SIMD3(cos(heading), -sin(heading), 0)
            let d0 = simd_cross(f, r0)
            let r = r0 * cos(roll) + d0 * sin(roll)
            return simd_double3x3(columns: (f, r, simd_cross(f, r)))
        }
        var forwardH: SIMD3<Double> { SIMD3(sin(heading), cos(heading), 0) }
        /// Chase camera behind and above, looking ahead of the aircraft.
        func chase(distance: Double = 22, height: Double = 5) -> WorldCamera {
            WorldCamera(position: position - forwardH * distance + SIMD3(0, 0, height), target: position + forwardH * 30 + SIMD3(0, 0, 1))
        }
        /// Orbit camera at `azimuth` (rad, from the aircraft's tail, positive to its left) and `elevation`.
        func orbit(azimuth: Double, elevation: Double, distance: Double, fov: Double = 45) -> WorldCamera {
            let back = -forwardH, left = SIMD3(-cos(heading), sin(heading), 0)
            let dir = (back * cos(azimuth) + left * sin(azimuth)) * cos(elevation) + SIMD3(0, 0, sin(elevation))
            return WorldCamera(position: position + dir * distance, target: position + forwardH * 0.5, verticalFOVDeg: fov)
        }
    }

    static func save(_ name: String, _ img: [UInt8]) {
        _ = VisualRegression.check(name: name, rgb: img, width: width, height: height, goldenDir: goldenDir)
    }

    static func contrast(_ img: [UInt8]) -> Int {
        var lo = Int.max, hi = 0
        for y in (height * 2 / 3)..<height { for x in stride(from: 0, to: width, by: 4) {
            let i = 3 * (y * width + x); let s = Int(img[i]) + Int(img[i + 1]) + Int(img[i + 2]); lo = min(lo, s); hi = max(hi, s)
        } }
        return hi - lo
    }

    /// The packed phone tier (what a phone flies).
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"), arguments: ["KMRY", "LSZS"])
    func showcaseFrame(ident: String) async throws {
        guard Self.wanted(ident) else { return }
        let region = try await RealWorldRegion.load(airport: ident, detail: .phone,
                                                    transport: Showcase.transport(for: ident, fallback: nil), cache: nil)
        let data = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        try r.applyRealAirport(data, fieldElevation: region.runwayElevation)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        let c = session.bodyToENUColumns
        let img = try r.render(width: Self.width, height: Self.height, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        Self.save("metal_real_\(ident)_1280x720", img)
        #expect(Self.contrast(img) > 60, "\(ident) ground contrast")
    }

    /// CDLOD morph check, numeric so it needs no eyes. Ten low-resolution frames while the camera steps 60 m along
    /// the approach each frame, which carries the terrain nodes through their morph bands. A geomorph seam or a
    /// popping node shows as one frame-to-frame change far above the rest, so the largest per-pixel change is
    /// compared with the median change. The 4× bound is a first guess until CI logs the real values.
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func cdlodMorphSequenceHasNoPops() async throws {
        let ident = "KMRY"
        guard Self.wanted(ident) else { return }
        let region = try await RealWorldRegion.load(airport: ident, detail: .phone,
                                                    transport: Showcase.transport(for: ident, fallback: nil), cache: nil)
        let data = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        try r.applyRealAirport(data, fieldElevation: region.runwayElevation)
        r.clouds = .clear
        let w = 320, h = 180
        let track = SIMD3<Double>(sin(region.runwayHeading), cos(region.runwayHeading), 0)
        var frames: [[UInt8]] = []
        for k in 0..<10 {
            let shift = track * (60 * Double(k))
            frames.append(try r.render(width: w, height: h, camera: WorldCamera(position: cam.position + shift, target: cam.target + shift)))
            #expect(r.lastDrawnChunks > 0, "CDLOD drew no nodes at step \(k)")
        }
        var changes: [Int] = []
        for k in 1..<frames.count {
            var largest = 0
            for i in 0..<frames[k].count { largest = max(largest, abs(Int(frames[k][i]) - Int(frames[k - 1][i]))) }
            changes.append(largest)
        }
        let sorted = changes.sorted(), median = max(1, sorted[sorted.count / 2]), worst = sorted.last ?? 0
        print("SKYFORGE_MORPH \(ident) largest_per_pixel=\(changes) median=\(median) ratio=\(String(format: "%.2f", Double(worst) / Double(median)))")
        #expect(worst <= 4 * median, "largest per-pixel change \(worst) against median \(median): a pop")
    }

    /// The look review: every showcase airport at the ultra tier from several cameras.
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"),
          arguments: ["KMRY", "KASE", "KBFI", "LSZS", "NZQN"])
    func ultraFrames(ident: String) async throws {
        guard Self.wanted(ident) else { return }
        let region = try await RealWorldRegion.load(airport: ident, detail: .ultra,
                                                    transport: Showcase.transport(for: ident, fallback: nil), cache: nil)
        let data = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        r.apply(.ultra)
        try r.applyRealAirport(data, fieldElevation: region.runwayElevation)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        let w = Self.width, h = Self.height
        let c = session.bodyToENUColumns
        let body = simd_double3x3(columns: (c.0, c.1, c.2))

        // 1. Final approach, chase camera (the frame every earlier review used).
        let final = try r.render(width: w, height: h, camera: WorldCamera(position: cam.position, target: cam.target),
                                 aircraftPosition: session.positionENU, aircraftBodyToENU: body)
        Self.save("ultra_\(ident)_final", final)
        #expect(Self.contrast(final) > 60, "\(ident) ultra ground contrast")

        // 2. Aircraft close-up from the rear quarter on the same final.
        let hdg = region.runwayHeading
        let onFinal = Pose(position: session.positionENU, heading: hdg, pitch: 0.02, roll: -0.10)
        let close = try r.render(width: w, height: h, camera: onFinal.orbit(azimuth: 0.62, elevation: 0.16, distance: 11.5),
                                 aircraftPosition: onFinal.position, aircraftBodyToENU: onFinal.bodyToENU)
        Self.save("ultra_\(ident)_close", close)

        // 3. A higher view chosen per airport (city, coast, lake, mountains), chase camera.
        let dir = region.runwayDirection
        func ground(_ p: SIMD2<Double>) -> Double { region.height(p.x, p.y) }
        var high: Pose
        switch ident {
        case "KBFI":   // north of the field toward downtown Seattle, Elliott Bay to the left
            let p = SIMD2(-1_200.0, 5_200.0)
            high = Pose(position: SIMD3(p.x, p.y, ground(p) + 520), heading: atan2(-1_000, 3_200), roll: 0.05)
        case "KMRY":   // over the shore of Monterey Bay, along the coast
            let p = SIMD2(-3_000.0, 1_800.0)
            high = Pose(position: SIMD3(p.x, p.y, max(0, ground(p)) + 380), heading: 250 * .pi / 180, roll: -0.12)
        case "NZQN":   // low over the Frankton Arm of Lake Wakatipu
            let p = region.runwayThreshold - dir * 4_200
            high = Pose(position: SIMD3(p.x, p.y, ground(p) + 160), heading: hdg, roll: 0.06)
        default:       // mountain airports: mid-valley, well above the field
            let p = region.runwayThreshold - dir * 6_000
            high = Pose(position: SIMD3(p.x, p.y, max(ground(p) + 350, region.runwayElevation + 750)), heading: hdg, roll: 0.04)
        }
        r.setLighting(LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: high.position.z))
        let wide = try r.render(width: w, height: h, camera: high.chase(distance: 24, height: 6),
                                aircraftPosition: high.position, aircraftBodyToENU: high.bodyToENU)
        Self.save("ultra_\(ident)_high", wide)

        // Lake pass (NZQN): 40 m above the lake surface, 1.5 km out along the Frankton Arm, same chase camera.
        if ident == "NZQN" {
            let p = region.runwayThreshold - dir * 1_500
            let lakePose = Pose(position: SIMD3(p.x, p.y, ground(p) + 40), heading: hdg, roll: 0.0)
            // The wake needs an aircraft speed; the static pose carries a 60 m/s wake along the arm so the lake shows it.
            let lakeWake = OceanWake.aircraft(position: SIMD2(Float(p.x), Float(p.y)), heading: Float(atan2(dir.y, dir.x)),
                                              speed: 60, wingspan: 11)
            r.oceanWakes = lakeWake.map { [$0] } ?? []
            let lake = try r.render(width: w, height: h, camera: lakePose.chase(distance: 24, height: 6),
                                    aircraftPosition: lakePose.position, aircraftBodyToENU: lakePose.bodyToENU)
            Self.save("ultra_NZQN_lake", lake)
            // Water path proof (debugView 9): r = imagery-water branch, g = ocean shader, b = wakes reaching the shader.
            r.debugView = 9
            let proof = try r.render(width: w, height: h, camera: lakePose.chase(distance: 24, height: 6),
                                     aircraftPosition: lakePose.position, aircraftBodyToENU: lakePose.bodyToENU)
            r.debugView = 0
            Self.save("debug_NZQN_lake_water", proof)
            // Frame names carry the wake state (the frames log does not echo prints): built = 1/0, wakes at the renderer = n.
            Self.save("wakes_built\(lakeWake == nil ? 0 : 1)_renderer\(r.oceanWakes.count)_NZQN_lake", lake)
        }

        // Debug views (WorldRenderer.debugView) for the terms the reviews could not tell apart: the LSZS high
        // valley wall that stayed near black through four lighting changes, and the near-ground patches at
        // the US airports that never showed. Means over the region of interest are printed for the log.
        func debugFrames(_ name: String, camera: WorldCamera, aircraft: SIMD3<Double>, attitude: simd_double3x3, modes: [Int], roi: (Int, Int, Int, Int)) throws {
            let saved = (r.bloomIntensity, r.ssaoStrength, r.colourGrade, r.sharpen)
            r.bloomIntensity = 0; r.ssaoStrength = 0; r.colourGrade = 0; r.sharpen = 0
            defer { (r.bloomIntensity, r.ssaoStrength, r.colourGrade, r.sharpen) = saved; r.debugView = 0 }
            for mode in modes {
                r.debugView = mode
                let img = try r.render(width: w, height: h, camera: camera, aircraftPosition: aircraft, aircraftBodyToENU: attitude)
                Self.save("debug_\(name)_v\(mode)", img)
                var sum = SIMD3<Double>(repeating: 0), n = 0.0
                for y in stride(from: roi.1, to: roi.3, by: 2) { for x in stride(from: roi.0, to: roi.2, by: 2) {
                    let i = 3 * (y * w + x)
                    sum += SIMD3(Double(img[i]), Double(img[i + 1]), Double(img[i + 2])) / 255; n += 1
                } }
                let m = sum / max(n, 1)
                print(String(format: "debug %@ view %d roi mean r %.3f g %.3f b %.3f", name, mode, m.x, m.y, m.z))
            }
        }
        if ident == "LSZS" {
            try debugFrames("LSZS_high", camera: high.chase(distance: 24, height: 6), aircraft: high.position, attitude: high.bodyToENU, modes: [1, 2, 4], roi: (700, 430, 1280, 720))
        }
        if ident == "KASE" {
            // Round-44 review: the high frame's right-side streaks run along the contours. View 2 (shading terms)
            // tells height terracing apart; view 5 (imagery metres per texel against pixel footprint) a coarse layer.
            try debugFrames("KASE_high", camera: high.chase(distance: 24, height: 6), aircraft: high.position, attitude: high.bodyToENU, modes: [1, 2, 5], roi: (800, 480, 1120, 640))
        }
        if ident == "NZQN" {
            // Round-58 review: the shaded left slope renders purple-blue. View 1 (albedo) against view 2 (shading terms)
            // says whether the cast is in the photo or in the sky light.
            try debugFrames("NZQN_high", camera: high.chase(distance: 24, height: 6), aircraft: high.position, attitude: high.bodyToENU, modes: [1, 2, 4], roi: (0, 260, 400, 720))
        }
        if ident == "KMRY" || ident == "KBFI" {
            r.setLighting(LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
            try debugFrames("\(ident)_final", camera: WorldCamera(position: cam.position, target: cam.target),
                            aircraft: session.positionENU, attitude: body,
                            modes: [1, 2, 3, 4], roi: (0, 540, 1280, 720))   // 2/4: sun visibility and direct/ambient split (round-60 review: are the blotches tree shadows?)
        }

        // 4. Cockpit on the final (one airport is enough to review the interior).
        if ident == "KMRY" {
            r.setLighting(LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
            try r.setCockpit(Cockpit.mesh(), screen: Cockpit.pfdCorners.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) })
            let pw = 1_024, ph = 640
            r.updateCockpitScreen(rgb: Raster2D.render(PFD.draw(session.data, width: Double(pw), height: Double(ph)), width: pw, height: ph).bytes(),
                                  width: pw, height: ph)
            r.cockpitView = true
            let ck = session.cockpitCamera()
            let inside = try r.render(width: w, height: h,
                                      camera: WorldCamera(position: ck.position, target: ck.target, verticalFOVDeg: 62, up: ck.up, near: 0.05),
                                      aircraftPosition: session.positionENU, aircraftBodyToENU: body)
            r.cockpitView = false
            Self.save("ultra_\(ident)_cockpit", inside)
        }
        print("ultra \(ident): \(region.buildings.count) buildings, \(data.buildingMesh?.triangleCount ?? 0) building triangles, \(data.trees.count) trees, building cells drawn \(r.lastDrawnBuildingCells)/\(r.buildingCellCount)")
    }

    /// The same final-approach frame at every graphics preset, each with the world detail the app pairs with it
    /// (low: phone, medium: tablet, high: desktop; ultra: the review tier), so the presets can be compared side by side.
    static let presets: [(name: String, settings: WorldRenderer.Settings, real: RealWorldDetail, sky: QuickFlightDetail)] = [
        ("low", .low, .phone, .phone), ("medium", .medium, .tablet, .tablet),
        ("high", .high, .desktop, .desktop), ("ultra", .ultra, .ultra, .desktop),
    ]

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"), arguments: [0, 1, 2, 3])
    func presetFrameKMRY(preset: Int) async throws {
        guard Self.wanted("KMRY") else { return }
        let p = Self.presets[preset]
        let region = try await RealWorldRegion.load(airport: "KMRY", detail: p.real,
                                                    transport: Showcase.transport(for: "KMRY", fallback: nil), cache: nil)
        let data = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        r.apply(p.settings)
        try r.applyRealAirport(data, fieldElevation: region.runwayElevation)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        let c = session.bodyToENUColumns
        let img = try r.render(width: Self.width, height: Self.height, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        Self.save("preset_KMRY_\(preset)_\(p.name)", img)
        #expect(Self.contrast(img) > 60, "KMRY \(p.name) ground contrast")
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"), arguments: [0, 1, 2, 3])
    func presetFrameSkyWorld(preset: Int) throws {
        guard Self.wanted("SKYWORLD") else { return }
        let p = Self.presets[preset]
        let world = QuickFlightWorld()
        let session = QuickFlightSession(world: world, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        r.apply(p.settings)
        let env = world.buildEnvironmentInstanced(detail: p.sky)
        try r.setEnvironment(env.soup)
        try r.setTrees(RealWorldRenderData.trees(env.trees))
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        r.clouds = .fairWeather
        let c = session.bodyToENUColumns
        let img = try r.render(width: Self.width, height: Self.height, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        Self.save("preset_skyworld_\(preset)_\(p.name)", img)
        #expect(r.lastDrawnEnvironmentCells > 0)
    }

    /// SkyWorld (the offline fallback) at phone detail and at the ultra render settings.
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"), arguments: [false, true])
    func skyWorldFrame(ultra: Bool) throws {
        guard Self.wanted("SKYWORLD") else { return }
        let world = QuickFlightWorld()
        let session = QuickFlightSession(world: world, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        if ultra { r.apply(.ultra) }
        let env = world.buildEnvironmentInstanced(detail: ultra ? .desktop : .phone)
        try r.setEnvironment(env.soup)
        try r.setTrees(RealWorldRenderData.trees(env.trees))
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        r.clouds = .fairWeather
        let c = session.bodyToENUColumns
        let img = try r.render(width: Self.width, height: Self.height, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        Self.save(ultra ? "ultra_skyworld_final" : "metal_skyworld_1280x720", img)
        #expect(r.lastDrawnEnvironmentCells > 0)
    }

    /// Night frame: traffic nav, strobe and beacon lights around the aircraft. The lights must add visible
    /// light, so the frame with them differs from the same frame without them (the night-light pass is drawn).
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func nightTrafficLightsFrame() throws {
        guard Self.wanted("SKYWORLD") else { return }
        let world = QuickFlightWorld()
        let session = QuickFlightSession(world: world, start: .final)
        let cam = session.chaseCamera()
        // The real .night preset (sun below the horizon), so the night-light pass fades in as it would in the app.
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.night, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        let env = world.buildEnvironmentInstanced(detail: .phone)
        try r.setEnvironment(env.soup)
        try r.setTrees(RealWorldRenderData.trees(env.trees))
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        r.clouds = .clear
        let c = session.bodyToENUColumns
        let body = simd_double3x3(columns: (c.0, c.1, c.2))
        let camera = WorldCamera(position: cam.position, target: cam.target)
        // Lights on the view axis, so they land in the frame whatever the chase heading is.
        let fwd = simd_normalize(cam.target - cam.position)
        func onAxis(_ distance: Double, lift: Double) -> SIMD3<Float> {
            let q = cam.position + fwd * distance + SIMD3<Double>(0, 0, lift)
            return SIMD3<Float>(Float(q.x), Float(q.y), Float(q.z))
        }
        // Count pixels where any channel changed between the two renders. The lights are a few pixels each, so a
        // brightness threshold would hide them; any change at all shows the pass drew.
        func changedPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
            var n = 0
            for i in stride(from: 0, to: min(a.count, b.count) - 2, by: 3) where a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
                n += 1
            }
            return n
        }
        r.trafficLights = []
        let dark = try r.render(width: Self.width, height: Self.height, camera: camera,
                                aircraftPosition: session.positionENU, aircraftBodyToENU: body)
        r.trafficLights = [
            NightLight(position: onAxis(300, lift: 0), kind: .navRed),
            NightLight(position: onAxis(340, lift: 12), kind: .navGreen),
            NightLight(position: onAxis(420, lift: 30), kind: .strobe),
            NightLight(position: onAxis(900, lift: 200), kind: .beacon),
        ]
        let lit = try r.render(width: Self.width, height: Self.height, camera: camera,
                               aircraftPosition: session.positionENU, aircraftBodyToENU: body)
        Self.save("night_traffic_lights_1280x720", lit)
        #expect(changedPixels(lit, dark) > 0, "night-light sprites change the frame")
    }

    /// Night sky frame: stars and the moon above the sunless horizon (the night lighting preset, fixed clock).
    /// The upper half of the frame must hold light, which the night sky pass adds.
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func nightSkyFrame() throws {
        guard Self.wanted("SKYWORLD") else { return }
        let world = QuickFlightWorld()
        let session = QuickFlightSession(world: world, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.night, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        r.skyUnixTime = 1_795_000_000   // fixed clock so the star field is reproducible
        let env = world.buildEnvironmentInstanced(detail: .phone)
        try r.setEnvironment(env.soup)
        try r.setTrees(RealWorldRenderData.trees(env.trees))
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        r.clouds = .clear
        let c = session.bodyToENUColumns
        let img = try r.render(width: Self.width, height: Self.height, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        Self.save("night_sky_1280x720", img)
        var upperLight = 0
        for y in 0..<(Self.height / 2) {
            for x in 0..<Self.width {
                let i = 3 * (y * Self.width + x)
                if Int(img[i]) + Int(img[i + 1]) + Int(img[i + 2]) > 60 { upperLight += 1 }
            }
        }
        #expect(upperLight > 30, "stars and moon light the night sky: \(upperLight)")
    }
}
#endif
