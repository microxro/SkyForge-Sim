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
        try r.setRealWorld(data)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        r.clouds = .fairWeather(fieldElevation: Float(region.runwayElevation))
        let c = session.bodyToENUColumns
        let img = try r.render(width: Self.width, height: Self.height, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        Self.save("metal_real_\(ident)_1280x720", img)
        #expect(Self.contrast(img) > 60, "\(ident) ground contrast")
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
        try r.setRealWorld(data)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        r.clouds = .fairWeather(fieldElevation: Float(region.runwayElevation))
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
}
#endif
