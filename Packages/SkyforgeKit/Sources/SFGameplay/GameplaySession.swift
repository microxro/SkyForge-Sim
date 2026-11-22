// SKYFORGE — Apache-2.0
// One flight: any aircraft in the catalog on any FlightWorld, optionally running a mission. It owns the
// flight model, the fly-by-wire law, the envelope monitor, AI aircraft, weapons and the mission
// runtime, and steps them together at a fixed 120 Hz. GPU-free, so it runs headless in tests.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel
import SFQuickFlight
import SFTraffic
import SFATC

public struct PilotControls: Sendable, Equatable {
    public var flight = ControlInputs()
    public var weapons = WeaponInput()
    public init(flight: ControlInputs = ControlInputs(), weapons: WeaponInput = WeaponInput()) {
        self.flight = flight; self.weapons = weapons
    }
}

public enum GameEvent: Sendable, Equatable {
    case weapon(WeaponEvent)
    case mission(MissionEvent)
    case warning(EnvelopeWarning)
    case crashed(String)
}

public struct GameplaySession: Sendable {
    public static let dt = 1.0 / 120

    public let world: any FlightWorld
    public let aircraft: PlaneSpec
    public let mission: MissionDefinition?
    public let frame: RunwayFrame
    public let model: FlightModel
    /// Wind, terrain and the wake vortices of other aircraft (`wakes`, updated from the traffic each step).
    public private(set) var environment: FlightEnvironment

    public private(set) var state: AircraftState
    /// Inputs after the control law (what the surfaces actually did on the last step).
    public private(set) var effectiveInputs = ControlInputs()
    public private(set) var director: GameplayDirector
    public private(set) var time = 0.0
    public private(set) var onGround = false
    public private(set) var crashed = false
    public private(set) var crashReason: String?

    private let controlFilter: ControlFilter?
    private var accumulator = 0.0
    private var trimmedInputs = ControlInputs()
    /// Landing-gear travel for retractable aircraft; `ControlInputs.gear` follows its position.
    private var gear = GearActuator()
    private var crashReported = false
    /// AI traffic and the tower, when the session has them. Nil by default, so headless tests run unchanged.
    public private(set) var traffic: TrafficSystem?
    public private(set) var atc: ATCController?
    private var atcClock = 0.0
    /// Seconds between tower decisions (s).
    public static let atcInterval = 0.5

    /// Starts a mission, or a free flight on the runway when `mission` is nil.
    /// `trafficEnabled` adds AI arrivals and departures at this runway, with the tower clearing them.
    public init(world: any FlightWorld, aircraft: PlaneSpec, mission: MissionDefinition? = nil, trafficEnabled: Bool = false) {
        self.world = world
        self.aircraft = aircraft
        self.mission = mission
        let frame = RunwayFrame(world: world)
        self.frame = frame
        model = aircraft.model
        let wind = mission?.wind.windNED(runwayHeading: frame.heading) ?? .zero
        let env = FlightEnvironment(windNED: wind, terrain: FlightWorldTerrain(world))
        environment = env
        controlFilter = GameplayDirector.makeControlFilter(for: aircraft)
        director = GameplayDirector(aircraft: aircraft, frame: frame, mission: mission)

        let spawn = mission?.spawn ?? MissionSpawn(along: 60, onRunway: true)
        let (s, trimmed) = Self.makeInitialState(spawn: spawn, aircraft: aircraft, frame: frame, wind: wind, terrain: env.terrain)
        state = s
        trimmedInputs = trimmed
        effectiveInputs = trimmed
        gear = GearActuator(position: trimmed.gear)
        onGround = spawn.onRunway
        if trafficEnabled {
            let runway = TrafficRunway(threshold: world.runwayThreshold, heading: world.runwayHeading,
                                       length: world.runwayLengthMetres, elevation: world.runwayElevation)
            traffic = TrafficSystem(runway: runway)
            atc = ATCController(runwayDesignator: runway.designator)
        }
    }

    /// Gear position (0 retracted … 1 extended) as it travels; 1 for fixed-gear aircraft.
    public var gearPosition: Double { gear.position }

    /// Inputs that hold the spawn trim (throttle and elevator) until the pilot's first input.
    public var spawnTrim: ControlInputs { trimmedInputs }

    /// The aircraft state and control inputs for a mission spawn (or the runway start when `onRunway`).
    public static func makeInitialState(spawn: MissionSpawn, aircraft: PlaneSpec, frame: RunwayFrame, wind: SIMD3<Double>,
                                 terrain: any TerrainHeightProvider) -> (AircraftState, ControlInputs) {
        let heading = frame.heading + spawn.headingOffset
        if spawn.onRunway {
            var p = frame.ned(along: spawn.along, right: spawn.right, up: 0)
            p.z = -(terrain.elevation(north: p.x, east: p.y) + aircraft.gearHeight - 0.03)
            return (AircraftState(positionNED: p, velocityBody: .zero,
                                  attitude: Quaternion(roll: 0, pitch: 0, yaw: heading), bodyRates: .zero), ControlInputs())
        }
        let speed: Double
        switch spawn.speed {
        case .cruise: speed = aircraft.cruiseSpeed
        case .approach: speed = aircraft.approachSpeed
        case .fixed(let v): speed = v
        }
        let p = frame.ned(along: spawn.along, right: spawn.right, up: spawn.up)
        // Trim in still air at this altitude, then add the wind so the airspeed stays what was asked.
        let gearDown = speed < GameplayDirector.gearDownSpeed(for: aircraft)
        let trim = aircraft.model.trimLevel(trueAirspeed: speed, altitude: -p.z, flaps: spawn.flaps, gear: gearDown ? 1 : 0)
        let attitude = Quaternion(roll: 0, pitch: trim.alpha, yaw: heading)
        let windBody = attitude.conjugate.rotate(wind)
        var s = AircraftState(positionNED: p, velocityBody: trim.state.velocityBody + windBody,
                              attitude: attitude, bodyRates: .zero)
        s.time = 0
        return (s, trim.inputs)
    }

