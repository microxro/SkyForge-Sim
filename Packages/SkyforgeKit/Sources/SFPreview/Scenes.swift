// SKYFORGE — Apache-2.0
// Canonical preview scenes (§8.5). Each scene is fixed camera + time + seed, so renders are reproducible.
import Foundation
import SFMath
import SFWorldGen

public enum PreviewScene: String, Sendable, CaseIterable {
    case suburban, forestRiver = "forest_river", coastline, mountainValley = "mountain_valley", airportFinal = "airport_final"

    public var defaultTime: TimePreset {
        switch self {
        case .suburban: return .goldenHour
        case .forestRiver: return .midday
        case .coastline: return .goldenHour
        case .mountainValley: return .midday
        case .airportFinal: return .sunrise
        }
    }

    var terrainKind: TerrainKind {
        switch self {
        case .suburban: return .suburbanPlain
        case .forestRiver: return .forestRiver
        case .coastline: return .coastline
        case .mountainValley: return .mountainValley
        case .airportFinal: return .suburbanPlain
        }
    }
}

public struct SceneSetup {
    public var camera: PreviewCamera
    public var generator: WorldGenerator
    public var nearHalfExtent: Double
    public var nearStep: Double
    public var farHalfExtent: Double
    public var farStep: Double
    public var objectRadius: Double
    public var treeDetailRadius: Double
    public var sunAzimuth: Double
    /// Chase-camera aircraft placement relative to the camera (metres / radians).
    public var aircraft: (ahead: Double, below: Double, right: Double, headingOffset: Double, pitch: Double, roll: Double)? = nil
    public var runway: RunwaySpec? = nil
    public var runwayElevation = 0.0
}

public enum PreviewScenes {
    public static func setup(_ scene: PreviewScene, seed: UInt64) -> SceneSetup {
        var recipe = TerrainRecipe(kind: scene.terrainKind, seed: seed)
        // Scene (j): a 1,500 x 30 m runway east of the suburbs on flattened ground.
        let rwyHeading = 20 * Double.pi / 180
        let rwyThreshold = SIMD2(3_300.0, -3_000.0)
        let rwyDir = SIMD2(sin(rwyHeading), cos(rwyHeading))
        let rwyElevation = recipe.height(rwyThreshold.x + rwyDir.x * 750, rwyThreshold.y + rwyDir.y * 750)
        if scene == .airportFinal {
            recipe.flattenZones = [(centre: rwyThreshold + rwyDir * 750, halfLength: 850, halfWidth: 90, heading: rwyHeading, elevation: rwyElevation)]
        }
        let gen = WorldGenerator(terrain: recipe, latitude: 47, season: .autumn)
        func cam(_ x: Double, _ y: Double, agl: Double, lookX: Double, lookY: Double, lookAGL: Double, fov: Double = 70) -> PreviewCamera {
            let z = recipe.height(x, y) + agl
            let tz = recipe.height(lookX, lookY) + lookAGL
            return PreviewCamera(position: SIMD3(x, y, z), lookAt: SIMD3(lookX, lookY, tz), horizontalFOV: fov * .pi / 180)
        }
        switch scene {
        case .suburban:
            var su = SceneSetup(camera: cam(700, 500, agl: 150, lookX: -500, lookY: -350, lookAGL: 0, fov: 62),
                                generator: gen, nearHalfExtent: 2_400, nearStep: 6, farHalfExtent: 16_000, farStep: 80,
                                objectRadius: 2_600, treeDetailRadius: 700, sunAzimuth: 268)
            su.aircraft = (ahead: 26, below: 7, right: 3, headingOffset: -0.12, pitch: 0.02, roll: -0.22)
            return su
        case .forestRiver:
            return SceneSetup(camera: cam(-260, -1_900, agl: 170, lookX: -150, lookY: -300, lookAGL: 0),
                              generator: gen, nearHalfExtent: 2_400, nearStep: 6, farHalfExtent: 16_000, farStep: 80,
                              objectRadius: 2_200, treeDetailRadius: 650, sunAzimuth: 200)
        case .coastline:
            return SceneSetup(camera: cam(900, -2_300, agl: 160, lookX: 150, lookY: 600, lookAGL: 0),
                              generator: gen, nearHalfExtent: 2_400, nearStep: 6, farHalfExtent: 16_000, farStep: 80,
                              objectRadius: 2_400, treeDetailRadius: 700, sunAzimuth: 255)
        case .mountainValley:
            return SceneSetup(camera: cam(-150, -3_200, agl: 260, lookX: -150, lookY: 1_800, lookAGL: 300, fov: 72),
                              generator: gen, nearHalfExtent: 3_000, nearStep: 8, farHalfExtent: 22_000, farStep: 90,
                              objectRadius: 2_600, treeDetailRadius: 600, sunAzimuth: 160)
        case .airportFinal:
            // On a 3° final, 1.5 km from the threshold, camera behind and above the aircraft.
            let camGround = rwyThreshold - rwyDir * 720
            let target = rwyThreshold + rwyDir * 380
            let camPos = SIMD3(camGround.x, camGround.y, rwyElevation + 720 * tan(3 * Double.pi / 180) + 9)
            var sf = SceneSetup(camera: PreviewCamera(position: camPos, lookAt: SIMD3(target.x, target.y, rwyElevation), horizontalFOV: 58 * .pi / 180),
                                generator: gen, nearHalfExtent: 2_400, nearStep: 6, farHalfExtent: 16_000, farStep: 80,
                                objectRadius: 2_600, treeDetailRadius: 700, sunAzimuth: 255)
            sf.aircraft = (ahead: 24, below: 5.5, right: 0, headingOffset: 0, pitch: -0.01, roll: 0.03)
            sf.runway = RunwaySpec(threshold: rwyThreshold, heading: rwyHeading, length: 1_500, width: 30,
                                   lowDesignator: RunwaySpec.designator(headingDegrees: 20), highDesignator: RunwaySpec.designator(headingDegrees: 200))
            sf.runwayElevation = rwyElevation
            return sf
        }
    }

