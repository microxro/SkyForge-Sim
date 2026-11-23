// SKYFORGE — Apache-2.0
// Radar: a forward scan volume, HUD contacts and a radar lock. Pure and deterministic: no wall clock, no
// randomness. Chaff clouds are passed in as plain world positions. NED axes throughout: x north, y east, z down.
import Foundation
import SFMath

public enum RadarMode: String, Sendable, Codable, CaseIterable {
    case off, standby, search, track

    public var displayName: String {
        switch self {
        case .off: return "OFF"
        case .standby: return "STBY"
        case .search: return "SRCH"
        case .track: return "TRK"
        }
    }
}

public struct RadarInput: Sendable, Equatable {
    public var cycleMode: Bool      // edge-triggered: off -> standby -> search -> track -> off
    public var lockNext: Bool       // edge-triggered: in track mode, lock or release the best contact
    public init(cycleMode: Bool = false, lockNext: Bool = false) {
        self.cycleMode = cycleMode; self.lockNext = lockNext
    }
}

public struct RadarContact: Sendable, Equatable, Identifiable {
    public var id: String
    public var role: TargetRole
    public var bearing: Double      // rad, relative to the nose, positive to the right, -pi...pi
    public var elevation: Double    // rad, relative to the nose, positive up
    public var range: Double        // m
    public var closureRate: Double  // m/s, positive when closing
    public var altitude: Double     // m, MSL (= -position.z)
    public var trackQuality: Double // 0...1
    public var locked: Bool         // true for the radar's locked target

    public init(id: String, role: TargetRole, bearing: Double, elevation: Double, range: Double,
                closureRate: Double, altitude: Double, trackQuality: Double, locked: Bool) {
        self.id = id; self.role = role; self.bearing = bearing; self.elevation = elevation
        self.range = range; self.closureRate = closureRate; self.altitude = altitude
        self.trackQuality = trackQuality; self.locked = locked
    }
}

public enum RadarEvent: Sendable, Equatable {
    case modeChanged(RadarMode)
    case lockAcquired(String)       // target id
    case lockLost(String)           // target id
}

public struct RadarSet: Sendable {
    public static let maxRange = 60_000.0          // m
    public static let scanHalfAzimuth = 60.0 * Double.pi / 180
    public static let scanHalfElevation = 25.0 * Double.pi / 180
    public static let trackHalfAngle = 10.0 * Double.pi / 180
    public static let lockTime = 2.0               // s inside the track cone to acquire
    public static let lockBreakTime = 0.5          // s of chaff blocking allowed before the lock breaks
    public static let chaffHalfAngle = 3.0 * Double.pi / 180
    public static let maxContacts = 8

    public private(set) var mode: RadarMode
    public private(set) var contacts: [RadarContact]
    public private(set) var lock: LockState

    private var previousCycle = false
    private var previousLockInput = false
    private var blockedTime = 0.0

    public init() {
        mode = .off
        contacts = []
        lock = .none
    }

    /// The locked target id, or nil (also nil while still acquiring).
    public var lockedTargetID: String? {
        if case .locked(let id) = lock { return id }
        return nil
    }

    /// One scanned target, with the extra data the lock logic needs.
    private struct Detection {
        var contact: RadarContact
        var offAxis: Double     // rad, angle between the nose and the line of sight
        var blocked: Bool
    }

    /// Steps the radar by dt. `chaffClouds` are world NED positions of active chaff clouds.
    public mutating func update(dt: Double, ownship: Ownship, targets: [AITarget], input: RadarInput,
                                chaffClouds: [SIMD3<Double>] = []) -> [RadarEvent] {
        var events: [RadarEvent] = []
        let step: Double = (dt.isFinite && dt > 0) ? dt : 0

        // Edge detection: remember the previous input, as WeaponSystem does.
        let cycleEdge: Bool = input.cycleMode && !previousCycle
        previousCycle = input.cycleMode
        let lockEdge: Bool = input.lockNext && !previousLockInput
        previousLockInput = input.lockNext

        if cycleEdge {
            mode = Self.nextMode(mode)
            events.append(.modeChanged(mode))
        }

        guard mode == .search || mode == .track else {
            contacts = []
            releaseLock(&events)
            return events
        }

        // The lock only exists in track mode.
        if mode != .track { releaseLock(&events) }

        let detections: [Detection] = Self.scan(ownship: ownship, targets: targets, chaff: chaffClouds)

        if mode == .track {
            updateLock(step: step, lockEdge: lockEdge, detections: detections, events: &events)
        }

        var lockedID: String? = nil
        if case .locked(let id) = lock { lockedID = id }
        var list: [RadarContact] = []
        for d in detections.prefix(Self.maxContacts) {
            var c: RadarContact = d.contact
            c.locked = (c.id == lockedID)
            list.append(c)
        }
        contacts = list
        return events
    }

