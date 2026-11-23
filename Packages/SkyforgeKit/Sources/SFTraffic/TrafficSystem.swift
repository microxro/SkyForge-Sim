// SKYFORGE — Apache-2.0
// AI traffic at one runway. Arrivals fly the traffic pattern and turn final only when cleared; without a
// clearance at the base-to-final turn they go around the pattern again. Departures hold short until cleared,
// roll, and climb out on a fixed route. Each aircraft is a point mass with its type's speeds and climb limit,
// guided toward runway waypoints. Heavy aircraft shed wake pairs (SFFlightModel's WakeTracker) that ownship's
// FlightEnvironment feels. Deterministic: a seeded generator drives spawns and callsigns, so tests replay exactly.
import Foundation
import SFAtmosphere
import SFFlightModel

public struct TrafficSystem: Sendable {
    public let runway: TrafficRunway
    public let pattern: TrafficPatternGeometry
    public let schedule: TrafficSchedule
    public let fleet: [AircraftConfig]
    /// Air density at the field (kg/m^3), from the ISA model at the runway elevation.
    public let density: Double
    /// Aircraft in the system, in spawn order.
    public private(set) var aircraft: [TrafficAircraft] = []
    /// Wake pairs from heavy aircraft. Pass `wakes.active` to the follower's `FlightEnvironment.wakes`.
    public private(set) var wakes = WakeTracker()
    /// Simulated seconds since the system started.
    public private(set) var time = 0.0
    private var pendingEvents: [TrafficEvent] = []
    private var rng: UInt64
    private var nextArrival: Double
    private var nextDeparture: Double
    private var serial = 0

    /// Seconds between wake pairs from a heavy aircraft (about 170 to 240 m of track at heavy approach speeds).
    public static let wakeInterval = 4.0
    /// Along-runway distance (m) at which a departure is handed from the tower to departure control. The same
    /// distance ends ownship's climb out in `OwnshipTracker`.
    public static let departureHandoffDistance = 3_000.0
    /// Radius (m) of the orbit an arrival flies while held at the approach fix.
    public static let holdRadius = 1_200.0
    /// Types flown as traffic: the civil fleet, from the 1 kg trainer to the 4.5 t jet.
    public static let defaultFleet: [AircraftConfig] = [.sf1Trainer, .sf2Cruiser, .sf3Twin, .sf5Jet]

    public init(runway: TrafficRunway, leftTraffic: Bool = false, seed: UInt64 = 0x7A11_F1C0_0D15_EA5E,
                schedule: TrafficSchedule = TrafficSchedule(), fleet: [AircraftConfig] = TrafficSystem.defaultFleet) {
        self.runway = runway
        self.pattern = TrafficPatternGeometry(leftTraffic: leftTraffic)
        self.schedule = schedule
        self.fleet = fleet.isEmpty ? TrafficSystem.defaultFleet : fleet
        self.density = ISA.state(geometricAltitude: runway.elevation).density
        self.rng = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        self.nextArrival = 20
        self.nextDeparture = 45
    }

    /// Snapshots of every aircraft in the system, in spawn order.
    public var snapshots: [TrafficSnapshot] { aircraft.map { snapshot(of: $0) } }

    /// The controller's view of one aircraft.
    public func snapshot(of a: TrafficAircraft) -> TrafficSnapshot {
        let local = runway.local(a.position)
        let touchdown = runway.ned(along: pattern.touchdownAlong, right: 0, up: 0)
        let dn = touchdown.x - a.position.x
        let de = touchdown.y - a.position.y
        let dd = touchdown.z - a.position.z
        return TrafficSnapshot(id: a.id, callsign: a.callsign, typeName: a.config.name, kind: a.kind, phase: a.phase,
                               positionNED: a.position, heading: a.heading, speed: a.speed,
                               heightAboveRunway: local.z, alongRunway: local.x,
                               distanceToTouchdown: (dn * dn + de * de + dd * dd).squareRoot(),
                               isHeavy: TrafficPerformance.isHeavy(a.config),
                               clearedToLand: a.clearedToLand, clearedToTakeoff: a.clearedToTakeoff,
                               takeoffFits: departureFits(a.config), facility: a.facility,
                               holding: a.holding, vectored: a.vectorHeading != nil,
                               distanceToApproachFix: distanceToApproachFix(a.position))
    }

