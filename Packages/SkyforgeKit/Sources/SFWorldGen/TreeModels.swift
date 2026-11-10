// SKYFORGE — Apache-2.0
// Tree meshes for the instanced vegetation pass, unit height (z 0…1), built from irregular lobes:
// broadleaf crowns are clusters of displaced ellipsoids around a main mass, conifers are tiers of
// drooping, scalloped skirts or a bare trunk under a clumped top. Every leaf vertex carries a shade
// value (how much sky it sees: low inside and under the crown), which the shader uses for ambient
// occlusion; trunks are marked as bark. Pure Swift, deterministic.
import Foundation
import SFMath

public struct TreeVertex: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    /// −1 for bark, otherwise 0 (deep in the crown) … 1 (open to the sky).
    public var shade: Float
}

public enum TreeModels {
    /// Variants in instance order: two conifers (spruce, pine), three broadleaves (oak, tall, spreading).
    public static let variantCount = 5
    public static let coniferVariants = 2

    /// Deterministic variant for a tree at a position.
    public static func variant(conifer: Bool, x: Float, y: Float) -> Int {
        let h = Hash.int(Int((x * 3).rounded()), Int((y * 3).rounded()), seed: 0x7EE0_51)
        return conifer ? Int(h % 2) : 2 + Int(h % 3)
    }

    struct Builder {
        var out: [TreeVertex] = []
        var rng: SplitMix64

        mutating func tri(_ a: TreeVertex, _ b: TreeVertex, _ c: TreeVertex) { out.append(a); out.append(b); out.append(c) }

        /// Tapered trunk (bark).
        mutating func trunk(z0: Float, z1: Float, r0: Float, r1: Float, sides: Int) {
            for k in 0..<sides {
                let a0 = Float(k) / Float(sides) * 2 * .pi, a1 = Float(k + 1) / Float(sides) * 2 * .pi
                func v(_ a: Float, _ r: Float, _ z: Float) -> TreeVertex {
                    TreeVertex(position: SIMD3(r * cos(a), r * sin(a), z), normal: SIMD3(cos(a), sin(a), 0.1), shade: -1)
                }
                tri(v(a0, r0, z0), v(a1, r0, z0), v(a1, r1, z1))
                tri(v(a0, r0, z0), v(a1, r1, z1), v(a0, r1, z1))
            }
        }

        /// A displaced ellipsoid lobe. `crown`: centre and radius of the whole crown, for the shade value
        /// and for blending normals toward the crown's own (so a cluster shades as one mass).
        mutating func lobe(centre c: SIMD3<Float>, radii r: SIMD3<Float>, rings: Int, segments: Int, bump: Float,
                           crown: (centre: SIMD3<Float>, radius: Float, bottom: Float, top: Float), blend: Float = 0.5) {
            // Per-lobe bump field: a few random low-order waves over the sphere.
            let waves = (0..<4).map { _ in (SIMD3(Float(Hash.unit(rng.next())) * 2 - 1, Float(Hash.unit(rng.next())) * 2 - 1, Float(Hash.unit(rng.next())) * 2 - 1),
                                            Float(2 + Int(rng.next() % 3)), Float(Hash.unit(rng.next())) * 6.28) }
            func radial(_ d: SIMD3<Float>) -> Float {
                var s: Float = 0
                for (axis, freq, phase) in waves { s += sin((d * axis).sum() * freq * 1.7 + phase) }
                return 1 + bump * s / 4
            }
            func point(_ i: Int, _ j: Int) -> (p: SIMD3<Float>, d: SIMD3<Float>) {
                let th = Float(i) / Float(rings) * .pi, ph = Float(j % segments) / Float(segments) * 2 * .pi
                let d = SIMD3(sin(th) * cos(ph), sin(th) * sin(ph), cos(th))
                return (c + d * r * radial(d), d)
            }
            func vertex(_ i: Int, _ j: Int) -> TreeVertex {
                let (p, d) = point(i, j)
                // Normal: the ellipsoid's own, blended with the direction from the crown centre.
                var own = d / r
                own /= max(1e-6, (own * own).sum().squareRoot())
                var whole = p - crown.centre
                let wl = (whole * whole).sum().squareRoot()
                whole = wl > 1e-5 ? whole / wl : SIMD3(0, 0, 1)
                var n = own * (1 - blend) + whole * blend
                n /= max(1e-6, (n * n).sum().squareRoot())
                // Shade: outer and upper foliage sees the sky; the core and the underside do not.
                let outer = min(1, wl / max(1e-4, crown.radius))
                let height = (p.z - crown.bottom) / max(1e-4, crown.top - crown.bottom)
                let s = max(0, min(1, 0.15 + 0.55 * outer * outer + 0.45 * height)) * (0.6 + 0.4 * max(0, n.z * 0.5 + 0.5))
                return TreeVertex(position: p, normal: n, shade: max(0, min(1, s)))
            }
            for i in 0..<rings {
                for j in 0..<segments {
                    let a = vertex(i, j), b = vertex(i, j + 1), cc = vertex(i + 1, j + 1), e = vertex(i + 1, j)
                    if i > 0 { tri(a, e, b) }                 // (the pole row collapses one triangle)
                    if i < rings - 1 { tri(b, e, cc) }
                }
            }
        }

