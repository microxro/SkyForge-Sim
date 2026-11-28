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
    /// The player's airframe, engine and control-surface health.
    public private(set) var damage: AircraftDamage = AircraftDamage()
    /// Combat statistics for the flight, passed to the mission runtime.
    public private(set) var combat: CombatTally = CombatTally()
    /// Tower compliance errors, set by the session each tick from the tower. Zero without a tower.
    var towerErrors = 0
    public private(set) var radar: RadarSet = RadarSet()
    public private(set) var countermeasures: CountermeasureSystem = CountermeasureSystem()
    /// Guns and missiles fired by hostile AI aircraft at the player.
    public private(set) var hostileWeapons: HostileWeapons = HostileWeapons()
    /// The id of the aircraft whose hit destroyed the player's airframe; nil while intact or if the source is unknown.
    public private(set) var destroyedBy: String? = nil
    private var previousWarnings: Set<EnvelopeWarning> = []

    public init(aircraft: PlaneSpec, frame: RunwayFrame, mission: MissionDefinition?) {
        self.aircraft = aircraft; self.frame = frame; self.mission = mission
        targets = (mission?.targets ?? []).map { $0.makeTarget(frame: frame) }
        weapons = WeaponSystem(kinds: aircraft.armament)
        monitor = EnvelopeMonitor(limits: aircraft.limits)
        if let m = mission { runtime = MissionRuntime(mission: m, frame: frame, aircraftID: aircraft.id) }
    }

    /// Airspeed (m/s) below which a retractable aircraft's gear is commanded down: 1.35x approach speed.
    public static func gearDownSpeed(for aircraft: PlaneSpec) -> Double { aircraft.approachSpeed * 1.35 }

    /// Fly-by-wire limiter for the flight model's control path; nil for aircraft with direct controls.
    /// Gear is not set here: the session's `GearActuator` moves it over time and feeds `ControlInputs.gear`.
    public static func makeControlFilter(for aircraft: PlaneSpec) -> ControlFilter? {
        guard aircraft.flyByWire else { return nil }
        let law = FlightControlLaw(limits: aircraft.limits, config: aircraft.config)
        let config = aircraft.config
        return { input, state, out in
            let rho = ISA.state(geometricAltitude: state.altitude).density
            let q = 0.5 * rho * out.trueAirspeed * out.trueAirspeed
            let nz = EnvelopeMath.loadFactor(state: state, outputs: out, config: config)
            return law.apply(input, qbar: q, nz: nz)
        }
    }

    public var isFinished: Bool { runtime?.isFinished ?? false }

    /// Returns and clears the events raised since the last call.
    public mutating func drainEvents() -> [GameEvent] {
        defer { pendingEvents.removeAll(keepingCapacity: true) }
        return pendingEvents
    }

    /// Advances countermeasures, AI, radar, weapons, hostile fire, the envelope and the mission by `dt`
    /// using the flight's snapshot. The radar and countermeasure inputs default to "nothing pressed", so
    /// callers without those controls behave as before.
    public mutating func advance(dt: Double, snapshot: FlightSnapshot, weaponInput: WeaponInput,
                                 radarInput: RadarInput = RadarInput(),
                                 countermeasureInput: CountermeasureInput = CountermeasureInput()) {
        let s: AircraftState = snapshot.state
        let o: FlightOutputs = snapshot.outputs
        loadFactor = EnvelopeMath.loadFactor(state: s, outputs: o, config: aircraft.config)
        let own = Ownship(position: s.positionNED, velocity: s.velocityNED,
                          forward: s.attitude.rotate(SIMD3<Double>(1, 0, 0)))

        // 1. Countermeasures: flares and chaff on the input's rising edges.
        let cmEvents: [CountermeasureEvent] = countermeasures.update(dt: dt, ownship: own, input: countermeasureInput)
        for e in cmEvents {
            if case .deployed = e { combat.countermeasuresUsed += 1 }
            pendingEvents.append(.countermeasure(e))
        }

        // 2. AI aircraft, reacting to the player's position and velocity.
        FormationFlight.step(&targets, dt: dt, threat: s.positionNED, threatVelocity: s.velocityNED)

        // 3. Radar, blinded by live chaff.
        let radarEvents: [RadarEvent] = radar.update(dt: dt, ownship: own, targets: targets, input: radarInput,
                                                     chaffClouds: countermeasures.chaffClouds)
        for e in radarEvents { pendingEvents.append(.radar(e)) }

        // 4. The player's weapons.
        let weaponEvents: [WeaponEvent] = weapons.update(dt: dt, ownship: own, input: weaponInput, targets: &targets,
                                                         radarLockID: radar.lockedTargetID,
                                                         decoys: countermeasures.decoys)
        for e in weaponEvents {
            pendingEvents.append(.weapon(e))
            if case .destroyed(let id, _) = e, targets.first(where: { $0.id == id })?.role == .hostile {
                kills += 1
                runtime?.noteKill()
            }
            switch e {
            case .missileLaunched, .radarMissileLaunched:
                combat.missilesFired += 1
            case .hit(_, let weapon):
                if weapon == .heatMissile || weapon == .radarMissile { combat.missilesHit += 1 }
            default:
                break
            }
        }

        // 4b. Midair contact with a live AI aircraft. The target is destroyed and the airframe takes one collision hit.
        for i in targets.indices where !targets[i].destroyed && Self.inContact(position: s.positionNED, target: targets[i]) {
            let id = targets[i].id
            targets[i].health = 0
            applyHit(source: .collision, amount: AircraftDamage.collisionDamage, sourceID: id)
        }

        // 5. Hostile fire at the player.
        let hostile: [HostileWeaponEvent] = hostileWeapons.update(dt: dt, targets: targets, player: own,
                                                                  decoys: countermeasures.decoys)
        applyHostileEvents(hostile)

        // 6. Envelope monitor.
        let mach = EnvelopeMath.mach(trueAirspeed: o.trueAirspeed, altitudeMSL: s.altitude)
        monitor.update(nz: loadFactor, trueAirspeed: o.trueAirspeed, mach: mach, flaps: snapshot.flaps,
                       stalled: o.stalled, onGround: o.weightOnWheels, heightAGL: snapshot.heightAGL,
                       sinkRate: s.velocityNED.z, dt: dt)
        // Runs every 120 Hz step; the warning set is almost always unchanged, so skip the set algebra then.
        if monitor.warnings != previousWarnings {
            for w in monitor.warnings.subtracting(previousWarnings).sorted() { pendingEvents.append(.warning(w)) }
            previousWarnings = monitor.warnings
        }

        // 7. Mission runtime. A shot-down airframe ends the mission like a crash.
        if runtime != nil {
            let failed: Bool = monitor.structuralFailure
            let shotDown: Bool = damage.destroyed
            let reason: String?
            if snapshot.crashed {
                reason = snapshot.crashReason
            } else if failed {
                reason = "Airframe overstressed"
            } else if shotDown {
                reason = shotDownReason
            } else {
                reason = nil
            }
            let sample = FlightSample(time: snapshot.time, positionNED: s.positionNED, velocityNED: s.velocityNED,
                                      heightAGL: snapshot.heightAGL - aircraft.gearHeight, onGround: o.weightOnWheels,
                                      crashed: snapshot.crashed || failed || shotDown,
                                      crashReason: reason, bodyRates: s.bodyRates)
            let missionEvents: [MissionEvent] = runtime!.update(sample: sample, targets: targets,
                                                                overstressSeconds: monitor.overstressSeconds,
                                                                combat: combat, radarLockedID: radar.lockedTargetID,
                                                                towerErrors: towerErrors)
            for e in missionEvents { pendingEvents.append(.mission(e)) }
        }
    }

    /// Ownship contact radius (m), added to a target's hit sphere to decide a midair collision.
    public static let contactRadius = 8.0

    /// True when the ownship at `position` is inside a target's hit sphere plus the contact radius.
    static func inContact(position: SIMD3<Double>, target: AITarget) -> Bool {
        let d = target.position - position
        let reach = target.radius + contactRadius
        return (d.x * d.x + d.y * d.y + d.z * d.z) <= reach * reach
    }

    /// "Shot down by <id>" when the destroying hit's source is known, else "Shot down".
    var shotDownReason: String {
        if let id = destroyedBy { return "Shot down by \(id)" }
        return "Shot down"
    }

    /// Hit zone for the player's hit number `hitIndex` (0-based, taken from `combat.hitsTaken`). The rule is
    /// deterministic, with no randomness: every fifth hit (index 4, 9, 14, ...) strikes the engine, every
    /// seventh hit (index 6, 13, 20, ...) strikes the controls, and all other hits strike the airframe. When
    /// both rules match (index 34, 69, ...) the engine wins. Over a long fight that is 20% engine, about 11%
    /// controls and the rest airframe.
    static func hitZone(hitIndex: Int) -> DamageZone {
        let n: Int = max(0, hitIndex)
        if n % 5 == 4 { return .engine }
        if n % 7 == 6 { return .controls }
        return .airframe
    }

    /// Records hostile weapon events and applies the damage of each hit on the player. Internal so tests can
    /// drive a known sequence of hits without depending on the hostile AI's aim.
    mutating func applyHostileEvents(_ events: [HostileWeaponEvent]) {
        for e in events {
            pendingEvents.append(.hostile(e))
            if case .cannonHit(let id) = e {
                applyHit(source: .cannon, amount: AircraftDamage.cannonRoundDamage, sourceID: id)
            } else if case .missileHit(let id) = e {
                applyHit(source: .missile, amount: AircraftDamage.missileWarheadDamage, sourceID: id)
            }
        }
    }

    private mutating func applyHit(source: DamageSource, amount: Double, sourceID: String) {
        // A destroyed airframe takes no more damage, so the tally only counts damage actually applied.
        guard !damage.destroyed else { return }
        let zone: DamageZone = Self.hitZone(hitIndex: combat.hitsTaken)
        let killed: Bool = damage.apply(source: source, zone: zone, amount: amount)
        combat.hitsTaken += 1
        combat.damageTaken += amount
        pendingEvents.append(.playerDamaged(source: source, amount: amount))
        if killed && destroyedBy == nil { destroyedBy = sourceID }
    }
}