    /// Builds and renders a scene. Returns the image and timing stats.
    public static func render(_ scene: PreviewScene, time: TimePreset? = nil, seed: UInt64 = 1,
                              width: Int = 1280, height: Int = 720, supersample: Int = 2) -> (PreviewImage, RenderStats, [String: Int]) {
        var stats = RenderStats()
        let t0 = Date()
        let s = setup(scene, seed: seed)
        let cam = s.camera
        let fwd2 = normalize(SIMD3(cam.forward.x, cam.forward.y, 0))
        let focus = SIMD2(cam.position.x + fwd2.x * s.nearHalfExtent * 0.55, cam.position.y + fwd2.y * s.nearHalfExtent * 0.55)
        let origin = SIMD3(cam.position.x, cam.position.y, 0)
        var b = SceneBuilder(generator: s.generator, origin: origin)
        b.addTerrain(centre: focus, halfExtent: s.nearHalfExtent, step: s.nearStep)
        // Mid ring (24 m) out to 8 km, then the far ring; each skips the area the finer ring covers.
        let midHalf = max(s.nearHalfExtent * 2.5, 8_000.0), midStep = 24.0
        b.addTerrain(centre: focus, halfExtent: midHalf, step: midStep,
                     skipInside: s.nearHalfExtent - midStep, lower: 0.5, far: true)
        b.addTerrain(centre: focus, halfExtent: s.farHalfExtent, step: s.farStep,
                     skipInside: midHalf - s.farStep, lower: 1.5, far: true)
        b.addWater(centre: focus, halfExtent: s.nearHalfExtent * 1.6, step: 8)
        // Objects: chunks around the focus within the object radius, in front of the camera.
        let r = s.objectRadius
        let c0x = Int(((focus.x - r) / WorldGenerator.chunkSize).rounded(.down)), c1x = Int(((focus.x + r) / WorldGenerator.chunkSize).rounded(.down))
        let c0y = Int(((focus.y - r) / WorldGenerator.chunkSize).rounded(.down)), c1y = Int(((focus.y + r) / WorldGenerator.chunkSize).rounded(.down))
        let camXY = SIMD2(cam.position.x, cam.position.y)
        for cy in c0y...c1y {
            for cx in c0x...c1x {
                let chunk = s.generator.generateChunk(cx: cx, cy: cy)
                b.addRoads(chunk.roads, near: focus, radius: r * 1.4)
                for bl in chunk.buildings {
                    let d = bl.center - camXY
                    if (d * fwd2.xy).sum() < -50 { continue }
                    b.addBuilding(bl)
                }
                for lot in chunk.parkingLots { b.addParkingLot(lot) }
                for t in chunk.trees {
                    let d = SIMD2(t.position.x, t.position.y) - camXY
                    let along = (d * fwd2.xy).sum()
                    if along < -30 { continue }
                    let dist = (d * d).sum().squareRoot()
                    if dist > r { continue }
                    b.addTree(t, detail: dist < s.treeDetailRadius * 1.8 ? 2 : 1)
                }
            }
        }
        if let rwy = s.runway { b.addRunway(rwy, elevation: s.runwayElevation) }
        if let rig = s.aircraft {
            let fwdH = normalize(SIMD3(cam.forward.x, cam.forward.y, 0))
            let pos = cam.position + fwdH * rig.ahead - SIMD3(0, 0, rig.below) + SIMD3(fwdH.y, -fwdH.x, 0) * rig.right
            b.addAircraft(at: pos, heading: atan2(fwdH.x, fwdH.y) + rig.headingOffset, pitch: rig.pitch, roll: rig.roll, accent: srgb(28, 62, 118))
        }
        stats.buildSeconds = Date().timeIntervalSince(t0)
        let lighting = LightingSetup.physicalPreset(time ?? scene.defaultTime, azimuthDegrees: s.sunAzimuth,
                                                    cameraHeightMetres: cam.position.z)
        let shadowCentre = SIMD3(focus.x - fwd2.x * s.nearHalfExtent * 0.25, focus.y - fwd2.y * s.nearHalfExtent * 0.25, cam.position.z - 150)
        let img = PreviewRenderer.render(soup: b.soup, camera: cam, lighting: lighting, width: width, height: height,
                                         supersample: supersample, shadowCentre: shadowCentre,
                                         shadowHalfExtent: 1_500, stats: &stats)
        return (img, stats, b.stats)
    }
}

extension SIMD3 where Scalar == Double {
    var xy: SIMD2<Double> { SIMD2(x, y) }
}