        /// A conifer tier: a cone skirt from an inner top ring down to a scalloped, drooping rim.
        mutating func skirt(zTop: Float, rTop: Float, zRim: Float, rRim: Float, points: Int, droop: Float, crownTop: Float, phase: Float) {
            let n = points * 2
            func rim(_ k: Int) -> SIMD3<Float> {
                let a = Float(k) / Float(n) * 2 * .pi + phase
                let tip = k % 2 == 0
                let rr = rRim * (tip ? 1 : 0.72) * (0.9 + 0.2 * Float(Hash.unit(Hash.int(k, Int(zTop * 1_000), seed: 0x5C1A))))
                return SIMD3(rr * cos(a), rr * sin(a), zRim - (tip ? droop : 0))
            }
            func top(_ k: Int) -> SIMD3<Float> {
                let a = Float(k) / Float(n) * 2 * .pi + phase
                return SIMD3(rTop * cos(a), rTop * sin(a), zTop)
            }
            func vert(_ p: SIMD3<Float>, _ nrm: SIMD3<Float>, rimPoint: Bool) -> TreeVertex {
                let height = p.z / max(1e-4, crownTop)
                let s = (rimPoint ? 0.75 : 0.30) * (0.55 + 0.45 * height)
                return TreeVertex(position: p, normal: nrm, shade: max(0, min(1, s + 0.2 * height)))
            }
            for k in 0..<n {
                let p0 = rim(k), p1 = rim(k + 1), t0 = top(k), t1 = top(k + 1)
                func nrm(_ p: SIMD3<Float>) -> SIMD3<Float> {
                    let h = SIMD3(p.x, p.y, 0)
                    let hl = max(1e-5, (h * h).sum().squareRoot())
                    let slope = (rRim - rTop) / max(1e-4, zTop - zRim)
                    let v = SIMD3(h.x / hl, h.y / hl, 1 / max(0.2, slope) * 0.6)
                    return v / (v * v).sum().squareRoot()
                }
                tri(vert(p0, nrm(p0), rimPoint: true), vert(p1, nrm(p1), rimPoint: true), vert(t1, nrm(t1 + SIMD3(t1.x, t1.y, 0) * 0.01), rimPoint: false))
                tri(vert(p0, nrm(p0), rimPoint: true), vert(t1, nrm(t1), rimPoint: false), vert(t0, nrm(t0), rimPoint: false))
            }
        }
    }

