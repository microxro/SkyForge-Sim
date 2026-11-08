// SKYFORGE — Apache-2.0
// Quick Flight vertical slice: the SkyWorld airport region (preview scene j's world), the SF-1
// Trainer flight model, instruments and input mapping, independent of any GPU. The Metal world
// renderer and the SwiftUI screen drive this; tests fly it headless on Linux.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel
import SFInstruments
import SFInput
import SFWorldGen
import SFPreview

/// Terrain heights from the procedural recipe for the flight model (NED north/east ↔ world y/x).
public struct RecipeTerrain: TerrainHeightProvider {
    public let recipe: TerrainRecipe
    public init(_ r: TerrainRecipe) { recipe = r }
    public func elevation(north: Double, east: Double) -> Double { recipe.height(east, north) }
}

/// Anything Quick Flight can fly over: terrain heights and a runway to start from.
public protocol FlightWorld: Sendable {
    var runwayThreshold: SIMD2<Double> { get }      // low-numbered threshold, world x east / y north (m)
    var runwayHeading: Double { get }               // true heading from that threshold (rad)
    var runwayLengthMetres: Double { get }
    var runwayElevation: Double { get }             // m AMSL
    func height(_ x: Double, _ y: Double) -> Double
}

extension FlightWorld {
    public var runwayDirection: SIMD2<Double> { SIMD2(sin(runwayHeading), cos(runwayHeading)) }
}

/// Flight-model terrain backed by any FlightWorld.
public struct FlightWorldTerrain: TerrainHeightProvider {
    public let world: any FlightWorld
    public init(_ w: any FlightWorld) { world = w }
    public func elevation(north: Double, east: Double) -> Double { world.height(east, north) }
}

public enum QuickFlightStart: String, Sendable, CaseIterable {
    case runway, final
}

/// Scene density for a device class (triangles scale roughly with 1/step²).
public struct QuickFlightDetail: Sendable, Equatable {
    public var nearHalfExtent: Double, nearStep: Double
    public var midHalfExtent: Double, midStep: Double
    public var farHalfExtent: Double, farStep: Double
    public var objectRadius: Double
    public var treeDetailRadius: Double
    public static let phone = QuickFlightDetail(nearHalfExtent: 2_000, nearStep: 12, midHalfExtent: 7_000, midStep: 48,
                                                farHalfExtent: 20_000, farStep: 200, objectRadius: 1_600, treeDetailRadius: 300)
    public static let tablet = QuickFlightDetail(nearHalfExtent: 2_500, nearStep: 9, midHalfExtent: 8_000, midStep: 36,
                                                 farHalfExtent: 24_000, farStep: 160, objectRadius: 2_200, treeDetailRadius: 450)
    public static let desktop = QuickFlightDetail(nearHalfExtent: 3_000, nearStep: 8, midHalfExtent: 9_000, midStep: 32,
                                                  farHalfExtent: 28_000, farStep: 140, objectRadius: 2_400, treeDetailRadius: 550)
}

public struct QuickFlightWorld: FlightWorld {
    public let generator: WorldGenerator
    public let runway: RunwaySpec
    public let runwayElevation: Double
    public var recipe: TerrainRecipe { generator.terrain }

    public init(seed: UInt64 = 1) {
        let s = PreviewScenes.setup(.airportFinal, seed: seed)
        generator = s.generator
        runway = s.runway!
        runwayElevation = s.runwayElevation
    }

    public var runwayThreshold: SIMD2<Double> { runway.threshold }
    public var runwayHeading: Double { runway.heading }
    public var runwayLengthMetres: Double { runway.length }
    public func height(_ x: Double, _ y: Double) -> Double { recipe.height(x, y) }
    public var runwayCentre: SIMD2<Double> { runway.threshold + runwayDirection * runway.length / 2 }

