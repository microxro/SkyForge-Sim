/// Frame timestamps for exporting a replay clip. Encoding is left to the caller
/// (AVFoundation or ReplayKit); this type only decides which replay times to render.
public struct ClipExportPlan: Sendable, Equatable {
    public let startTime: Double
    public let endTime: Double
    public let frameRate: Int

    public init(startTime: Double, endTime: Double, frameRate: Int) {
        self.startTime = startTime
        self.endTime = endTime
        self.frameRate = max(1, frameRate)
    }

    public var duration: Double { max(0, endTime - startTime) }

    /// One time per frame, end exclusive: `[start, start + 1/fps, ...]`.
    public var frameTimes: [Double] {
        // An infinite end time would make the frame count overflow Int (a trap), so it renders nothing.
        guard duration.isFinite else { return [] }
        let count = Int((duration * Double(frameRate)).rounded(.down))
        guard count > 0 else { return [] }
        let fps = Double(frameRate)
        return (0..<count).map { startTime + Double($0) / fps }
    }

    /// The same plan restricted to the replay's recorded span.
    public func clamped(to replay: FlightReplay) -> ClipExportPlan {
        ClipExportPlan(
            startTime: max(startTime, replay.startTime),
            endTime: min(endTime, replay.endTime),
            frameRate: frameRate
        )
    }
}