    /// Meshes per variant: `full` for near trees, `lod` (a fraction of the triangles, same silhouette) for
    /// the distance. Triangle lists (three vertices per triangle).
    public static func build() -> (full: [[TreeVertex]], lod: [[TreeVertex]]) {
        var full: [[TreeVertex]] = [], lod: [[TreeVertex]] = []
        for variant in 0..<variantCount {
            for isLOD in [false, true] {
                var b = Builder(rng: SplitMix64(seed: 0x7EE5_0000 + UInt64(variant)))
                let rings = isLOD ? 4 : 7, segs = isLOD ? 6 : 10
                switch variant {
                case 0:   // spruce: tiers of drooping skirts over a hidden trunk
                    if !isLOD { b.trunk(z0: -0.03, z1: 0.30, r0: 0.020, r1: 0.014, sides: 5) }
                    let tiers = isLOD ? 3 : 7
                    for t in 0..<tiers {
                        let f = Float(t) / Float(tiers)
                        let zRim = 0.10 + 0.80 * f, zTop = min(1.0, zRim + 0.90 / Float(tiers) * 1.9)
                        let rRim = 0.235 * (1 - f * 0.93) + 0.012
                        b.skirt(zTop: zTop, rTop: rRim * 0.18, zRim: zRim, rRim: rRim, points: isLOD ? 4 : 7, droop: 0.035 * (1 - f), crownTop: 1, phase: Float(t) * 0.9)
                    }
                case 1:   // pine: bare trunk, clumped flat-topped crown
                    b.trunk(z0: -0.03, z1: 0.62, r0: 0.024, r1: 0.016, sides: isLOD ? 4 : 6)
                    let crown = (centre: SIMD3<Float>(0, 0, 0.76), radius: Float(0.30), bottom: Float(0.52), top: Float(1.0))
                    b.lobe(centre: SIMD3(0, 0, 0.78), radii: SIMD3(0.22, 0.22, 0.20), rings: rings, segments: segs, bump: 0.22, crown: crown)
                    if !isLOD {
                        for (x, y, z, r) in [(0.17, 0.05, 0.68, 0.15), (-0.13, 0.13, 0.72, 0.14), (-0.06, -0.17, 0.66, 0.15), (0.05, 0.02, 0.90, 0.12)] as [(Float, Float, Float, Float)] {
                            b.lobe(centre: SIMD3(x, y, z), radii: SIMD3(r, r, r * 0.75), rings: 5, segments: 7, bump: 0.25, crown: crown)
                        }
                    }
                case 2:   // oak: a round mass with side and top lobes
                    b.trunk(z0: -0.03, z1: 0.34, r0: 0.034, r1: 0.026, sides: isLOD ? 4 : 6)
                    let crown = (centre: SIMD3<Float>(0, 0, 0.62), radius: Float(0.46), bottom: Float(0.22), top: Float(1.0))
                    b.lobe(centre: SIMD3(0, 0, 0.62), radii: SIMD3(0.36, 0.36, 0.33), rings: rings, segments: segs, bump: 0.16, crown: crown)
                    if !isLOD {
                        for k in 0..<6 {
                            let a = Float(k) / 6 * 2 * .pi + 0.4, rr = Float(0.19 + 0.05 * Hash.unit(b.rng.next()))
                            let d = Float(0.24 + 0.05 * Hash.unit(b.rng.next())), z = Float(0.50 + 0.22 * Hash.unit(b.rng.next()))
                            b.lobe(centre: SIMD3(d * cos(a), d * sin(a), z), radii: SIMD3(rr, rr, rr * 0.85), rings: 5, segments: 7, bump: 0.22, crown: crown)
                        }
                        b.lobe(centre: SIMD3(0.04, -0.03, 0.84), radii: SIMD3(0.20, 0.20, 0.16), rings: 5, segments: 7, bump: 0.22, crown: crown)
                    }
                case 3:   // tall broadleaf (elm, poplar, alder): a high narrow crown
                    b.trunk(z0: -0.03, z1: 0.30, r0: 0.028, r1: 0.020, sides: isLOD ? 4 : 6)
                    let crown = (centre: SIMD3<Float>(0, 0, 0.60), radius: Float(0.42), bottom: Float(0.18), top: Float(1.0))
                    b.lobe(centre: SIMD3(0, 0, 0.58), radii: SIMD3(0.23, 0.23, 0.40), rings: rings, segments: segs, bump: 0.16, crown: crown, blend: 0.35)
                    if !isLOD {
                        for (x, y, z, r) in [(0.13, 0.04, 0.42, 0.15), (-0.11, 0.09, 0.50, 0.15), (-0.02, -0.14, 0.64, 0.14), (0.08, -0.06, 0.80, 0.13), (-0.05, 0.06, 0.88, 0.11)]
                            as [(Float, Float, Float, Float)] {
                            b.lobe(centre: SIMD3(x, y, z), radii: SIMD3(r, r, r * 1.15), rings: 5, segments: 7, bump: 0.24, crown: crown, blend: 0.35)
                        }
                    }
                default:  // spreading broadleaf (maple, plane): wide and layered
                    b.trunk(z0: -0.03, z1: 0.38, r0: 0.036, r1: 0.028, sides: isLOD ? 4 : 6)
                    let crown = (centre: SIMD3<Float>(0, 0, 0.66), radius: Float(0.52), bottom: Float(0.30), top: Float(1.0))
                    b.lobe(centre: SIMD3(0, 0, 0.68), radii: SIMD3(0.44, 0.44, 0.27), rings: rings, segments: segs, bump: 0.18, crown: crown)
                    if !isLOD {
                        for k in 0..<7 {
                            let a = Float(k) / 7 * 2 * .pi, rr = Float(0.17 + 0.05 * Hash.unit(b.rng.next()))
                            let d = Float(0.30 + 0.06 * Hash.unit(b.rng.next())), z = Float(0.56 + 0.16 * Hash.unit(b.rng.next()))
                            b.lobe(centre: SIMD3(d * cos(a), d * sin(a), z), radii: SIMD3(rr, rr, rr * 0.72), rings: 5, segments: 7, bump: 0.22, crown: crown)
                        }
                        b.lobe(centre: SIMD3(-0.03, 0.05, 0.86), radii: SIMD3(0.22, 0.22, 0.13), rings: 5, segments: 7, bump: 0.2, crown: crown)
                    }
                }
                if isLOD { lod.append(b.out) } else { full.append(b.out) }
            }
        }
        return (full, lod)
    }
}
