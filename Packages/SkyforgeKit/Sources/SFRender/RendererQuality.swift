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
    /// and terrain SSE are stored on the renderer (`vegetationDensity`, `drawDistanceScale`, `terrainSSEScale`)
    /// for the scene builders to read.
    func applyQuality(_ plan: QualityPlan, base: Settings) {
        var s = base
        s.renderScale = max(0.5, base.renderScale * Float(plan.renderScale))
        s.cloudSteps = max(8, Int((Double(base.cloudSteps) * plan.cloudStepScale).rounded()))
        s.shadowMapSize = max(512, base.shadowMapSize / max(1, plan.shadowMapDivisor))
        s.vegetationDensity = max(0.1, base.vegetationDensity * Float(plan.vegetationDensity))
        s.drawDistanceScale = max(0.25, base.drawDistanceScale * Float(plan.drawDistanceScale))
        s.terrainSSEScale = max(1, base.terrainSSEScale * Float(plan.terrainSSEScale))
        apply(s)
    }

    /// Attach GPU timing to a frame's command buffer. Call before `commit()`.
    func recordFrameTiming(_ cmd: MTLCommandBuffer) {
        let t = frameTelemetry
        GPUTelemetry.attach(to: cmd) { ms in t.record(ms) }
    }
}

#endif
