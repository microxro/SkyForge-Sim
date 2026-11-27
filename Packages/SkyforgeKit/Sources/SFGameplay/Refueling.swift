// SKYFORGE — Apache-2.0
// Aerial refueling: where the boom or drogue sits behind a tanker, when a receiver is in the envelope and
// when the contact is stable enough for fuel to flow. The tanker itself is an ordinary AI aircraft on a
// racetrack route, so this file models only the hookup. Pure and deterministic. NED axes: x north, y east,
// z down. Body axes for an aircraft: x forward, y right, z down.
import Foundation
import SFMath

public enum RefuelMethod: String, Sendable, Codable, CaseIterable {
    case boom
    case probeAndDrogue

    public var displayName: String {
        switch self {
        case .boom: return "Flying boom"
        case .probeAndDrogue: return "Probe and drogue"
        }
    }
}

public enum RefuelContact: Sendable, Equatable {
    /// Outside the envelope around the boom or drogue.
    case none
    /// Inside the envelope but not yet stable. Fuel does not flow.
    case inEnvelope
    /// Stable contact. Fuel flows at `Refueling.transferRate`.
    case connected
}

public enum Refueling {
    /// Boom or drogue anchor in the tanker's body frame, metres from the tanker's reference point.
    public static let boomAnchor = SIMD3<Double>(-30, 0, 3)
    /// Probe-and-drogue basket. Approximated as a fixed point behind the tanker; hose drag is not modelled.
    public static let drogueAnchor = SIMD3<Double>(-40, 0, 6)
    /// Radius of the stable contact zone, metres.
    public static let boomContactRadius = 3.0
    public static let drogueContactRadius = 3.5
    /// Relative speed to the tanker (m/s) above which a contact is not stable.
    public static let stableRelativeSpeed = 2.0
    /// Fuel transfer while connected, kg/s.
    public static let boomTransferRate = 9.0
    public static let drogueTransferRate = 5.0

    public static func transferRate(_ method: RefuelMethod) -> Double {
        switch method {
        case .boom: return boomTransferRate
        case .probeAndDrogue: return drogueTransferRate
        }
    }

    public static func contactRadius(_ method: RefuelMethod) -> Double {
        switch method {
        case .boom: return boomContactRadius
        case .probeAndDrogue: return drogueContactRadius
        }
    }

    /// NED point of the boom or drogue for a tanker in its current attitude.
    public static func anchorPoint(of tanker: AITarget, method: RefuelMethod) -> SIMD3<Double> {
        let local = method == .boom ? boomAnchor : drogueAnchor
        let heading = tanker.heading, path = tanker.flightPath
        let forward = SIMD3<Double>(cos(heading) * cos(path), sin(heading) * cos(path), -sin(path))
        let right = SIMD3<Double>(-sin(heading), cos(heading), 0)
        let down = cross(forward, right)
        return tanker.position + forward * local.x + right * local.y + down * local.z
    }

    /// Contact state for a receiver. A destroyed tanker or non-finite input is always `.none`.
    public static func contact(method: RefuelMethod, tanker: AITarget,
                               receiverPosition: SIMD3<Double>, receiverVelocity: SIMD3<Double>) -> RefuelContact {
        guard !tanker.destroyed, finite(tanker.position), finite(receiverPosition), finite(receiverVelocity) else {
            return .none
        }
        let anchor = anchorPoint(of: tanker, method: method)
        let distance = length(receiverPosition - anchor)
        let radius = contactRadius(method)
        guard distance <= 2 * radius else { return .none }
        let relative = length(receiverVelocity - tanker.velocity)
        if distance <= radius && relative <= stableRelativeSpeed { return .connected }
        return .inEnvelope
    }

    static func finite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
}