    // MARK: Derived

    public var altitudeMSL: Double { state.altitude }
    public var heightAGL: Double {
        state.altitude - environment.terrain.elevation(north: state.positionNED.x, east: state.positionNED.y)
    }
    public var trueAirspeed: Double { length(state.velocityBody - state.attitude.conjugate.rotate(environment.windNED)) }
    public var mach: Double { EnvelopeMath.mach(trueAirspeed: trueAirspeed, altitudeMSL: altitudeMSL) }
    public var targets: [AITarget] { director.targets }
    public var weapons: WeaponSystem { director.weapons }
    public var monitor: EnvelopeMonitor { director.monitor }
    public var runtime: MissionRuntime? { director.runtime }
    public var loadFactor: Double { director.loadFactor }
    public var missionResult: MissionResult? { director.runtime?.result }
    public var isFinished: Bool { crashed || director.isFinished }
    /// Position in world coordinates (x east, y north, z up), as the renderer uses.
    public var positionENU: SIMD3<Double> { SIMD3(state.positionNED.y, state.positionNED.x, -state.positionNED.z) }

    /// Returns and clears the events raised since the last call.
    public mutating func drainEvents() -> [GameEvent] {
        var events = director.drainEvents()
        if let reason = crashReason, !crashReported { events.append(.crashed(reason)); crashReported = true }
        return events
    }

    // MARK: Stepping

    /// Advances real time `realDt` in fixed 120 Hz steps (at most 8 per call).
    public mutating func update(realDt: Double, controls: PilotControls) {
        guard !isFinished, realDt.isFinite, realDt > 0 else { return }
        accumulator = min(accumulator + realDt, 8 * Self.dt)
        while accumulator >= Self.dt, !isFinished {
            step(controls)
            accumulator -= Self.dt
        }
    }

    public mutating func step(_ controls: PilotControls) {
        let dt = Self.dt
        var input = controls.flight.sanitized
        input.gear = gear.position
        let before = model.forcesAndMoments(state, input, environment).2
        if aircraft.config.retractableGear {
            // Automatic gear: commanded down on the ground or below the gear-down speed, and it travels over time.
            let commandDown = before.weightOnWheels || before.trueAirspeed < GameplayDirector.gearDownSpeed(for: aircraft)
            input.gear = gear.update(commandDown: commandDown, dt: dt)
        }
        if let filter = controlFilter { input = filter(input, state, before) }
        effectiveInputs = input
        let sinkBefore = state.velocityNED.z

        state = model.step(state, inputs: input, environment: environment, dt: dt)
        time += dt
        onGround = before.weightOnWheels

        // Crash: the airframe well below the surface, or ground contact at over 3 m/s sink. The
        // thresholds match Quick Flight's (a belly strike), so a firm gear landing is not a crash.
        let lowest = heightAGL - aircraft.gearHeight
        if lowest < -1.75 || (lowest < -0.95 && sinkBefore > 3.0) { fail("Crashed into the ground") }

        director.advance(dt: dt, snapshot: FlightSnapshot(time: time, state: state, outputs: before, flaps: input.flaps,
                                                          heightAGL: heightAGL, crashed: crashed, crashReason: crashReason),
                         weaponInput: controls.weapons)
        if director.monitor.structuralFailure { fail("Airframe overstressed") }
        updateTraffic(dt: dt)
    }

    /// Snapshots of the AI aircraft, for the renderer and HUD.
    public var trafficSnapshots: [TrafficSnapshot] { traffic?.snapshots ?? [] }

    /// Steps the traffic in place, lets the tower clear it, and gives ownship the wakes of the heavy aircraft near it.
    private mutating func updateTraffic(dt: Double) {
        guard traffic != nil else { return }
        traffic?.step(dt: dt)
        _ = traffic?.drainEvents()   // nothing reads these yet; drain so the buffer stays short
        atcClock += dt
        if atcClock >= Self.atcInterval {
            atcClock = 0
            let simTime = traffic?.time ?? 0
            let snapshots = traffic?.snapshots ?? []
            let wind = ATCWind(windNED: environment.windNED)
            let instructions = atc?.update(time: simTime, traffic: snapshots, wind: wind) ?? []
            for instruction in instructions {
                if let clearance = instruction.clearance {
                    _ = traffic?.issue(clearance, to: instruction.aircraftID)
                }
            }
        }
        environment.wakes = traffic?.wakesNear(state.positionNED) ?? []
    }

    private mutating func fail(_ reason: String) {
        guard !crashed else { return }
        crashed = true
        crashReason = reason
    }
}
