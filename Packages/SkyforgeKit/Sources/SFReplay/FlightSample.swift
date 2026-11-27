/// One recorded state of an aircraft.
/// `position` is local east-north-up metres. Body forward is +x, so a level
/// aircraft heading east has identity orientation.
public struct FlightSample: Sendable, Equatable {
    /// Seconds on the simulation clock.
    public var time: Double
    public var position: Vec3
    public var orientation: Quat
    /// True airspeed in metres per second.
    public var airspeed: Double

    public init(time: Double, position: Vec3, orientation: Quat, airspeed: Double) {
        self.time = time
        self.position = position
        self.orientation = orientation
        self.airspeed = airspeed
    }
}