    /// Static environment mesh around the airfield (no view culling: the camera moves).
    public func buildEnvironment(detail d: QuickFlightDetail, origin: SIMD3<Double>? = nil) -> TriangleSoup {
        let focus = runwayCentre
        var b = SceneBuilder(generator: generator, origin: origin ?? SIMD3(focus.x, focus.y, 0))
        b.airfield = runway
        b.addTerrain(centre: focus, halfExtent: d.nearHalfExtent, step: d.nearStep)
        b.addTerrain(centre: focus, halfExtent: d.midHalfExtent, step: d.midStep, skipInside: d.nearHalfExtent - d.midStep, lower: 0.5, far: true)
        b.addTerrain(centre: focus, halfExtent: d.farHalfExtent, step: d.farStep, skipInside: d.midHalfExtent - d.farStep, lower: 1.5, far: true)
        b.addWater(centre: focus, halfExtent: d.nearHalfExtent * 1.4, step: 10)
        let r = d.objectRadius
        let cs = WorldGenerator.chunkSize
        for cy in Int(((focus.y - r) / cs).rounded(.down))...Int(((focus.y + r) / cs).rounded(.down)) {
            for cx in Int(((focus.x - r) / cs).rounded(.down))...Int(((focus.x + r) / cs).rounded(.down)) {
                let chunk = generator.generateChunk(cx: cx, cy: cy)
                b.addRoads(chunk.roads, near: focus, radius: r * 1.3)
                for bl in chunk.buildings {
                    let dx = bl.center.x - focus.x, dy = bl.center.y - focus.y
                    if dx * dx + dy * dy < r * r { b.addBuilding(bl) }
                }
                for lot in chunk.parkingLots { b.addParkingLot(lot) }
                for t in chunk.trees {
                    let dx = t.position.x - focus.x, dy = t.position.y - focus.y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    if dist > r { continue }
                    b.addTree(t, detail: dist < d.treeDetailRadius ? 2 : 1)
                }
            }
        }
        b.addRunway(runway, elevation: runwayElevation)
        return b.soup
    }

    /// Aircraft mesh in body axes (x forward, y right, z down), with colours and materials.
    public static func aircraftMesh(accent: SIMD3<Float> = SIMD3(0.011, 0.048, 0.18)) -> TriangleSoup {
        var b = SceneBuilder(generator: WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 1)), origin: .zero)
        b.addAircraft(at: .zero, heading: 0, pitch: 0, roll: 0, accent: accent)
        // addAircraft maps NED→ENU; undo it so the mesh stays in body axes (x fwd, y right, z down).
        var soup = TriangleSoup(origin: .zero)
        let s = b.soup
        for t in 0..<s.triangleCount {
            func body(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(p.y), Double(p.x), Double(-p.z)) }
            // SceneBuilder reversed the winding for its ENU output; keep that order so normals face outward
            // (the cockpit view discards back faces by normal; test `cabinNormalsPointOutward`).
            soup.addFlat(body(s.positions[3 * t]), body(s.positions[3 * t + 1]), body(s.positions[3 * t + 2]),
                         colour: s.albedo[t], material: s.material[t])
        }
        return soup
    }
}

public struct QuickFlightSession: Sendable {
    public let world: any FlightWorld
    public let model = FlightModel(config: .sf1Trainer)
    public let environment: FlightEnvironment
    public private(set) var state: AircraftState
    public private(set) var inputs = ControlInputs()
    public private(set) var instruments = InstrumentSystem()
    public var mapper = InputMapper(profiles: [.defaults, .touchDefaults])
    public private(set) var crashed = false
    public private(set) var time = 0.0
    private var accumulator = 0.0
    private var lastFlapAction = false
    public static let dt = 1.0 / 120

    public init(world: any FlightWorld = QuickFlightWorld(), start: QuickFlightStart = .runway) {
        self.world = world
        environment = FlightEnvironment(terrain: FlightWorldTerrain(world))
        let dir = world.runwayDirection
        let hdg = world.runwayHeading
        switch start {
        case .runway:
            let p = world.runwayThreshold + dir * 60
            state = AircraftState(positionNED: SIMD3(p.y, p.x, -(world.runwayElevation + 1.22)), velocityBody: .zero,
                                  attitude: Quaternion(roll: 0, pitch: 0, yaw: hdg), bodyRates: .zero)
            inputs.brakes = 0
        case .final:
            let dist = 2_000.0
            let p = world.runwayThreshold - dir * dist
            let alt = world.runwayElevation + 15 + dist * tan(3 * Double.pi / 180)
            let trim = model.trimLevel(trueAirspeed: 34, altitude: alt, flaps: 0.5, environment: environment)
            var s = trim.state
            s.positionNED = SIMD3(p.y, p.x, -alt)
            s.attitude = Quaternion(roll: 0, pitch: trim.alpha, yaw: hdg)
            state = s
            inputs = trim.inputs
        }
    }

