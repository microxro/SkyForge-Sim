import Foundation

public struct CameraPose: Sendable, Equatable {
    public var position: Vec3
    public var orientation: Quat

    public init(position: Vec3, orientation: Quat) {
        self.position = position
        self.orientation = orientation
    }
}

public enum CinematicMode: Sendable, Equatable {
    /// Behind and above the aircraft, looking at it.
    case chase(distance: Double, height: Double)
    /// Beside the aircraft at a fixed offset, looking at it.
    case flyby(lateralOffset: Double, height: Double)
    /// Fixed world position that tracks the aircraft.
    case tower(position: Vec3)
    /// Circles the aircraft at a fixed radius and height.
    case orbit(radius: Double, height: Double, radiansPerSecond: Double)
}

/// Places a camera relative to a replayed aircraft. Pure function of time.
public struct CinematicCamera: Sendable, Equatable {
    public var mode: CinematicMode

    public init(mode: CinematicMode) {
        self.mode = mode
    }

    public func pose(at time: Double, in replay: FlightReplay) -> CameraPose {
        let s = replay.sample(at: time)
        let forward = s.orientation.rotate(Vec3(1, 0, 0))
        let horizontal = Vec3(forward.x, forward.y, 0).normalized
        let heading = horizontal.length > 0 ? horizontal : Vec3(1, 0, 0)
        let right = heading.cross(Vec3(0, 0, 1))
        let target = s.position

        let position: Vec3
        switch mode {
        case let .chase(distance, height):
            position = target - heading * distance + Vec3(0, 0, height)
        case let .flyby(lateralOffset, height):
            position = target + right * lateralOffset + Vec3(0, 0, height)
        case let .tower(fixed):
            position = fixed
        case let .orbit(radius, height, rate):
            let a = rate * time
            position = target + Vec3(cos(a) * radius, sin(a) * radius, height)
        }
        return CameraPose(position: position, orientation: Self.lookAt(from: position, to: target))
    }

    /// Level-horizon orientation looking from `from` toward `to`.
    public static func lookAt(from: Vec3, to: Vec3) -> Quat {
        let d = to - from
        let len = d.length
        guard len > 0 else { return .identity }
        let yaw = atan2(d.y, d.x)
        let pitch = asin(max(-1, min(1, d.z / len)))
        return Quat.yawPitch(yaw: yaw, pitch: pitch)
    }
}
