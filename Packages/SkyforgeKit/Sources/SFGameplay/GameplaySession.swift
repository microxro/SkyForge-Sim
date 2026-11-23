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
    public var radar = RadarInput()
    public var countermeasures = CountermeasureInput()
    public init(flight: ControlInputs = ControlInputs(), weapons: WeaponInput = WeaponInput(),
                radar: RadarInput = RadarInput(), countermeasures: CountermeasureInput = CountermeasureInput()) {
        self.flight = flight; self.weapons = weapons
        self.radar = radar; self.countermeasures = countermeasures
    }
}

public enum GameEvent: Sendable, Equatable {
    case weapon(WeaponEvent)
    case mission(MissionEvent)
    case warning(EnvelopeWarning)
    case crashed(String)
    case radar(RadarEvent)
    case countermeasure(CountermeasureEvent)
    case hostile(HostileWeaponEvent)
    case playerDamaged(source: DamageSource, amount: Double)
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
    /// AI traffic, the tower and ownship's place in the tower's picture. Nil by default, so headless tests run unchanged.
    public private(set) var tower: TowerSession?
    /// The AI traffic, when the session has traffic.
    public var traffic: TrafficSystem? { tower?.traffic }
    /// The tower, when the session has traffic.
    public var atc: ATCController? { tower?.controller }

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
            tower = TowerSession(runway: runway, startsOnRunway: onGround)
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
    public var damage: AircraftDamage { director.damage }
    public var radar: RadarSet { director.radar }
    public var countermeasures: CountermeasureSystem { director.countermeasures }
    public var combat: CombatTally { director.combat }
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
        // Battle damage: a hurt engine gives less thrust and hurt surfaces less authority. Both factors are
        // exactly 1 while undamaged, so this is a no-op then.
        input = Self.applyDamageScaling(input, damage: director.damage)
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
                         weaponInput: controls.weapons, radarInput: controls.radar,
                         countermeasureInput: controls.countermeasures)
        if director.monitor.structuralFailure { fail("Airframe overstressed") }
        updateTraffic(dt: dt)
        checkShotDown()
    }

    /// Scales the final control inputs by the battle damage: throttle by `thrustFactor`, and elevator,
    /// aileron and rudder by `controlFactor`. Gear, flaps and everything else pass through. With intact
    /// damage both factors are exactly 1.0, and x * 1.0 == x in IEEE arithmetic, so the inputs come back
    /// unchanged.
    public static func applyDamageScaling(_ inputs: ControlInputs, damage: AircraftDamage) -> ControlInputs {
        let thrust: Double = damage.thrustFactor
        let authority: Double = damage.controlFactor
        var out: ControlInputs = inputs
        out.throttle = inputs.throttle * thrust
        out.elevator = inputs.elevator * authority
        out.aileron = inputs.aileron * authority
        out.rudder = inputs.rudder * authority
        return out
    }

    /// Feeds hostile weapon events straight into the director, as if hostile fire had produced them, then
    /// applies the shot-down check. Internal: for tests and scripted sequences.
    mutating func receiveHostileEvents(_ events: [HostileWeaponEvent]) {
        director.applyHostileEvents(events)
        checkShotDown()
    }

    /// Ends the flight when hostile fire has destroyed the airframe.
    private mutating func checkShotDown() {
        if director.damage.destroyed { fail(director.shotDownReason) }
    }

    /// Snapshots of the AI aircraft, for the renderer and HUD.
    public var trafficSnapshots: [TrafficSnapshot] { traffic?.snapshots ?? [] }

    /// The clearance the tower is waiting on from the pilot, if any. Answer it with `answerTower(choice:)`.
    public var towerPrompt: OwnshipPrompt? { tower?.prompt }

    /// The pilot's readback choice for the tower's prompt. Returns true when correct, false for "say again", and nil
    /// when no prompt is waiting.
    @discardableResult
    public mutating func answerTower(choice: Int) -> Bool? {
        tower?.readback(choice: choice)
    }

    /// Steps the traffic and the tower, and gives ownship the wakes of the heavy aircraft near it.
    private mutating func updateTraffic(dt: Double) {
        guard tower != nil else { return }
        let report = OwnshipReport(config: aircraft.config, positionNED: state.positionNED,
                                   velocityNED: state.velocityNED, onGround: onGround)
        _ = tower?.step(dt: dt, ownship: report, wind: ATCWind(windNED: environment.windNED))
        environment.wakes = tower?.traffic.wakesNear(state.positionNED) ?? []
    }

    private mutating func fail(_ reason: String) {
        guard !crashed else { return }
        crashed = true
        crashReason = reason
    }
}