    /// The approach fix in runway coordinates (along, right, up). It is the downwind entry: arrivals are vectored
    /// to it, held around it, and released from it onto the pattern.
    public var approachFix: SIMD3<Double> {
        SIMD3(pattern.downwindStart, pattern.side * pattern.downwindOffset, pattern.patternAltitude)
    }

    /// Straight-line distance (m) from an NED position to the approach fix.
    public func distanceToApproachFix(_ ned: SIMD3<Double>) -> Double {
        let fix = runway.ned(along: approachFix.x, right: approachFix.y, up: approachFix.z)
        let d = fix - ned
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    /// Applies an approach control instruction to an arrival. Returns false when the aircraft is not in the system,
    /// is not an arrival still inbound, or the instruction does not fit its state.
    @discardableResult
    public mutating func apply(_ control: TrafficControl, to id: String) -> Bool {
        guard let index = aircraft.firstIndex(where: { $0.id == id }),
              aircraft[index].kind == .arrival, aircraft[index].phase == .inbound else { return false }
        switch control {
        case .vectorToFix:
            guard !aircraft[index].holding else { return false }
            let fix = runway.ned(along: approachFix.x, right: approachFix.y, up: approachFix.z)
            let dn = fix.x - aircraft[index].position.x
            let de = fix.y - aircraft[index].position.y
            aircraft[index].vectorHeading = atan2(de, dn)
        case .direct:
            aircraft[index].vectorHeading = nil
        case .hold:
            let local = runway.local(aircraft[index].position)
            aircraft[index].holding = true
            aircraft[index].vectorHeading = nil
            aircraft[index].holdBearing = atan2(local.y - approachFix.y, local.x - approachFix.x)
        case .release:
            aircraft[index].holding = false
        }
        return true
    }

    /// True when this type reaches rotation speed on this runway at the takeoff acceleration, with 150 m to spare.
    public func departureFits(_ config: AircraftConfig) -> Bool {
        let rotate = TrafficPerformance.speeds(config, density: density).rotate
        let distance = rotate * rotate / (2 * TrafficPerformance.groundAcceleration)
        return distance <= runway.length - 150
    }

    /// Wake pairs close enough to matter to ownship: younger than `maxAge` seconds and within `radius` metres.
    /// The model's vortices are infinite straight lines with no along-track decay, so distant pairs are culled here.
    public func wakesNear(_ ownship: SIMD3<Double>, radius: Double = 1_500, maxAge: Double = 90) -> [WakeVortexPair] {
        let limit = radius * radius
        return wakes.active.filter { p in
            let d = p.centerNED - ownship
            return p.age < maxAge && (d.x * d.x + d.y * d.y + d.z * d.z) < limit
        }
    }

    /// Returns and clears the events raised since the last call.
    public mutating func drainEvents() -> [TrafficEvent] {
        let out = pendingEvents
        pendingEvents.removeAll()
        return out
    }

    /// Issues a clearance. Returns false when the aircraft is not in the system or the clearance does not fit its phase.
    @discardableResult
    public mutating func issue(_ clearance: TrafficClearance, to id: String) -> Bool {
        guard let index = aircraft.firstIndex(where: { $0.id == id }) else { return false }
        switch clearance {
        case .land:
            guard aircraft[index].kind == .arrival, Self.canBeClearedToLand(aircraft[index].phase) else { return false }
            aircraft[index].clearedToLand = true
            return true
        case .takeoff:
            guard aircraft[index].kind == .departure, aircraft[index].phase == .holdShort,
                  departureFits(aircraft[index].config) else { return false }
            aircraft[index].clearedToTakeoff = true
            return true
        }
    }

    /// Advances the system by `dt` seconds: spawns due traffic, flies every aircraft, sheds wakes and
    /// removes finished aircraft. Steps longer than a second are ignored.
    public mutating func step(dt: Double) {
        guard dt.isFinite, dt > 0, dt <= 1 else { return }
        time += dt
        spawnDue()
        let rwy = runway
        let pat = pattern
        let rho = density
        for i in aircraft.indices {
            aircraft[i].age += dt
            if let event = Self.advance(&aircraft[i], dt: dt, runway: rwy, pattern: pat, density: rho) {
                pendingEvents.append(event)
            }
            aircraft[i].facility = Self.facility(current: aircraft[i].facility, phase: aircraft[i].phase,
                                                 alongRunway: rwy.local(aircraft[i].position).x)
        }
        shedWakes(dt: dt)
        wakes.step(dt: dt)
        aircraft.removeAll { $0.phase == .complete }
        if pendingEvents.count > 256 { pendingEvents.removeFirst(pendingEvents.count - 256) }
    }

    // MARK: - Spawning

    private mutating func spawnDue() {
        if time >= nextArrival {
            let u = nextUnit()
            nextArrival = time + schedule.meanArrivalInterval * (0.5 + u)
            if aircraft.count < schedule.maxAircraft { spawnArrival() }
        }
        if time >= nextDeparture {
            let u = nextUnit()
            nextDeparture = time + schedule.meanDepartureInterval * (0.5 + u)
            let queued = aircraft.contains { $0.kind == .departure && $0.phase == .holdShort }
            if !queued && aircraft.count < schedule.maxAircraft { spawnDeparture() }
        }
    }

    private mutating func spawnArrival() {
        let config = pickConfig()
        let speeds = TrafficPerformance.speeds(config, density: density)
        let start = runway.ned(along: schedule.arrivalSpawnDistance, right: pattern.side * pattern.downwindOffset,
                               up: pattern.patternAltitude + 150)
        let id = nextID()
        let callsign = nextCallsign()
        let arrival = TrafficAircraft(id: id, callsign: callsign, config: config, kind: .arrival, phase: .inbound,
                                      position: start, heading: runway.heading + Double.pi, speed: speeds.downwind)
        aircraft.append(arrival)
        pendingEvents.append(.spawned(id: id, kind: .arrival))
    }

    private mutating func spawnDeparture() {
        let config = pickConfig()
        let start = runway.ned(along: 0, right: 0, up: 0)
        let id = nextID()
        let callsign = nextCallsign()
        let departure = TrafficAircraft(id: id, callsign: callsign, config: config, kind: .departure, phase: .holdShort,
                                        position: start, heading: runway.heading, speed: 0)
        aircraft.append(departure)
        pendingEvents.append(.spawned(id: id, kind: .departure))
    }

    private mutating func pickConfig() -> AircraftConfig {
        let u = nextUnit()
        let index = min(fleet.count - 1, Int(u * Double(fleet.count)))
        return fleet[max(0, index)]
    }

    private mutating func nextCallsign() -> String {
        let u = nextUnit()
        return "SKY\(100 + Int(u * 900))"
    }

    private mutating func nextID() -> String {
        serial += 1
        return "T\(serial)"
    }

    /// xorshift64* in [0, 1).
    private mutating func nextUnit() -> Double {
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        let r = rng &* 0x2545_F491_4F6C_DD1D
        return Double(r >> 11) / Double(1 << 53)
    }

    // MARK: - Wakes

    private mutating func shedWakes(dt: Double) {
        let rho = density
        for i in aircraft.indices {
            let a = aircraft[i]
            guard Self.isAirborne(a.phase), TrafficPerformance.isHeavy(a.config) else { continue }
            aircraft[i].sinceWake += dt
            guard aircraft[i].sinceWake >= Self.wakeInterval else { continue }
            aircraft[i].sinceWake = 0
            wakes.emit(WakeVortexPair.generated(by: a.config, tas: a.speed, density: rho,
                                                centerNED: a.position, headingRad: a.heading))
        }
    }

    // MARK: - Facilities

    /// The controller that has an aircraft in `phase`, given the one that had it before. Inbound aircraft are with
    /// approach. Ownship coming back inbound after its climb out stays with departure, so the change is not
    /// repeated. A departure goes to departure control at `departureHandoffDistance` along the runway. Once an
    /// aircraft is on the pattern or the runway, the tower has it.
    public static func facility(current: TrafficFacility, phase: TrafficPhase, alongRunway: Double) -> TrafficFacility {
        switch phase {
        case .inbound:
            return current == .approach ? .approach : .departure
        case .downwind, .base, .extended, .final, .landing, .holdShort, .takeoffRoll:
            return .tower
        case .departing:
            return (current == .departure || alongRunway >= departureHandoffDistance) ? .departure : .tower
        case .complete:
            return current
        }
    }

    // MARK: - Flight

    private static func canBeClearedToLand(_ phase: TrafficPhase) -> Bool {
        switch phase {
        case .inbound, .downwind, .base, .extended, .final: return true
        case .landing, .holdShort, .takeoffRoll, .departing, .complete: return false
        }
    }

    static func isAirborne(_ phase: TrafficPhase) -> Bool {
        switch phase {
        case .inbound, .downwind, .base, .extended, .final, .departing: return true
        case .landing, .holdShort, .takeoffRoll, .complete: return false
        }
    }

    /// Advances one aircraft. Returns the event raised by a phase change, if any.
    private static func advance(_ a: inout TrafficAircraft, dt: Double, runway: TrafficRunway,
                                pattern: TrafficPatternGeometry, density: Double) -> TrafficEvent? {
        let speeds = TrafficPerformance.speeds(a.config, density: density)
        switch a.phase {
        case .inbound, .downwind, .base, .extended, .final:
            return advanceArrival(&a, dt: dt, runway: runway, pattern: pattern, speeds: speeds)
        case .landing:
            return rollOut(&a, dt: dt, runway: runway)
        case .holdShort:
            a.speed = 0
            if a.clearedToTakeoff { a.phase = .takeoffRoll }
            return nil
        case .takeoffRoll:
            a.speed += TrafficPerformance.groundAcceleration * dt
            let along = runway.local(a.position).x + a.speed * dt
            a.position = runway.ned(along: along, right: 0, up: 0)
            a.heading = runway.heading
            guard a.speed >= speeds.rotate else { return nil }
            a.phase = .departing
            a.routeIndex = 0
            return .tookOff(id: a.id)
        case .departing:
            return advanceDeparture(&a, dt: dt, runway: runway, pattern: pattern, speeds: speeds)
        case .complete:
            return nil
        }
    }

    private static func advanceArrival(_ a: inout TrafficAircraft, dt: Double, runway: TrafficRunway,
                                       pattern: TrafficPatternGeometry, speeds: TrafficPerformance.Speeds) -> TrafficEvent? {
        let target = (a.phase == .base || a.phase == .final) ? speeds.approach : speeds.downwind
        let change = TrafficPerformance.speedChangeRate * dt
        a.speed += max(-change, min(change, target - a.speed))
        if a.phase == .inbound, a.holding || a.vectorHeading != nil {
            flyControlled(&a, dt: dt, runway: runway, pattern: pattern)
            return nil
        }
        let waypoint = pattern.waypoint(for: a.phase)
        let climb = TrafficPerformance.maxClimbRate(a.config)
        let reached = guide(&a, toward: waypoint, runway: runway, dt: dt, climb: climb)
        switch a.phase {
        case .inbound:
            if reached { a.phase = .downwind }
            return nil
        case .downwind:
            if reached { a.phase = .base }
            return nil
        case .base:
            guard reached else { return nil }
            if a.clearedToLand {
                a.phase = .final
                return nil
            }
            a.phase = .extended
            return .extended(id: a.id)
        case .extended:
            if reached { a.phase = .downwind }
            return nil
        case .final:
            let local = runway.local(a.position)
            guard local.z <= 0.5 || local.x >= pattern.touchdownAlong + 300 else { return nil }
            a.position = runway.ned(along: local.x, right: local.y, up: 0)
            a.phase = .landing
            return .touchedDown(id: a.id)
        case .landing, .holdShort, .takeoffRoll, .departing, .complete:
            return nil
        }
    }

    /// Flies an arrival that approach control has vectored or held. A hold is an orbit of `holdRadius` around the
    /// approach fix. A vector is a line on the heading given, flown by aiming at a point 3 km ahead on it.
    private static func flyControlled(_ a: inout TrafficAircraft, dt: Double, runway: TrafficRunway,
                                      pattern: TrafficPatternGeometry) {
        let climb = TrafficPerformance.maxClimbRate(a.config)
        if a.holding {
            a.holdBearing += a.speed / Self.holdRadius * dt
            let fix = SIMD3(pattern.downwindStart, pattern.side * pattern.downwindOffset, pattern.patternAltitude)
            let point = SIMD3(fix.x + Self.holdRadius * cos(a.holdBearing),
                              fix.y + Self.holdRadius * sin(a.holdBearing), fix.z)
            _ = guide(&a, toward: point, runway: runway, dt: dt, climb: climb)
            return
        }
        guard let heading = a.vectorHeading else { return }
        let ahead = a.position + SIMD3(cos(heading), sin(heading), 0) * 3_000
        let local = runway.local(ahead)
        _ = guide(&a, toward: SIMD3(local.x, local.y, pattern.patternAltitude), runway: runway, dt: dt, climb: climb)
    }

    private static func advanceDeparture(_ a: inout TrafficAircraft, dt: Double, runway: TrafficRunway,
                                         pattern: TrafficPatternGeometry, speeds: TrafficPerformance.Speeds) -> TrafficEvent? {
        let change = TrafficPerformance.speedChangeRate * dt
        a.speed += max(-change, min(change, speeds.climb - a.speed))
        guard a.routeIndex < pattern.departureRoute.count else {
            a.phase = .complete
            return .completed(id: a.id, kind: a.kind)
        }
        let waypoint = pattern.departureRoute[a.routeIndex]
        let climb = TrafficPerformance.maxClimbRate(a.config)
        guard guide(&a, toward: waypoint, runway: runway, dt: dt, climb: climb) else { return nil }
        a.routeIndex += 1
        guard a.routeIndex < pattern.departureRoute.count else {
            a.phase = .complete
            return .completed(id: a.id, kind: a.kind)
        }
        return nil
    }

    private static func rollOut(_ a: inout TrafficAircraft, dt: Double, runway: TrafficRunway) -> TrafficEvent? {
        a.speed = max(0, a.speed - TrafficPerformance.groundAcceleration * dt)
        let local = runway.local(a.position)
        a.position = runway.ned(along: local.x + a.speed * dt, right: local.y, up: 0)
        a.heading = runway.heading
        guard a.speed <= 0.5 else { return nil }
        a.phase = .complete
        return .completed(id: a.id, kind: a.kind)
    }

    /// One guidance step toward a runway-frame waypoint: turn at the fixed radius, and climb or descend so
    /// the waypoint altitude is reached on arrival. Returns true once inside the reach radius.
    private static func guide(_ a: inout TrafficAircraft, toward waypoint: SIMD3<Double>, runway: TrafficRunway,
                              dt: Double, climb: Double) -> Bool {
        let target = runway.ned(along: waypoint.x, right: waypoint.y, up: 0)
        let dn = target.x - a.position.x
        let de = target.y - a.position.y
        let horizontal = (dn * dn + de * de).squareRoot()
        let speed = a.speed
        let omega = TrafficPerformance.turnRate(speed: speed)
        let reach = max(150, 0.8 * TrafficPerformance.turnRadius)
        a.heading = TrafficPerformance.turn(from: a.heading, toward: atan2(de, dn), rate: omega, dt: dt)
        let up = -a.position.z - runway.elevation
        let timeToGo = max(horizontal / max(speed, 1), 1)
        let rate = max(-TrafficPerformance.maxDescentRate, min(climb, (waypoint.z - up) / timeToGo))
        a.position.z = -(runway.elevation + up + rate * dt)
        a.position.x += speed * cos(a.heading) * dt
        a.position.y += speed * sin(a.heading) * dt
        return horizontal < reach
    }
}
