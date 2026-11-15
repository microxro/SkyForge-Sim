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
    /// Cap on instanced trees; farther trees are thinned first (`buildEnvironmentInstanced`).
    public var maxTrees: Int = 1_000_000
    public static let phone = QuickFlightDetail(nearHalfExtent: 2_000, nearStep: 12, midHalfExtent: 7_000, midStep: 48,
                                                farHalfExtent: 20_000, farStep: 200, objectRadius: 1_600, treeDetailRadius: 300)
    public static let tablet = QuickFlightDetail(nearHalfExtent: 2_500, nearStep: 9, midHalfExtent: 8_000, midStep: 36,
                                                 farHalfExtent: 24_000, farStep: 160, objectRadius: 2_200, treeDetailRadius: 450)
    public static let desktop = QuickFlightDetail(nearHalfExtent: 3_000, nearStep: 8, midHalfExtent: 9_000, midStep: 32,
                                                  farHalfExtent: 28_000, farStep: 140, objectRadius: 2_400, treeDetailRadius: 550,
                                                  maxTrees: 58_000)   // 105k uncapped kept SkyWorld high at its budget; 65k left ~0 margin against CI variance (run 42724229611: 16.95 ms)
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

    /// Static environment mesh around the airfield (no view culling: the camera moves), trees baked in.
    public func buildEnvironment(detail d: QuickFlightDetail, origin: SIMD3<Double>? = nil) -> TriangleSoup {
        build(detail: d, origin: origin, collectTrees: false).soup
    }

    /// The environment without trees, plus the trees as a list for GPU instancing (the Metal renderer
    /// draws and culls them per 400 m cell; baked into the mesh they doubled SkyWorld's shadow cost).
    public func buildEnvironmentInstanced(detail d: QuickFlightDetail) -> (soup: TriangleSoup, trees: [Tree]) {
        build(detail: d, origin: nil, collectTrees: true)
    }

    func build(detail d: QuickFlightDetail, origin: SIMD3<Double>?, collectTrees: Bool) -> (soup: TriangleSoup, trees: [Tree]) {
        var collected: [Tree] = []
        let focus = runwayCentre
        var b = SceneBuilder(generator: generator, origin: origin ?? SIMD3(focus.x, focus.y, 0))
        b.airfield = runway
        b.townImpostor = (focus, d.objectRadius)
        b.addTerrain(centre: focus, halfExtent: d.nearHalfExtent, step: d.nearStep)
        b.addTerrain(centre: focus, halfExtent: d.midHalfExtent, step: d.midStep, skipInside: d.nearHalfExtent - d.midStep, lower: 0.5, far: true)
        b.addTerrain(centre: focus, halfExtent: d.farHalfExtent, step: d.farStep, skipInside: d.midHalfExtent - d.farStep, lower: 1.5, far: true)
        b.addWater(centre: focus, halfExtent: d.nearHalfExtent * 1.4, step: 10)
        let r = d.objectRadius
        let cs = WorldGenerator.chunkSize
        // Objects around the airfield and around the final approach (the 3 nm final start is ~4 km from
        // the runway centre, beyond the object radius, so its whole foreground used to be bare fields).
        let foci = [focus, runway.threshold - runwayDirection * 2_600]
        func nearest(_ p: SIMD2<Double>) -> (dist: Double, focus: SIMD2<Double>) {
            foci.map { f -> (Double, SIMD2<Double>) in let d = p - f; return ((d * d).sum().squareRoot(), f) }.min { $0.0 < $1.0 }!
        }
        let lo = SIMD2(foci.map(\.x).min()! - r, foci.map(\.y).min()! - r), hi = SIMD2(foci.map(\.x).max()! + r, foci.map(\.y).max()! + r)
        var roads: [Road] = [], chunkTrees: [(tree: Tree, dist: Double)] = []
        for cy in Int((lo.y / cs).rounded(.down))...Int((hi.y / cs).rounded(.down)) {
            for cx in Int((lo.x / cs).rounded(.down))...Int((hi.x / cs).rounded(.down)) {
                let centre = SIMD2((Double(cx) + 0.5) * cs, (Double(cy) + 0.5) * cs)
                if nearest(centre).dist > r + cs { continue }
                let chunk = generator.generateChunk(cx: cx, cy: cy)
                b.addRoads(chunk.roads, near: nearest(centre).focus, radius: r * 1.3)
                roads += chunk.roads
                for bl in chunk.buildings where nearest(bl.center).dist < r { b.addBuilding(bl) }
                for lot in chunk.parkingLots { b.addParkingLot(lot) }
                for t in chunk.trees {
                    let dist = nearest(SIMD2(t.position.x, t.position.y)).dist
                    if !SceneBuilder.keepTree(t.position, dist: dist, radius: r) { continue }
                    chunkTrees.append((t, dist))
                }
            }
        }
        let farms = parcelFarmsteads(b.soup.fieldPattern, foci: foci, radius: r, roads: roads)
        for bl in farms { b.addBuilding(bl) }
        for (t, dist) in chunkTrees where !Self.inside(SIMD2(t.position.x, t.position.y), farms, margin: 4) {
            if collectTrees { collected.append(t) } else { b.addTree(t, detail: dist < d.treeDetailRadius ? 2 : 1) }
        }
        let hedges = hedgerowTrees(b.soup.fieldPattern, foci: foci, radius: r)
        if collectTrees { collected += hedges } else { for t in hedges { b.addTree(t, detail: 1) } }
        if collectTrees && collected.count > d.maxTrees {
            // Thin only trees farther than 1 km from both foci, by a stable per-tree hash, to the cap.
            let nearCount = collected.filter { nearest(SIMD2($0.position.x, $0.position.y)).dist <= 1_000 }.count
            let keepFar = Double(max(0, d.maxTrees - nearCount)) / Double(max(1, collected.count - nearCount))
            collected = collected.filter { t in
                nearest(SIMD2(t.position.x, t.position.y)).dist <= 1_000
                    || Hash.unit(Hash.int(Int(t.position.x * 4), Int(t.position.y * 4), seed: 0x51C7)) < keepFar
            }
        }
        b.addRunway(runway, elevation: runwayElevation)
        b.addAirportKit(runway, elevation: runwayElevation)
        return (b.soup, collected)
    }

    /// Farmsteads in a corner of about one farmed parcel in six: a house, a barn and a shed on the parcel
    /// axes, clear of the hedgerows, roads, water and the runway approach. Farms used to line only the
    /// rural roads, and none reached the open fields the SkyWorld final camera looks across (art round 49).
    func parcelFarmsteads(_ fieldPattern: FieldPattern?, foci: [SIMD2<Double>], radius r: Double, roads: [Road]) -> [Building] {
        var out: [Building] = []
        guard let pattern = fieldPattern, let grid = pattern.parcels else { return out }
        let a = Double(FieldPattern.angle)
        let du = SIMD2(cos(a), sin(a)), dv = SIMD2(-sin(a), cos(a))
        let halfU = Double(FieldPattern.parcelU) / 2, halfV = Double(FieldPattern.parcelV) / 2
        let houseWalls = [srgb(206, 196, 172), srgb(188, 176, 156), srgb(214, 208, 196), srgb(170, 150, 124)]
        let houseRoofs = [srgb(118, 64, 48), srgb(96, 90, 86), srgb(134, 82, 58)]
        func roadDistance(_ p: SIMD2<Double>) -> Double {
            var best = Double.infinity
            for road in roads {
                for k in 0..<max(0, road.points.count - 1) {
                    let s0 = road.points[k], s1 = road.points[k + 1], e = s1 - s0
                    if min(s0.x, s1.x) > p.x + 40 || max(s0.x, s1.x) < p.x - 40 || min(s0.y, s1.y) > p.y + 40 || max(s0.y, s1.y) < p.y - 40 { continue }
                    let t = max(0, min(1, ((p - s0) * e).sum() / max(1e-9, (e * e).sum())))
                    let q = s0 + e * t - p
                    best = min(best, (q * q).sum().squareRoot())
                }
            }
            return best
        }
        for gy in 0..<grid.height {
            for gx in 0..<grid.width {
                let key = SIMD2(grid.iu0 + Int32(gx), grid.iv0 + Int32(gy))
                guard grid.isOn(key) else { continue }
                let h = Hash.int(Int(key.x), Int(key.y), seed: 0xFA57)
                if Hash.unit(h) > 0.17 { continue }
                let c = pattern.parcelCentre(key)
                let centre = SIMD2(Double(c.x), Double(c.y))
                guard foci.contains(where: { f in let e = centre - f; return (e * e).sum() < r * r }) else { continue }
                let heading = h & 4 == 0 ? a : a + Double.pi / 2
                let along = SIMD2(cos(heading), sin(heading)), across = SIMD2(-sin(heading), cos(heading))
                let su: Double = h & 1 == 0 ? 1 : -1, sv: Double = h & 2 == 0 ? 1 : -1
                // The parcel centre ignores the grid's ±22 m warp: try the four corners, keep the first whose
                // buildings all sit inside this parcel and clear of its hedges.
                for (cu, cv) in [(su, sv), (su, -sv), (-su, sv), (-su, -sv)] {
                    let yard = centre + du * cu * (halfU - 30) + dv * cv * (halfV - 38)
                    let inward = centre - yard   // barn and shed toward the parcel's middle
                    let ia = along * (((inward * along).sum() < 0) ? -1.0 : 1.0), ic = across * (((inward * across).sum() < 0) ? -1.0 : 1.0)
                    let house = yard, barn = yard + ia * 21 + ic * 9, shed = yard - ia * 2 + ic * 17
                    let parts: [(SIMD2<Double>, SIMD2<Double>, BuildingKind, Bool)] = [
                        (house, SIMD2(5.5, 7), .house, false), (barn, SIMD2(9, 13), .barn, false), (shed, SIMD2(3.5, 5), .barn, true)]
                    let fits = parts.allSatisfy { p, half, _, _ in
                        let hd = pattern.hedge(Float(p.x), Float(p.y))
                        let q = p - runway.threshold
                        let alongRwy = (q * runwayDirection).sum(), acrossRwy = abs(q.x * runwayDirection.y - q.y * runwayDirection.x)
                        return hd.parcel == key && Double(hd.distance) > (half * half).sum().squareRoot() + 4
                            && !recipe.isWater(p.x, p.y) && roadDistance(p) > 16
                            && !(alongRwy > -1_200 && alongRwy < runway.length + 400 && acrossRwy < 260)
                    }
                    if !fits { continue }
                    let wall = houseWalls[Int((h >> 8) % UInt64(houseWalls.count))]
                    let roofC = houseRoofs[Int((h >> 12) % UInt64(houseRoofs.count))]
                    for (p, half, kind, isShed) in parts {
                        out.append(Building(center: p, halfSize: half, heading: heading, baseHeight: height(p.x, p.y),
                                            wallHeight: isShed ? 3.2 : (kind == .barn ? 6.5 : 5.6), roof: .gabled,
                                            roofPitch: kind == .barn ? 0.75 : 0.6, kind: kind,
                                            wallColour: isShed ? srgb(118, 104, 84) : (kind == .barn ? srgb(132, 46, 36) : wall),
                                            roofColour: kind == .barn ? srgb(82, 80, 78) : roofC,
                                            variant: UInt32(truncatingIfNeeded: h >> 16) &+ (isShed ? 2 : kind == .barn ? 1 : 0)))
                    }
                    break
                }
            }
        }
        return out
    }

    /// Whether a point is within `margin` of any footprint in `buildings`.
    static func inside(_ p: SIMD2<Double>, _ buildings: [Building], margin: Double) -> Bool {
        buildings.contains { b in
            let d = p - b.center
            if abs(d.x) > 60 || abs(d.y) > 60 { return false }
            let c = cos(b.heading), s = sin(b.heading)
            return abs(c * d.x + s * d.y) < b.halfSize.x + margin && abs(-s * d.x + c * d.y) < b.halfSize.y + margin
        }
    }

    /// Broadleaf trees along the hedgerows of farmed parcels (every ~9 m with gaps, ~22 % kept), so the
    /// farmland reads as hedged fields with 3D trees instead of flat paint. Clear of the runway and its
    /// approach surface.
    func hedgerowTrees(_ fieldPattern: FieldPattern?, foci: [SIMD2<Double>], radius r: Double) -> [Tree] {
        var out: [Tree] = []
        guard let pattern = fieldPattern, let grid = pattern.parcels else { return out }
        let step = 9.0
        for f in foci {
            var y = f.y - r
            while y < f.y + r {
                var x = f.x - r
                while x < f.x + r {
                    defer { x += step }
                    let dx = x - f.x, dy = y - f.y, dist = (dx * dx + dy * dy).squareRoot()
                    if dist > r { continue }
                    // Each focus covers its own disc; skip points the other focus also covers (no doubles).
                    if foci.first(where: { g in let e = SIMD2(x, y) - g; return (e * e).sum() < r * r }) != f { continue }
                    let h = pattern.hedge(Float(x), Float(y))
                    if h.distance > 2.5 || !grid.isOn(h.parcel) { continue }
                    let u = Hash.unit(Hash.int(Int(x * 2), Int(y * 2), seed: 0x4ED6))
                    if u > 0.22 { continue }
                    // Runway strip and approach: no trees within 150 m of the centreline from 900 m before
                    // the threshold to the far end.
                    let q = SIMD2(x, y) - runway.threshold
                    let along = (q * runwayDirection).sum(), across = abs(q.x * runwayDirection.y - q.y * runwayDirection.x)
                    if along > -900 && along < runway.length + 300 && across < 150 { continue }
                    let ht = 9 + Hash.unit(Hash.int(Int(x * 3), Int(y * 3), seed: 0x7A11)) * 7
                    let tint = Float(0.85 + 0.3 * Hash.unit(Hash.int(Int(y * 3), Int(x * 3), seed: 0x0C01)))
                    let tree = Tree(position: SIMD3(x, y, height(x, y)), height: ht, crownRadius: ht * 0.32, conifer: false,
                                    colour: SIMD3<Float>(0.052, 0.078, 0.036) * tint)
                    if SceneBuilder.keepTree(tree.position, dist: dist, radius: r) { out.append(tree) }
                }
                y += step
            }
        }
        return out
    }

    /// Aircraft mesh in body axes (x forward, y right, z down) with smooth normals. Skin triangles carry
    /// the base paint and the `airframe` / `airSurface` materials: the world shader draws glazing, livery,
    /// seams and markings per pixel from the body coordinates (`AircraftLivery` holds the same zones).
    public static func aircraftMesh(accent: SIMD3<Float> = AircraftLivery.navy) -> TriangleSoup {
        var soup = TriangleSoup(origin: .zero)
        func f(_ n: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(n.x), Float(n.y), Float(n.z)) }
        for t in AircraftMesh.build() {
            let colour: SIMD3<Float>, mat: Material
            switch t.part {
            case .fuselage: colour = AircraftLivery.white; mat = .airframe
            case .surface: colour = AircraftLivery.white; mat = .airSurface
            case .glass: colour = SIMD3(0.55, 0.04, 0.03); mat = .glass          // beacon lens
            case .metal: colour = SIMD3(0.78, 0.79, 0.80); mat = .metal
            case .tyre: colour = SIMD3(0.012, 0.012, 0.013); mat = .opaque
            case .prop: colour = SIMD3(0.016, 0.016, 0.018); mat = .prop
            }
            soup.add(t.a, t.b, t.c, na: f(t.na), nb: f(t.nb), nc: f(t.nc), colour: colour, material: mat)
        }
        _ = accent
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
