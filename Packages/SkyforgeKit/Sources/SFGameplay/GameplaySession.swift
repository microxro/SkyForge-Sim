// SKYFORGE — Apache-2.0
// One flight: any aircraft in the catalog on any FlightWorld, optionally running a mission. It owns the
// flight model, the fly-by-wire law, the envelope monitor, AI aircraft, weapons and the mission
// runtime, and steps them together at a fixed 120 Hz. GPU-free, so it runs headless in tests.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel
import SFQuickFlight

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
    public let aircraft: AircraftSpec
    public let mission: MissionDefinition?
    public let frame: RunwayFrame
    public let model: FlightModel
    public let environment: FlightEnvironment

    public private(set) var state: AircraftState
    /// Inputs after the control law (what the surfaces actually did on the last step).
    public private(set) var effectiveInputs = ControlInputs()
    public private(set) var targets: [AITarget] = []
    public private(set) var weapons: WeaponSystem
    public private(set) var monitor: EnvelopeMonitor
    public private(set) var runtime: MissionRuntime?
    public private(set) var time = 0.0
    public private(set) var loadFactor = 1.0
    public private(set) var onGround = false
    public private(set) var crashed = false
    public private(set) var crashReason: String?
    public private(set) var pendingEvents: [GameEvent] = []

    private var control: FlightControlLaw
    private var accumulator = 0.0
    private var lastSinkRate = 0.0
    private var previousWarnings: Set<EnvelopeWarning> = []
    private var trimmedInputs = ControlInputs()

    /// Starts a mission, or a free flight on the runway when `mission` is nil.
    public init(world: any FlightWorld, aircraft: AircraftSpec, mission: MissionDefinition? = nil) {
        self.world = world
        self.aircraft = aircraft
        self.mission = mission
        let frame = RunwayFrame(world: world)
        self.frame = frame
        model = aircraft.model
        let wind = mission?.wind.windNED(runwayHeading: frame.heading) ?? .zero
        let env = FlightEnvironment(windNED: wind, terrain: FlightWorldTerrain(world))
        environment = env
        control = FlightControlLaw(limits: aircraft.limits, config: aircraft.config)
        monitor = EnvelopeMonitor(limits: aircraft.limits)
        weapons = WeaponSystem(kinds: aircraft.armament)

        let spawn = mission?.spawn ?? MissionSpawn(along: 60, onRunway: true)
        let (s, trimmed) = Self.makeInitialState(spawn: spawn, aircraft: aircraft, frame: frame, wind: wind, terrain: env.terrain)
        state = s
        trimmedInputs = trimmed
        effectiveInputs = trimmed
        targets = (mission?.targets ?? []).map { $0.makeTarget(frame: frame) }
        if let m = mission { runtime = MissionRuntime(mission: m, frame: frame, aircraftID: aircraft.id) }
        onGround = spawn.onRunway
    }

    /// Inputs that hold the spawn trim (throttle and elevator) until the pilot's first input.
    public var spawnTrim: ControlInputs { trimmedInputs }

    static func makeInitialState(spawn: MissionSpawn, aircraft: AircraftSpec, frame: RunwayFrame, wind: SIMD3<Double>,
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
        let trim = aircraft.model.trimLevel(trueAirspeed: speed, altitude: -p.z, flaps: spawn.flaps)
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
    public var missionResult: MissionResult? { runtime?.result }
    public var isFinished: Bool { crashed || (runtime?.isFinished ?? false) }
    /// Position in world coordinates (x east, y north, z up), as the renderer uses.
    public var positionENU: SIMD3<Double> { SIMD3(state.positionNED.y, state.positionNED.x, -state.positionNED.z) }

    /// Returns and clears the events raised since the last call.
    public mutating func drainEvents() -> [GameEvent] {
        defer { pendingEvents.removeAll(keepingCapacity: true) }
        return pendingEvents
    }

    // MARK: Stepping

    /// Advances real time `realDt` in fixed 120 Hz steps (at most 8 per call).
    public mutating func update(realDt: Double, controls: PilotControls) {
        guard !isFinished else { return }
        accumulator = min(accumulator + realDt, 8 * Self.dt)
        while accumulator >= Self.dt, !isFinished {
            step(controls)
            accumulator -= Self.dt
        }
    }

    public mutating func step(_ controls: PilotControls) {
        let dt = Self.dt
        var input = controls.flight.sanitized
        let atm = ISA.state(geometricAltitude: state.altitude)
        let before = model.forcesAndMoments(state, input, environment).2
        loadFactor = EnvelopeMath.loadFactor(state: state, outputs: before, config: aircraft.config)
        if aircraft.flyByWire {
            let qbar = 0.5 * atm.density * before.trueAirspeed * before.trueAirspeed
            input = control.apply(input, qbar: qbar, nz: loadFactor)
        }
        effectiveInputs = input
        let sinkBefore = state.velocityNED.z

        state = model.step(state, inputs: input, environment: environment, dt: dt)
        time += dt
        onGround = before.weightOnWheels
        if !onGround { lastSinkRate = sinkBefore }

        // Crash: gear well below the surface, or ground contact at over 3 m/s sink.
        let clearance = heightAGL - aircraft.gearHeight
        if clearance < -0.8 || (clearance < -0.25 && sinkBefore > 3.0) { fail("Crashed into the ground") }

        // AI aircraft and weapons.
        for i in targets.indices { targets[i].step(dt: dt, threat: state.positionNED) }
        let own = Ownship(position: state.positionNED, velocity: state.velocityNED, forward: state.attitude.rotate(SIMD3(1, 0, 0)))
        for e in weapons.update(dt: dt, ownship: own, input: controls.weapons, targets: &targets) {
            pendingEvents.append(.weapon(e))
        }

        // Envelope.
        let m = EnvelopeMath.mach(trueAirspeed: before.trueAirspeed, altitudeMSL: state.altitude)
        monitor.update(nz: loadFactor, trueAirspeed: before.trueAirspeed, mach: m, flaps: input.flaps,
                       stalled: before.stalled, onGround: onGround, heightAGL: heightAGL, sinkRate: state.velocityNED.z, dt: dt)
        for w in monitor.warnings.subtracting(previousWarnings).sorted() { pendingEvents.append(.warning(w)) }
        previousWarnings = monitor.warnings
        if monitor.structuralFailure { fail("Airframe overstressed") }

        // Mission.
        if runtime != nil {
            let sample = FlightSample(time: time, positionNED: state.positionNED, velocityNED: state.velocityNED,
                                      heightAGL: clearance, onGround: onGround, crashed: crashed, crashReason: crashReason)
            for e in runtime!.update(sample: sample, targets: targets, overstressSeconds: monitor.overstressSeconds) {
                pendingEvents.append(.mission(e))
            }
        }
    }

    private mutating func fail(_ reason: String) {
        guard !crashed else { return }
        crashed = true
        crashReason = reason
        pendingEvents.append(.crashed(reason))
    }
}
