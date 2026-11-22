// SKYFORGE — Apache-2.0
// Round 5 (aa_shadows): CPU reference math for temporal anti-aliasing and 4-cascade stabilised sun shadows.
// Pure Swift (stdlib SIMD only), so it is testable on Linux. The MSL in AAShadowShaders.swift mirrors it.

import Foundation

/// Quality tiers for the AA and shadow features.
public enum AAShadowTier: Int, Sendable, CaseIterable {
    case low, medium, high, ultra

    /// low: FXAA-lite only; medium: TAA with 8-sample jitter; high/ultra: TAA with 16 samples.
    public var usesTAA: Bool { self != .low }
    public var jitterLength: Int { self == .ultra || self == .high ? 16 : (self == .medium ? 8 : 1) }
    /// Cascades drawn: low 2 (existing path), medium 3, high/ultra 4.
    public var cascadeCount: Int { self == .low ? 2 : (self == .medium ? 3 : 4) }
    public var shadowMapSize: Int { [1024, 2048, 2048, 4096][rawValue] }
    /// Bytes per shadow texel: ultra uses 16-bit depth so its 4-layer 4096² array is 128 MiB (32-bit would be 256 MiB).
    public var shadowDepthBytes: Int { self == .ultra ? 2 : 4 }
    /// Total shadow-array memory: cascades × size² × bytes. Budget: ≤ `AAShadowTier.shadowMemoryBudget` on every tier.
    public var shadowMemoryBytes: Int { cascadeCount * shadowMapSize * shadowMapSize * shadowDepthBytes }
    public static let shadowMemoryBudget = 128 * 1024 * 1024
    /// Maximum cascades any tier uses; the MSL arrays are sized for this, the runtime count is `cascadeCount`.
    public static let maxCascades = 4
    /// PCSS blocker search + variable penumbra only on high and ultra.
    public var usesPCSS: Bool { self.rawValue >= AAShadowTier.high.rawValue }
    /// Always >= 1 (the shader also guards against 0).
    public var pcfTaps: Int { max(1, [4, 9, 16, 24][rawValue]) }
    /// Fraction of the cascade (0…1) over which it cross-fades into the next.
    public var blendFraction: Float { self == .low ? 0 : 0.1 }
}

// MARK: - Jitter

public enum TAAJitter {
    /// Radical inverse of `index` (1-based) in `base`; the Halton low-discrepancy sequence, in [0, 1).
    public static func halton(_ index: Int, base: Int) -> Float {
        precondition(base >= 2)
        var i = max(0, index), f: Double = 1, r: Double = 0
        let b = Double(base)
        while i > 0 { f /= b; r += f * Double(i % base); i /= base }
        return Float(r)
    }

    /// Sub-pixel jitter in pixels, each component in (-0.5, 0.5), Halton(2,3), cycling through `length` samples.
    public static func pixelJitter(frame: Int, length: Int = 8) -> SIMD2<Float> {
        let n = max(1, length)
        let i = (((frame % n) + n) % n) + 1
        if n == 1 { return .zero }
        return SIMD2(halton(i, base: 2) - 0.5, halton(i, base: 3) - 0.5)
    }

    /// Clip-space offset to add to projection[2][0..1] (x, y) so the image shifts by `pixelJitter`.
    /// Metal NDC y is up while pixel y is down, hence the sign on y.
    public static func ndcOffset(pixelJitter j: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
        SIMD2(2 * j.x / Float(width), -2 * j.y / Float(height))
    }
}

// MARK: - History reset

/// Owns the TAA history validity. The resolve shader has no motion vectors: it reprojects with camera
/// matrices only, so moving objects (other aircraft, vehicles, animated foliage) ghost or smear and rely on
/// neighbourhood clipping alone. History must be explicitly reset (shader `TAAParams.p.z = 1`) whenever
/// camera-based reprojection is meaningless.
public struct TAAHistoryState: Sendable, Equatable {
    public enum ResetReason: Sendable, Equatable { case firstFrame, resize, cameraCut, teleport, tierChange, depthConventionChange }
    public private(set) var width = 0, height = 0
    public private(set) var hasHistory = false
    /// Camera jump (m) between frames beyond which reprojection is treated as a teleport.
    public var teleportDistance: Double = 500
    private var lastEye = SIMD3<Double>.zero
    public init() {}