    public var data: InstrumentData { instruments.data }
    /// Aircraft position in world coordinates (x east, y north, z up).
    public var positionENU: SIMD3<Double> { SIMD3(state.positionNED.y, state.positionNED.x, -state.positionNED.z) }
    /// Columns of the body (x fwd, y right, z down) → world ENU rotation.
    public var bodyToENUColumns: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        func enu(_ b: SIMD3<Double>) -> SIMD3<Double> { let n = state.attitude.rotate(b); return SIMD3(n.y, n.x, -n.z) }
        return (enu(SIMD3(1, 0, 0)), enu(SIMD3(0, 1, 0)), enu(SIMD3(0, 0, 1)))
    }
    public var heightAboveGround: Double {
        state.altitude - environment.terrain.elevation(north: state.positionNED.x, east: state.positionNED.y)
    }

    /// Advances real time `dt` with the given device state (fixed 120 Hz steps, at most 8 per call).
    public mutating func update(realDt: Double, device: InputMapper.DeviceState) {
        guard !crashed else { return }
        let out = mapper.evaluate(device, dt: realDt)
        inputs.elevator = out.axes[.pitch] ?? 0
        inputs.aileron = out.axes[.roll] ?? 0
        inputs.rudder = out.axes[.yaw] ?? 0
        if let t = out.axes[.throttle] { inputs.throttle = max(0, min(1, t)) }
        inputs.brakes = max(0, out.axes[.brakes] ?? 0)
        let flapEvent = out.actions.contains(.flapsDown) || out.actions.contains(.flapsUp)
        if flapEvent && !lastFlapAction {
            inputs.flaps = max(0, min(1, inputs.flaps + (out.actions.contains(.flapsDown) ? 0.5 : -0.5)))
        }
        lastFlapAction = flapEvent
        accumulator = min(accumulator + realDt, 8 * Self.dt)
        while accumulator >= Self.dt {
            step()
            accumulator -= Self.dt
        }
    }

    /// One fixed simulation step with the current inputs.
    public mutating func step() {
        let o = model.outputs(state, inputs: inputs, environment: environment)
        let rho = ISA.state(geometricAltitude: state.altitude).density
        instruments.update(state: state, outputs: o, environment: environment, inputs: inputs,
                           rpm: PropellerRPM.rpm(throttle: inputs.throttle, trueAirspeed: o.trueAirspeed, density: rho), dt: Self.dt)
        let vBefore = state.velocityNED.z
        state = model.step(state, inputs: inputs, environment: environment, dt: Self.dt)
        time += Self.dt
        // Crash: hard ground contact (> 600 fpm at contact) or the airframe below the surface.
        if heightAboveGround < 0.3 && vBefore > 3.0 { crashed = true }
        if heightAboveGround < -0.5 { crashed = true }
    }

    /// Sets inputs directly (autopilots, tests).
    public mutating func setInputs(_ i: ControlInputs) { inputs = i.sanitized }

    /// Chase camera: behind and above the aircraft along its track, looking slightly ahead.
    public func chaseCamera(distance: Double = 22, height: Double = 5) -> (position: SIMD3<Double>, target: SIMD3<Double>) {
        let e = state.attitude.euler
        let fwd = SIMD3(sin(e.yaw), cos(e.yaw), 0)
        let p = positionENU
        var cam = p - fwd * distance + SIMD3(0, 0, height)
        let ground = world.height(cam.x, cam.y) + 2
        cam.z = max(cam.z, ground)
        return (cam, p + fwd * 30 + SIMD3(0, 0, 1))
    }
}
