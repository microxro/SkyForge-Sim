// SKYFORGE — Apache-2.0
// Pure Swift (Linux-testable). Adaptive quality ladder (§11): the renderer applies a `QualityPlan`.
import Foundation

public enum PerfTier: Int, Sendable, CaseIterable {
    case low = 0, medium, high, ultra
}

/// Multipliers relative to the tier baseline, so the renderer maps them onto its own Settings.
public struct QualityPlan: Sendable, Equatable {
    public var renderScale: Double          // dynamic resolution (MetalFX or tone-map upscale)
    public var vegetationDensity: Double    // instance density
    public var drawDistanceScale: Double    // vegetation and buildings
    public var cloudStepScale: Double       // cloud raymarch steps
    public var terrainSSEScale: Double      // CDLOD screen-space-error threshold (>1 = coarser)
    public var shadowMapDivisor: Int        // 1 = full, 2 = half edge
    public var shadowCascadesDropped: Int
    public var oceanFFTLog2Drop: Int
    public var fpsCap: Int                  // 0 = no cap beyond the display's

    public static let full = QualityPlan(renderScale: 1, vegetationDensity: 1, drawDistanceScale: 1, cloudStepScale: 1,
                                         terrainSSEScale: 1, shadowMapDivisor: 1, shadowCascadesDropped: 0,
                                         oceanFFTLog2Drop: 0, fpsCap: 0)

    /// Continuous fields blend; integer steps switch at t ≥ 0.5, so a transition ramps instead of popping.
    public func blended(to o: QualityPlan, t: Double) -> QualityPlan {
        let k = min(1, max(0, t))
        func l(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return QualityPlan(renderScale: l(renderScale, o.renderScale), vegetationDensity: l(vegetationDensity, o.vegetationDensity),
                           drawDistanceScale: l(drawDistanceScale, o.drawDistanceScale), cloudStepScale: l(cloudStepScale, o.cloudStepScale),
                           terrainSSEScale: l(terrainSSEScale, o.terrainSSEScale),
                           shadowMapDivisor: k >= 0.5 ? o.shadowMapDivisor : shadowMapDivisor,
                           shadowCascadesDropped: k >= 0.5 ? o.shadowCascadesDropped : shadowCascadesDropped,
                           oceanFFTLog2Drop: k >= 0.5 ? o.oceanFFTLog2Drop : oceanFFTLog2Drop,
                           fpsCap: k >= 0.5 ? o.fpsCap : fpsCap)
    }
}

public enum QualityLadder {
    /// Steps in §11 order: resolution, density and distance, clouds, terrain SSE, shadows and ocean, frame cap.
    public static let plans: [QualityPlan] = [
        .full,
        QualityPlan(renderScale: 0.90, vegetationDensity: 1.00, drawDistanceScale: 1.00, cloudStepScale: 1.00, terrainSSEScale: 1.00,
                    shadowMapDivisor: 1, shadowCascadesDropped: 0, oceanFFTLog2Drop: 0, fpsCap: 0),
        QualityPlan(renderScale: 0.80, vegetationDensity: 0.80, drawDistanceScale: 1.00, cloudStepScale: 1.00, terrainSSEScale: 1.00,
                    shadowMapDivisor: 1, shadowCascadesDropped: 0, oceanFFTLog2Drop: 0, fpsCap: 0),
        QualityPlan(renderScale: 0.70, vegetationDensity: 0.65, drawDistanceScale: 0.85, cloudStepScale: 1.00, terrainSSEScale: 1.00,
                    shadowMapDivisor: 1, shadowCascadesDropped: 0, oceanFFTLog2Drop: 0, fpsCap: 0),
        QualityPlan(renderScale: 0.70, vegetationDensity: 0.65, drawDistanceScale: 0.85, cloudStepScale: 0.75, terrainSSEScale: 1.00,
                    shadowMapDivisor: 1, shadowCascadesDropped: 0, oceanFFTLog2Drop: 0, fpsCap: 0),
        QualityPlan(renderScale: 0.70, vegetationDensity: 0.65, drawDistanceScale: 0.85, cloudStepScale: 0.75, terrainSSEScale: 1.25,
                    shadowMapDivisor: 1, shadowCascadesDropped: 0, oceanFFTLog2Drop: 0, fpsCap: 0),
        QualityPlan(renderScale: 0.65, vegetationDensity: 0.55, drawDistanceScale: 0.80, cloudStepScale: 0.60, terrainSSEScale: 1.25,
                    shadowMapDivisor: 2, shadowCascadesDropped: 1, oceanFFTLog2Drop: 1, fpsCap: 0),
        QualityPlan(renderScale: 0.60, vegetationDensity: 0.50, drawDistanceScale: 0.70, cloudStepScale: 0.50, terrainSSEScale: 1.50,
                    shadowMapDivisor: 2, shadowCascadesDropped: 1, oceanFFTLog2Drop: 1, fpsCap: 30),
    ]
    public static var maxLevel: Int { plans.count - 1 }

