// SKYFORGE — Apache-2.0
// Wiring for the adaptive quality ladder (SFPerf): GPU frame timing from the command buffer, and mapping a
// `QualityPlan` onto the renderer's own settings. The governor itself stays in SFPerf (pure Swift).
#if canImport(Metal)
import Foundation
import Metal
import SFPerf

/// Last GPU frame time, written on a Metal completion thread and read on the main thread.
public final class FrameTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var gpuMS: Double = 0
    public init() {}
    public func record(_ ms: Double) { lock.lock(); gpuMS = ms; lock.unlock() }
    /// Most recent completed GPU frame time (ms); 0 until the first frame completes.
    public var lastGPUMS: Double { lock.lock(); defer { lock.unlock() }; return gpuMS }
}

public extension WorldRenderer {
    /// Maps a governor plan onto the renderer's settings. `base` is the tier's own settings, so the plan
    /// scales what the device was already set to rather than replacing it. Vegetation density, draw distance
    /// and terrain SSE are not renderer settings yet; the plan carries them for the scene builders.
    func applyQuality(_ plan: QualityPlan, base: Settings) {
        var s = base
        s.renderScale = max(0.5, base.renderScale * Float(plan.renderScale))
        s.cloudSteps = max(8, Int((Double(base.cloudSteps) * plan.cloudStepScale).rounded()))
        s.shadowMapSize = max(512, base.shadowMapSize / max(1, plan.shadowMapDivisor))
        apply(s)
    }

    /// Attach GPU timing to a frame's command buffer. Call before `commit()`.
    func recordFrameTiming(_ cmd: MTLCommandBuffer) {
        let t = frameTelemetry
        GPUTelemetry.attach(to: cmd) { ms in t.record(ms) }
    }
}

#endif