    // MARK: Lock

    private mutating func releaseLock(_ events: inout [RadarEvent]) {
        if case .locked(let id) = lock { events.append(.lockLost(id)) }
        lock = .none
        blockedTime = 0
    }

    private mutating func updateLock(step: Double, lockEdge: Bool, detections: [Detection],
                                     events: inout [RadarEvent]) {
        if lockEdge {
            if case .locked = lock {
                releaseLock(&events)
                return
            }
            // Detections are sorted nearest first, so the first eligible one is the nearest.
            let pick: Detection? = detections.first { !$0.blocked && $0.offAxis <= Self.trackHalfAngle }
            if let p = pick {
                lock = .acquiring(targetID: p.contact.id, progress: 0)
                blockedTime = 0
            }
        }

        switch lock {
        case .none:
            break
        case .acquiring(let id, let progress):
            guard let d = detections.first(where: { $0.contact.id == id }),
                  !d.blocked, d.offAxis <= Self.trackHalfAngle else {
                lock = .none
                return
            }
            let next: Double = progress + step / Self.lockTime
            if next >= 1 {
                lock = .locked(targetID: id)
                blockedTime = 0
                events.append(.lockAcquired(id))
            } else {
                lock = .acquiring(targetID: id, progress: next)
            }
        case .locked(let id):
            guard let d = detections.first(where: { $0.contact.id == id }),
                  d.offAxis <= Self.trackHalfAngle else {
                releaseLock(&events)
                return
            }
            if d.blocked {
                blockedTime += step
                if blockedTime > Self.lockBreakTime { releaseLock(&events) }
            } else {
                blockedTime = 0
            }
        }
    }

    // MARK: Scan

    private static func nextMode(_ m: RadarMode) -> RadarMode {
        switch m {
        case .off: return .standby
        case .standby: return .search
        case .search: return .track
        case .track: return .off
        }
    }

    /// Live targets inside the scan volume, nearest first. Not capped: the lock logic needs the full list.
    private static func scan(ownship own: Ownship, targets: [AITarget], chaff: [SIMD3<Double>]) -> [Detection] {
        // Nose frame (NED). right = down x forward, so facing north the right-hand vector points east.
        // up = right x forward, which is -z (up) when the nose is level. A straight-up or straight-down nose
        // has no horizontal reference, so fall back to east for "right".
        let fl: Double = length(own.forward)
        let fwd: SIMD3<Double> = fl > 1e-9 ? own.forward / fl : SIMD3<Double>(1, 0, 0)
        var right: SIMD3<Double> = cross(SIMD3<Double>(0, 0, 1), fwd)
        let rl: Double = length(right)
        right = rl > 1e-9 ? right / rl : SIMD3<Double>(0, 1, 0)
        let up: SIMD3<Double> = cross(right, fwd)

        var out: [Detection] = []
        for t in targets where !t.destroyed {
            let d: SIMD3<Double> = t.position - own.position
            let range: Double = length(d)
            // Rejects NaN, infinity and a target sitting on the radar (no defined line of sight).
            guard range.isFinite, range > 1e-6, range <= maxRange else { continue }

            // Sign conventions: a = along the nose, b = to the right, c = up.
            //   bearing   = atan2(b, a): positive to the right of the nose, +-pi directly behind.
            //   elevation = atan2(c, hypot(a, b)): positive above the nose.
            let a: Double = dot(d, fwd)
            let b: Double = dot(d, right)
            let c: Double = dot(d, up)
            let bearing: Double = atan2(b, a)
            let elevation: Double = atan2(c, (a * a + b * b).squareRoot())
            guard bearing.isFinite, elevation.isFinite,
                  abs(bearing) <= scanHalfAzimuth, abs(elevation) <= scanHalfElevation else { continue }
            let offAxis: Double = atan2((b * b + c * c).squareRoot(), a)

            let los: SIMD3<Double> = d / range
            let closure: Double = -dot(los, t.velocity - own.velocity)

            var blocked = false
            for cloud in chaff {
                let cv: SIMD3<Double> = cloud - own.position
                let cr: Double = length(cv)
                guard cr.isFinite, cr > 1e-6, cr < range else { continue }
                let cosAngle: Double = min(1, max(-1, dot(cv / cr, los)))
                if acos(cosAngle) <= chaffHalfAngle { blocked = true; break }
            }

            var quality: Double = min(1, max(0, 1 - 0.5 * range / maxRange))
            if blocked { quality *= 0.5 }

            let contact = RadarContact(id: t.id, role: t.role, bearing: bearing, elevation: elevation,
                                       range: range, closureRate: closure, altitude: -t.position.z,
                                       trackQuality: quality, locked: false)
            out.append(Detection(contact: contact, offAxis: offAxis, blocked: blocked))
        }
        out.sort { $0.contact.range < $1.contact.range }
        return out
    }
}