    /// Call once per frame before the resolve. Returns the reset reason (history must be ignored, p.z = 1) or nil.
    /// Pass `cameraCut: true` on scripted cuts / view switches; resizes and teleports are detected here.
    public mutating func beginFrame(width w: Int, height h: Int, eye: SIMD3<Double>, cameraCut: Bool = false, tierChanged: Bool = false) -> ResetReason? {
        var reason: ResetReason?
        if !hasHistory { reason = .firstFrame }
        else if w != width || h != height { reason = .resize }
        else if tierChanged { reason = .tierChange }
        else if cameraCut { reason = .cameraCut }
        else {
            let d = eye - lastEye
            if (d * d).sum().squareRoot() > teleportDistance || !eye.x.isFinite || !eye.y.isFinite || !eye.z.isFinite { reason = .teleport }
        }
        width = w; height = h; lastEye = eye
        hasHistory = reason == nil
        // After a reset frame the freshly resolved image becomes valid history for the next frame.
        if reason != nil { hasHistory = true }
        return reason
    }

    /// Force the next frame to reset (e.g. device lost, history textures recreated).
    public mutating func invalidate() { hasHistory = false }
}

// MARK: - Colour and history rectification

public enum TAAMath {
    public static func rgbToYCoCg(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(0.25 * c.x + 0.5 * c.y + 0.25 * c.z,
              0.5 * c.x - 0.5 * c.z,
              -0.25 * c.x + 0.5 * c.y - 0.25 * c.z)
    }
    public static func yCoCgToRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z)
    }

    /// Variance clipping bounds (Salvi 2016): mean ± gamma·sigma of the 3×3 neighbourhood in YCoCg.
    public static func neighbourhoodBounds(_ samples: [SIMD3<Float>], gamma: Float = 1.25) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        guard !samples.isEmpty else { return (.zero, .zero) }
        var m1 = SIMD3<Float>.zero, m2 = SIMD3<Float>.zero
        for s in samples { m1 += s; m2 += s * s }
        let n = Float(samples.count)
        m1 /= n; m2 /= n
        let variance = m2 - m1 * m1
        let sigma = pointwiseMax(variance, SIMD3<Float>.zero).squareRoot()
        return (m1 - gamma * sigma, m1 + gamma * sigma)
    }

    /// Clip `history` toward `centre` until it lies inside the AABB (keeps hue, unlike per-channel clamp).
    public static func clipToAABB(history h: SIMD3<Float>, centre c: SIMD3<Float>, lo: SIMD3<Float>, hi: SIMD3<Float>) -> SIMD3<Float> {
        let e = (hi - lo) * 0.5 + SIMD3(repeating: 1e-5)
        let mid = (hi + lo) * 0.5
        let v = h - mid
        let q = SIMD3(abs(v.x) / e.x, abs(v.y) / e.y, abs(v.z) / e.z)
        let k = max(q.x, max(q.y, q.z))
        if k <= 1 { return h }
        _ = c
        return mid + v / k
    }

    /// History blend weight: lower (more current frame) when the history needed heavy clipping or left the screen.
    public static func blendWeight(base: Float = 0.1, clipDistance: Float, historyValid: Bool) -> Float {
        if !historyValid { return 1 }
        return min(1, base + min(0.4, clipDistance * 0.5))
    }
}

