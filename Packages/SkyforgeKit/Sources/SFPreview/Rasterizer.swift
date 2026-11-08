// SKYFORGE — Apache-2.0
// Parallel deferred rasteriser: projects a TriangleSoup into a G-buffer (depth, normal, albedo, material).
import Foundation
import SFMath

public struct PreviewCamera: Sendable {
    public var position: SIMD3<Double>
    public var forward: SIMD3<Double>
    public var right: SIMD3<Double>
    public var up: SIMD3<Double>
    public var horizontalFOV: Double

    public init(position: SIMD3<Double>, lookAt target: SIMD3<Double>, horizontalFOV: Double = 70 * .pi / 180) {
        self.position = position
        forward = normalize(target - position)
        right = normalize(cross(forward, SIMD3(0, 0, 1)))
        up = cross(right, forward)
        self.horizontalFOV = horizontalFOV
    }
}

public struct GBuffer: Sendable {
    public let width: Int, height: Int
    public var depth: [Float]          // camera-space z (forward distance); +inf = sky
    public var normal: [SIMD3<Float>]
    public var albedo: [SIMD3<Float>]
    public var material: [UInt8]
    public var field: [Float]          // interpolated FieldPattern weight (terrain only)

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        depth = [Float](repeating: .infinity, count: width * height)
        normal = [SIMD3<Float>](repeating: .zero, count: width * height)
        albedo = [SIMD3<Float>](repeating: .zero, count: width * height)
        material = [UInt8](repeating: 0, count: width * height)
        field = [Float](repeating: 0, count: width * height)
    }
}

/// Screen-space triangle after projection and near-plane clipping.
struct ScreenTri {
    var p0: SIMD3<Float>, p1: SIMD3<Float>, p2: SIMD3<Float>   // x, y pixels; z = 1/depth
    var n0: SIMD3<Float>, n1: SIMD3<Float>, n2: SIMD3<Float>
    var c0: SIMD3<Float>, c1: SIMD3<Float>, c2: SIMD3<Float>
    var f: SIMD3<Float> = .zero   // per-vertex field weights
    var material: UInt8
    var minY: Int32, maxY: Int32
}

enum Raster {
    static let near: Float = 0.3