    /// Level each tier starts at (low devices begin already trimmed).
    public static func startLevel(_ tier: PerfTier) -> Int {
        switch tier {
        case .low: 2
        case .medium: 1
        case .high, .ultra: 0
        }
    }

    /// Lowest level the thermal state forces.
    public static func thermalFloor(_ t: ThermalLevel) -> Int {
        switch t {
        case .nominal: 0
        case .fair: 1
        case .serious: 5
        case .critical: maxLevel
        }
    }
}

public struct GovernorSample: Sendable {
    public var gpuMS: Double
    public var cpuMS: Double
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool
    public init(gpuMS: Double, cpuMS: Double, thermal: ThermalLevel = .nominal, lowPowerMode: Bool = false) {
        self.gpuMS = gpuMS; self.cpuMS = cpuMS; self.thermal = thermal; self.lowPowerMode = lowPowerMode
    }
}

/// Steps the ladder down when frames run over budget and back up after sustained headroom.
/// A change needs `holdSeconds` (≥ 3 s per §11) since the previous one; recovery waits twice as long.
public struct QualityGovernor: Sendable {
    public let tier: PerfTier
    public var holdSeconds: Double
    public private(set) var level: Int
    public private(set) var targetMS: Double
    private var lastChange = -Double.infinity
    private var ema = 0.0
    private var seeded = false
    private var overSince: Double?
    private var underSince: Double?

    public init(tier: PerfTier, targetFPS: Int = 60, holdSeconds: Double = 3) {
        self.tier = tier
        self.holdSeconds = max(3, holdSeconds)
        self.level = QualityLadder.startLevel(tier)
        self.targetMS = RefreshPolicy.budgetMS(fps: targetFPS)
    }

    public var plan: QualityPlan { QualityLadder.plans[level] }

    public mutating func setTargetFPS(_ fps: Int) { targetMS = RefreshPolicy.budgetMS(fps: fps) }

    /// Feed one frame. Returns the new plan only when the level changed.
    public mutating func update(_ s: GovernorSample, now: Double) -> QualityPlan? {
        // Smooth the worse of GPU and CPU time so a single spike does not move the ladder.
        let cost = max(s.gpuMS, s.cpuMS)
        ema = seeded ? ema + 0.1 * (cost - ema) : cost
        seeded = true

        var floor = QualityLadder.thermalFloor(s.thermal)
        if s.lowPowerMode { floor = max(floor, 3) }
        let before = level

        if level < floor {
            // Thermal and low-power floors apply at once; they protect the device.
            level = floor
        } else if now - lastChange >= holdSeconds {
            if ema > targetMS * 1.0 {
                overSince = overSince ?? now
                underSince = nil
                if now - (overSince ?? now) >= holdSeconds * 0.5, level < QualityLadder.maxLevel {
                    level += 1
                    overSince = nil
                }
            } else if ema < targetMS * 0.75, level > max(floor, QualityLadder.startLevel(tier)) {
                underSince = underSince ?? now
                overSince = nil
                if now - (underSince ?? now) >= holdSeconds * 2 {
                    level -= 1
                    underSince = nil
                }
            } else {
                overSince = nil
                underSince = nil
            }
        }
        guard level != before else { return nil }
        lastChange = now
        overSince = nil
        underSince = nil
        return plan
    }
}
