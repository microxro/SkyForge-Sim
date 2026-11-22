// SKYFORGE — Apache-2.0
// Everything about a flight that is not the flight model: AI aircraft, weapons, the envelope monitor
// and the mission runtime. It reads a snapshot of the flight each step, so the same director drives the
// headless `GameplaySession` and the app's Quick Flight session.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel

public typealias ControlFilter = @Sendable (ControlInputs, AircraftState, FlightOutputs) -> ControlInputs

public struct FlightSnapshot: Sendable {
    public var time: Double
    public var state: AircraftState
    public var outputs: FlightOutputs       // from the step's control inputs, before integrating
    public var flaps: Double
    public var heightAGL: Double            // centre of gravity above the ground
    public var crashed: Bool
    public var crashReason: String?

    public init(time: Double, state: AircraftState, outputs: FlightOutputs, flaps: Double, heightAGL: Double,
                crashed: Bool = false, crashReason: String? = nil) {
        self.time = time; self.state = state; self.outputs = outputs; self.flaps = flaps
        self.heightAGL = heightAGL; self.crashed = crashed; self.crashReason = crashReason
    }
}

public struct GameplayDirector: Sendable {
    public let aircraft: PlaneSpec
    public let frame: RunwayFrame
    public let mission: MissionDefinition?
    public private(set) var targets: [AITarget]
    public private(set) var weapons: WeaponSystem
    public private(set) var monitor: EnvelopeMonitor
    public private(set) var runtime: MissionRuntime?
    public private(set) var loadFactor = 1.0
    public private(set) var kills = 0
    public private(set) var pendingEvents: [GameEvent] = []
    private var previousWarnings: Set<EnvelopeWarning> = []

    public init(aircraft: PlaneSpec, frame: RunwayFrame, mission: MissionDefinition?) {
        self.aircraft = aircraft; self.frame = frame; self.mission = mission
        targets = (mission?.targets ?? []).map { $0.makeTarget(frame: frame) }
        weapons = WeaponSystem(kinds: aircraft.armament)
        monitor = EnvelopeMonitor(limits: aircraft.limits)
        if let m = mission { runtime = MissionRuntime(mission: m, frame: frame, aircraftID: aircraft.id) }
    }

    /// Control path for the flight model: the fly-by-wire limiter where fitted, and automatic gear for
    /// retractable aircraft (down on the ground or below 1.35x approach speed, up otherwise). Nil when neither applies.
    public static func makeControlFilter(for aircraft: PlaneSpec) -> ControlFilter? {
        let retractable = aircraft.config.retractableGear
        guard aircraft.flyByWire || retractable else { return nil }
        let law = aircraft.flyByWire ? FlightControlLaw(limits: aircraft.limits, config: aircraft.config) : nil
        let config = aircraft.config
        let gearSpeed = aircraft.approachSpeed * 1.35
        return { input, state, out in
            var u = input.sanitized
            if retractable { u.gear = (out.weightOnWheels || out.trueAirspeed < gearSpeed) ? 1 : 0 }
            guard let law else { return u }
            let rho = ISA.state(geometricAltitude: state.altitude).density
            let q = 0.5 * rho * out.trueAirspeed * out.trueAirspeed
            let nz = EnvelopeMath.loadFactor(state: state, outputs: out, config: config)
            return law.apply(u, qbar: q, nz: nz)
        }
    }

    public var isFinished: Bool { runtime?.isFinished ?? false }

    /// Returns and clears the events raised since the last call.
    public mutating func drainEvents() -> [GameEvent] {
        defer { pendingEvents.removeAll(keepingCapacity: true) }
        return pendingEvents
    }

    /// Advances AI, weapons, the envelope and the mission by `dt` using the flight's snapshot.
    public mutating func advance(dt: Double, snapshot: FlightSnapshot, weaponInput: WeaponInput) {
        let s = snapshot.state, o = snapshot.outputs
        loadFactor = EnvelopeMath.loadFactor(state: s, outputs: o, config: aircraft.config)

        for i in targets.indices { targets[i].step(dt: dt, threat: s.positionNED) }
        let own = Ownship(position: s.positionNED, velocity: s.velocityNED, forward: s.attitude.rotate(SIMD3(1, 0, 0)))
        for e in weapons.update(dt: dt, ownship: own, input: weaponInput, targets: &targets) {
            pendingEvents.append(.weapon(e))
            if case .destroyed(let id, _) = e, targets.first(where: { $0.id == id })?.role == .hostile {
                kills += 1
                runtime?.noteKill()
            }
        }

        let mach = EnvelopeMath.mach(trueAirspeed: o.trueAirspeed, altitudeMSL: s.altitude)
        monitor.update(nz: loadFactor, trueAirspeed: o.trueAirspeed, mach: mach, flaps: snapshot.flaps,
                       stalled: o.stalled, onGround: o.weightOnWheels, heightAGL: snapshot.heightAGL,
                       sinkRate: s.velocityNED.z, dt: dt)
        for w in monitor.warnings.subtracting(previousWarnings).sorted() { pendingEvents.append(.warning(w)) }
        previousWarnings = monitor.warnings

        if runtime != nil {
            let failed = monitor.structuralFailure
            let sample = FlightSample(time: snapshot.time, positionNED: s.positionNED, velocityNED: s.velocityNED,
                                      heightAGL: snapshot.heightAGL - aircraft.gearHeight, onGround: o.weightOnWheels,
                                      crashed: snapshot.crashed || failed,
                                      crashReason: snapshot.crashed ? snapshot.crashReason : (failed ? "Airframe overstressed" : nil))
            for e in runtime!.update(sample: sample, targets: targets, overstressSeconds: monitor.overstressSeconds) {
                pendingEvents.append(.mission(e))
            }
        }
    }
}