    /// Projects triangles (camera-relative positions) with a pinhole camera into screen triangles.
    static func project(_ soup: TriangleSoup, cameraOffset: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>,
                        focal: Float, width: Int, height: Int) -> [ScreenTri] {
        var out: [ScreenTri] = []
        out.reserveCapacity(soup.triangleCount)
        let cx = Float(width) / 2, cy = Float(height) / 2
        let w = Float(width), h = Float(height)
        func toCam(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let d = p - cameraOffset
            return SIMD3((d * right).sum(), (d * up).sum(), (d * forward).sum())
        }
        func screen(_ c: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(cx + c.x / c.z * focal, cy - c.y / c.z * focal, 1 / c.z)
        }
        for t in 0..<soup.triangleCount {
            let a = toCam(soup.positions[3 * t]), b = toCam(soup.positions[3 * t + 1]), c = toCam(soup.positions[3 * t + 2])
            let na = soup.normals[3 * t], nb = soup.normals[3 * t + 1], nc = soup.normals[3 * t + 2]
            if a.z < near && b.z < near && c.z < near { continue }
            let mat = soup.material[t].rawValue
            let ca = soup.colour(t, 0), cb = soup.colour(t, 1), cc = soup.colour(t, 2)
            let fa = soup.field(t, 0), fb = soup.field(t, 1), fc = soup.field(t, 2)
            // Clip against the near plane (Sutherland–Hodgman on one plane).
            var verts: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float)] = []
            let input = [(a, na, ca, fa), (b, nb, cb, fb), (c, nc, cc, fc)]
            for i in 0..<3 {
                let (p, pn, pc, pf) = input[i], (q, qn, qc, qf) = input[(i + 1) % 3]
                let pin = p.z >= near, qin = q.z >= near
                if pin { verts.append((p, pn, pc, pf)) }
                if pin != qin {
                    let s = (near - p.z) / (q.z - p.z)
                    verts.append((p + (q - p) * s, pn + (qn - pn) * s, pc + (qc - pc) * s, pf + (qf - pf) * s))
                }
            }
            guard verts.count >= 3 else { continue }
            for k in 1..<(verts.count - 1) {
                let s0 = screen(verts[0].0), s1 = screen(verts[k].0), s2 = screen(verts[k + 1].0)
                let minX = min(s0.x, s1.x, s2.x), maxX = max(s0.x, s1.x, s2.x)
                let minYf = min(s0.y, s1.y, s2.y), maxYf = max(s0.y, s1.y, s2.y)
                if maxX < 0 || minX >= w || maxYf < 0 || minYf >= h { continue }
                let area = (s1.x - s0.x) * (s2.y - s0.y) - (s1.y - s0.y) * (s2.x - s0.x)
                if abs(area) < 1e-6 { continue }
                out.append(ScreenTri(p0: s0, p1: s1, p2: s2, n0: verts[0].1, n1: verts[k].1, n2: verts[k + 1].1,
                                     c0: verts[0].2, c1: verts[k].2, c2: verts[k + 1].2,
                                     f: SIMD3(verts[0].3, verts[k].3, verts[k + 1].3), material: mat,
                                     minY: Int32(max(0, Int(minYf.rounded(.down)))), maxY: Int32(min(height - 1, Int(maxYf.rounded(.up))))))
            }
        }
        return out
    }

    /// Rasterises screen triangles into the G-buffer using row bands in parallel.
    static func rasterize(_ tris: [ScreenTri], into g: inout GBuffer) {
        if tris.isEmpty { return }
        let width = g.width, height = g.height
        let bands = max(1, min(64, height / 16))
        let bandHeight = (height + bands - 1) / bands
        // Bin triangle indices per band.
        var bins = [[Int32]](repeating: [], count: bands)
        for (i, t) in tris.enumerated() {
            let b0 = Int(t.minY) / bandHeight, b1 = Int(t.maxY) / bandHeight
            for b in b0...min(b1, bands - 1) { bins[b].append(Int32(i)) }
        }
        g.depth.withUnsafeMutableBufferPointer { depth in
        g.normal.withUnsafeMutableBufferPointer { normal in
        g.albedo.withUnsafeMutableBufferPointer { albedo in
        g.material.withUnsafeMutableBufferPointer { material in
        g.field.withUnsafeMutableBufferPointer { field in
        tris.withUnsafeBufferPointer { tp in
            let dp = Shared(depth.baseAddress!), np = Shared(normal.baseAddress!)
            let ap = Shared(albedo.baseAddress!), mp = Shared(material.baseAddress!)
            let fp = Shared(field.baseAddress!)
            let tps = SharedRead(tp.baseAddress!)
            let binsCopy = bins
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let y0 = band * bandHeight, y1 = min(height, y0 + bandHeight)
                for ti in binsCopy[band] {
                    let t = tps[Int(ti)]
                    let x0f = min(t.p0.x, t.p1.x, t.p2.x), x1f = max(t.p0.x, t.p1.x, t.p2.x)
                    let xs = max(0, Int(x0f.rounded(.down))), xe = min(width - 1, Int(x1f.rounded(.up)))
                    let ys = max(y0, Int(t.minY)), ye = min(y1 - 1, Int(t.maxY))
                    if xs > xe || ys > ye { continue }
                    let area = (t.p1.x - t.p0.x) * (t.p2.y - t.p0.y) - (t.p1.y - t.p0.y) * (t.p2.x - t.p0.x)
                    let invArea = 1 / area
                    let isDecal = t.material == Material.road.rawValue
                    for y in ys...ye {
                        let py = Float(y) + 0.5
                        let row = y * width
                        for x in xs...xe {
                            let px = Float(x) + 0.5
                            var w0 = (t.p1.x - px) * (t.p2.y - py) - (t.p1.y - py) * (t.p2.x - px)
                            var w1 = (t.p2.x - px) * (t.p0.y - py) - (t.p2.y - py) * (t.p0.x - px)
                            var w2 = (t.p0.x - px) * (t.p1.y - py) - (t.p0.y - py) * (t.p1.x - px)
                            w0 *= invArea; w1 *= invArea; w2 *= invArea
                            if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                            let invZ = w0 * t.p0.z + w1 * t.p1.z + w2 * t.p2.z
                            var z = 1 / invZ
                            if isDecal { z -= max(0.05, z * 0.0015) }
                            let idx = row + x
                            if z >= dp[idx] { continue }
                            dp[idx] = z
                            // Perspective-correct normal interpolation.
                            let n = (t.n0 * (w0 * t.p0.z) + t.n1 * (w1 * t.p1.z) + t.n2 * (w2 * t.p2.z)) / invZ
                            np[idx] = n
                            ap[idx] = (t.c0 * (w0 * t.p0.z) + t.c1 * (w1 * t.p1.z) + t.c2 * (w2 * t.p2.z)) / invZ
                            mp[idx] = t.material
                            fp[idx] = t.f == .zero ? 0 : (t.f.x * (w0 * t.p0.z) + t.f.y * (w1 * t.p1.z) + t.f.z * (w2 * t.p2.z)) / invZ
                        }
                    }
                }
            }
        }}}}}}
    }
}

