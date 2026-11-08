// SKYFORGE — Apache-2.0
// CoreMotion gravity → SFInput.TiltMapper (iPhone/iPad). Device-motion gravity needs no
// permission prompt (unlike motion-activity data), so no usage string is required.
#if canImport(CoreMotion) && os(iOS)
import CoreMotion
import SFInput

@MainActor
public final class MotionTiltInput {
    private let manager = CMMotionManager()
    public var mapper: TiltMapper

    public init(orientation: TiltMapper.Orientation = .landscapeLeft) {
        mapper = TiltMapper(orientation: orientation)
    }

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates()
    }

    public func stop() { manager.stopDeviceMotionUpdates() }

    private var gravity: (x: Double, y: Double, z: Double)? {
        guard let g = manager.deviceMotion?.gravity else { return nil }
        return (x: g.x, y: g.y, z: g.z)
    }

    /// Sets the current hold as neutral.
    public func calibrate() { if let g = gravity { mapper.calibrate(gravity: g) } }

    public func poll() -> InputMapper.DeviceState {
        guard let g = gravity else { return InputMapper.DeviceState() }
        return mapper.deviceState(gravity: g)
    }
}
#endif