/// Column-major 4×4 matrix for the CPU reprojection reference (no simd dependency).
public struct AAMat4: Equatable, Sendable {
    public var m: [Float]   // 16, column-major: m[col*4 + row]
    public init(_ m: [Float]) { precondition(m.count == 16); self.m = m }
    public static let identity = AAMat4([1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
    public static func * (a: AAMat4, b: AAMat4) -> AAMat4 {
        var r = [Float](repeating: 0, count: 16)
        for c in 0..<4 { for rr in 0..<4 {
            var s: Float = 0
            for k in 0..<4 { s += a.m[k * 4 + rr] * b.m[c * 4 + k] }
            r[c * 4 + rr] = s
        } }
        return AAMat4(r)
    }
    public func apply(_ v: SIMD4<Float>) -> SIMD4<Float> {
        var o = SIMD4<Float>.zero
        for r in 0..<4 { o[r] = m[r] * v.x + m[4 + r] * v.y + m[8 + r] * v.z + m[12 + r] * v.w }
        return o
    }
}

public enum TAAReprojection {
    /// Velocity-free reprojection: unproject the current pixel with its depth, then project with the previous
    /// frame's view-projection. `inverseCurrent` and `previous` should both be jitter-free and use the same
    /// camera-relative origin (translate `previous` by the camera delta before calling, see the doc).
    /// Returns the previous-frame uv (0…1, y down) and whether it lies on screen.
    public static func previousUV(uv: SIMD2<Float>, depth: Float, inverseCurrent: AAMat4, previous: AAMat4) -> (uv: SIMD2<Float>, onScreen: Bool) {
        let ndc = SIMD4<Float>(uv.x * 2 - 1, 1 - uv.y * 2, depth, 1)
        var w = inverseCurrent.apply(ndc)
        w /= w.w
        let p = previous.apply(w)
        guard p.w > 1e-6 else { return (uv, false) }
        let q = SIMD2(p.x / p.w, p.y / p.w)
        let puv = SIMD2<Float>(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5)
        return (puv, puv.x >= 0 && puv.x <= 1 && puv.y >= 0 && puv.y <= 1)
    }
}

// MARK: - Cascades

public enum CascadeMath {
    /// Practical split scheme (Zhang 2006): lambda blends logarithmic and uniform splits.
    /// Returns the far edge (m) of each of `count` cascades between `near` and `far`.
    public static func splits(count: Int, near: Float, far: Float, lambda: Float = 0.75) -> [Float] {
        precondition(count >= 1 && near > 0 && far > near)
        return (1...count).map { i in
            let t = Float(i) / Float(count)
            let log = near * pow(far / near, t)
            let uni = near + (far - near) * t
            return lambda * log + (1 - lambda) * uni
        }
    }

    /// Rotation-invariant bounding-sphere radius of a frustum slice from `a` to `b` metres, in a camera with
    /// the given vertical FOV (radians) and aspect. Rounded up to 1/16 m so it does not wobble.
    public static func sliceRadius(near a: Float, far b: Float, verticalFOV: Float, aspect: Float) -> Float {
        let ty = tan(verticalFOV * 0.5), tx = ty * aspect
        let k = tx * tx + ty * ty
        // Sphere through the far corners, centred on the axis at distance c.
        let c = min(b, 0.5 * (a + b) * (1 + k))
        let fx = b * tx, fy = b * ty
        let r = (fx * fx + fy * fy + (b - c) * (b - c)).squareRoot()
        return (r * 16).rounded(.up) / 16
    }

    /// Snap a light-space coordinate (m) to the shadow texel grid so edges do not crawl. `world` is the
    /// absolute coordinate along the axis (Double, so far-from-origin positions stay exact).
    public static func snap(_ world: Double, texel: Double) -> Double {
        (world / texel).rounded(.down) * texel
    }

    /// Texel size (m) for a cascade of bounding radius `radius` and map edge `size`.
    public static func texelSize(radius: Float, size: Int) -> Float { 2 * radius / Float(size) }

    /// View-space depth (m along the camera forward axis) of a camera-relative point. Splits are depths, not
    /// radial distances, so selection must use this; radial distance picks too-far cascades at screen edges
    /// and makes cascade boundaries curve with the view.
    public static func viewDepth(rel: SIMD3<Float>, forward: SIMD3<Float>) -> Float {
        (rel * forward).sum()
    }

    /// Cascade index for view-space depth `d` and the far edges (only the first `count` are considered); nil beyond the last.
    public static func cascade(forViewDepth d: Float, splits: [Float], count: Int? = nil) -> Int? {
        let n = min(splits.count, count ?? splits.count)
        return splits.prefix(max(0, n)).firstIndex { d < $0 }
    }

    /// Cross-fade weight toward the next cascade: 0 well inside, ramps to 1 at the cascade's far edge over
    /// `blendFraction` of its depth span.
    public static func blendToNext(distance d: Float, index i: Int, splits: [Float], near: Float, blendFraction f: Float) -> Float {
        guard f > 0, i < splits.count - 1 else { return 0 }
        let start = i == 0 ? near : splits[i - 1]
        let span = splits[i] - start
        let begin = splits[i] - span * f
        return min(1, max(0, (d - begin) / max(1e-4, splits[i] - begin)))
    }

    /// PCSS penumbra width in world metres: (receiver − blocker) / blocker · lightSize, with the sun's
    /// angular diameter (~0.0093 rad) giving lightSize = tan(angle) per metre of separation.
    public static func penumbraWidth(blockerDepth: Float, receiverDepth: Float, sunAngularDiameter: Float = 0.0093) -> Float {
        max(0, receiverDepth - blockerDepth) * tan(sunAngularDiameter)
    }
}