/// Orthographic sun shadow map.
public struct ShadowMap: Sendable {
    public let size: Int
    let centre: SIMD3<Float>
    let right: SIMD3<Float>, up: SIMD3<Float>, dir: SIMD3<Float>   // dir = direction light travels
    let halfExtent: Float
    var depth: [Float]

    init(soup: TriangleSoup, sunDirection toSun: SIMD3<Float>, centre: SIMD3<Float>, halfExtent: Float, size: Int) {
        self.size = size; self.centre = centre; self.halfExtent = halfExtent
        dir = -simd_normalize(toSun)
        var r = SIMD3<Float>(dir.y, -dir.x, 0)
        if (r * r).sum() < 1e-6 { r = SIMD3(1, 0, 0) }
        right = simd_normalize(r)
        up = simd_cross(right, dir)
        depth = [Float](repeating: .infinity, count: size * size)
        // Rasterise depth along the light direction (painter-free z-buffer).
        let scale = Float(size) / (2 * halfExtent)
        var tris: [ScreenTri] = []
        tris.reserveCapacity(soup.triangleCount)
        for t in 0..<soup.triangleCount {
            if soup.material[t] == .water || soup.material[t] == .road { continue }
            var s = [SIMD3<Float>](repeating: .zero, count: 3)
            for k in 0..<3 {
                let d = soup.positions[3 * t + k] - centre
                s[k] = SIMD3(Float(size) / 2 + (d * right).sum() * scale, Float(size) / 2 - (d * up).sum() * scale, (d * dir).sum())
            }
            let minYf = min(s[0].y, s[1].y, s[2].y), maxYf = max(s[0].y, s[1].y, s[2].y)
            let minX = min(s[0].x, s[1].x, s[2].x), maxX = max(s[0].x, s[1].x, s[2].x)
            if maxX < 0 || minX >= Float(size) || maxYf < 0 || minYf >= Float(size) { continue }
            tris.append(ScreenTri(p0: s[0], p1: s[1], p2: s[2], n0: .zero, n1: .zero, n2: .zero, c0: .zero, c1: .zero, c2: .zero, material: 0,
                                  minY: Int32(max(0, Int(minYf.rounded(.down)))), maxY: Int32(min(size - 1, Int(maxYf.rounded(.up))))))
        }
        let n = size
        let bands = 64, bandHeight = (n + bands - 1) / bands
        var bins = [[Int32]](repeating: [], count: bands)
        for (i, t) in tris.enumerated() {
            for b in (Int(t.minY) / bandHeight)...min(Int(t.maxY) / bandHeight, bands - 1) { bins[b].append(Int32(i)) }
        }
        let binsCopy = bins
        if tris.isEmpty { return }
        depth.withUnsafeMutableBufferPointer { dpb in
            let dp = Shared(dpb.baseAddress!)
            tris.withUnsafeBufferPointer { tpb in
                let tp = SharedRead(tpb.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let y0 = band * bandHeight, y1 = min(n, y0 + bandHeight)
                    for ti in binsCopy[band] {
                        let t = tp[Int(ti)]
                        let xs = max(0, Int(min(t.p0.x, t.p1.x, t.p2.x).rounded(.down)))
                        let xe = min(n - 1, Int(max(t.p0.x, t.p1.x, t.p2.x).rounded(.up)))
                        let ys = max(y0, Int(t.minY)), ye = min(y1 - 1, Int(t.maxY))
                        if xs > xe || ys > ye { continue }
                        let area = (t.p1.x - t.p0.x) * (t.p2.y - t.p0.y) - (t.p1.y - t.p0.y) * (t.p2.x - t.p0.x)
                        if abs(area) < 1e-8 { continue }
                        let inv = 1 / area
                        for y in ys...ye {
                            let py = Float(y) + 0.5
                            for x in xs...xe {
                                let px = Float(x) + 0.5
                                let w0 = ((t.p1.x - px) * (t.p2.y - py) - (t.p1.y - py) * (t.p2.x - px)) * inv
                                let w1 = ((t.p2.x - px) * (t.p0.y - py) - (t.p2.y - py) * (t.p0.x - px)) * inv
                                let w2 = 1 - w0 - w1
                                if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                                let z = w0 * t.p0.z + w1 * t.p1.z + w2 * t.p2.z
                                let idx = y * n + x
                                if z < dp[idx] { dp[idx] = z }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 0 = fully shadowed, 1 = lit. 3x3 PCF with slope-scaled bias.
    func visibility(_ p: SIMD3<Float>, normalDotLight: Float) -> Float {
        let d = p - centre
        let scale = Float(size) / (2 * halfExtent)
        let sx = Float(size) / 2 + (d * right).sum() * scale
        let sy = Float(size) / 2 - (d * up).sum() * scale
        if sx < 1 || sy < 1 || sx >= Float(size - 2) || sy >= Float(size - 2) { return 1 }
        let z = (d * dir).sum()
        let texel = 2 * halfExtent / Float(size)
        // Slope-scaled bias: the depth error across a texel grows with tan(angle to the light), which
        // reaches ~10 for a 6° sun on flat ground (the old linear term left acne bands at sunrise).
        let ndl = max(0.05, normalDotLight)
        let tanT = (1 - ndl * ndl).squareRoot() / ndl
        let bias = texel * (1.2 + min(24, tanT * 1.6))
        var lit: Float = 0
        let ix = Int(sx), iy = Int(sy)
        for oy in -1...1 {
            for ox in -1...1 {
                lit += z - bias <= depth[(iy + oy) * size + ix + ox] ? 1 : 0
            }
        }
        return lit / 9
    }
}

@inline(__always) func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = (v * v).sum().squareRoot()
    return l > 0 ? v / l : v
}
@inline(__always) func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inline(__always) func fdot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }

/// Pointer wrapper for data-parallel loops where each worker touches a disjoint index range.
struct Shared<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
    init(_ b: UnsafeMutablePointer<T>) { base = b }
    @inline(__always) subscript(i: Int) -> T {
        get { base[i] }
        nonmutating set { base[i] = newValue }
    }
}
struct SharedRead<T>: @unchecked Sendable {
    let base: UnsafePointer<T>
    init(_ b: UnsafePointer<T>) { base = b }
    @inline(__always) subscript(i: Int) -> T { base[i] }
}
