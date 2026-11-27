import Foundation

/// Input for one frame of the free camera. Axes run from -1 to 1.
public struct FreeCameraInput: Sendable, Equatable {
    public var forward: Double
    public var strafe: Double
    public var vertical: Double
    public var lookYaw: Double
    public var lookPitch: Double
    public var boost: Bool

    public init(forward: Double = 0, strafe: Double = 0, vertical: Double = 0,
                lookYaw: Double = 0, lookPitch: Double = 0, boost: Bool = false) {
        self.forward = forward
        self.strafe = strafe
        self.vertical = vertical
        self.lookYaw = lookYaw
        self.lookPitch = lookPitch
        self.boost = boost
    }
}

/// Free-flying camera for photo mode.
public struct FreeCamera: Sendable, Equatable {
    public static let maxPitch = 1.5
    public static let fovRange: ClosedRange<Double> = 10...90
    public static let baseSpeed = 20.0
    public static let lookRate = 1.5

    public var position: Vec3
    public var yaw: Double
    public var pitch: Double
    public var fovDegrees: Double

    public init(position: Vec3 = .zero, yaw: Double = 0, pitch: Double = 0, fovDegrees: Double = 60) {
        self.position = position
        self.yaw = yaw
        self.pitch = max(-Self.maxPitch, min(Self.maxPitch, pitch))
        self.fovDegrees = max(Self.fovRange.lowerBound, min(Self.fovRange.upperBound, fovDegrees))
    }

    public var orientation: Quat {
        Quat.yawPitch(yaw: yaw, pitch: pitch)
    }

    /// Moves and turns the camera. `dt` is seconds.
    public mutating func step(_ input: FreeCameraInput, dt: Double) {
        guard dt > 0, dt.isFinite else { return }
        let speed = Self.baseSpeed * (input.boost ? 5 : 1) * dt
        let look = Self.lookRate * dt

        let facing = orientation.rotate(Vec3(1, 0, 0))
        let flatRight = Vec3(sin(yaw), -cos(yaw), 0)
        position = position
            + facing * (input.forward * speed)
            + flatRight * (input.strafe * speed)
            + Vec3(0, 0, input.vertical * speed)

        yaw += input.lookYaw * look
        pitch = max(-Self.maxPitch, min(Self.maxPitch, pitch + input.lookPitch * look))
    }

    /// Zoom in photo mode. Clamped to `fovRange`.
    public mutating func zoom(by degrees: Double) {
        fovDegrees = max(Self.fovRange.lowerBound, min(Self.fovRange.upperBound, fovDegrees + degrees))
    }
}

/// Thin-lens depth of field.
public struct DepthOfField: Sendable, Equatable {
    public var enabled: Bool
    /// Metres.
    public var focusDistance: Double
    /// Metres (0.05 is a typical 50 mm lens).
    public var focalLength: Double
    public var fNumber: Double

    public init(enabled: Bool = true, focusDistance: Double = 10, focalLength: Double = 0.05, fNumber: Double = 2.8) {
        self.enabled = enabled
        self.focusDistance = max(focalLength * 1.01, focusDistance)
        self.focalLength = max(0.001, focalLength)
        self.fNumber = max(0.5, fNumber)
    }

    /// Blur-circle diameter on the image plane, in metres, for a point at `objectDistance`.
    /// Zero when disabled or in focus.
    public func circleOfConfusion(objectDistance d: Double) -> Double {
        guard enabled, d > 0 else { return 0 }
        let aperture = focalLength / fNumber
        let s = focusDistance
        return aperture * abs(d - s) / d * focalLength / (s - focalLength)
    }
}

/// Colour grading applied to the final photo. Neutral is the identity.
public struct ImageGrade: Sendable, Equatable {
    /// Stops, -2...2.
    public var exposureEV: Double
    /// 1 is neutral.
    public var saturation: Double
    /// 1 is neutral.
    public var contrast: Double
    /// -1 cool, 1 warm.
    public var warmth: Double

    public init(exposureEV: Double = 0, saturation: Double = 1, contrast: Double = 1, warmth: Double = 0) {
        self.exposureEV = exposureEV
        self.saturation = saturation
        self.contrast = contrast
        self.warmth = warmth
    }

    public static let neutral = ImageGrade()

    public var clamped: ImageGrade {
        ImageGrade(
            exposureEV: max(-2, min(2, exposureEV)),
            saturation: max(0, min(2, saturation)),
            contrast: max(0, min(2, contrast)),
            warmth: max(-1, min(1, warmth))
        )
    }
}

public enum PhotoFilter: String, Sendable, CaseIterable {
    case none
    case vivid
    case mono
    case warm
    case dusk

    public var grade: ImageGrade {
        switch self {
        case .none: .neutral
        case .vivid: ImageGrade(exposureEV: 0.1, saturation: 1.35, contrast: 1.15, warmth: 0)
        case .mono: ImageGrade(exposureEV: 0, saturation: 0, contrast: 1.2, warmth: 0)
        case .warm: ImageGrade(exposureEV: 0.05, saturation: 1.1, contrast: 1, warmth: 0.4)
        case .dusk: ImageGrade(exposureEV: -0.2, saturation: 1.2, contrast: 1.1, warmth: 0.6)
        }
    }
}

/// Time-of-day scrub helpers. This is an equinox, latitude-free approximation
/// for scrub UI only. The renderer's sun model stays authoritative.
public enum TimeOfDay {
    public static func wrapHour(_ hour: Double) -> Double {
        let r = hour.truncatingRemainder(dividingBy: 24)
        return r < 0 ? r + 24 : r
    }

    /// Solar elevation in degrees. 12 gives 90, 6 gives 0, 0 gives -90.
    public static func sunElevationDegrees(hour: Double) -> Double {
        let h = wrapHour(hour)
        return 90 * cos(2 * Double.pi * (h - 12) / 24)
    }

    public static func isDaylight(hour: Double) -> Bool {
        sunElevationDegrees(hour: hour) > 0
    }
}
