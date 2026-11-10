// SKYFORGE — Apache-2.0
// Deferred shading + post-processing for the CPU preview.
import Foundation
import SFMath

public struct RenderStats: Sendable {
    public var triangles = 0
    public var buildSeconds = 0.0
    public var shadowSeconds = 0.0
    public var rasterSeconds = 0.0
    public var shadeSeconds = 0.0
    public init() {}
}

public struct PreviewImage: Sendable {
    public let width: Int
    public let height: Int
    public var rgb: [UInt8]
    public func png() -> Data { PNGEncoder.encodeRGB(width: width, height: height, rgb: rgb) }
}

public enum PreviewRenderer {
    /// Renders a triangle soup at width x height with `supersample`^2 samples per pixel.
    public static func render(soup: TriangleSoup, camera: PreviewCamera, lighting L: LightingSetup,
                              width: Int, height: Int, supersample ss: Int = 2,
                              shadowCentre: SIMD3<Double>, shadowHalfExtent: Double,
                              ground: (any GroundAlbedo)? = nil,
                              fields: FieldPattern? = nil,
                              stats: inout RenderStats) -> PreviewImage {
        let W = width * ss, H = height * ss
        let origin = soup.origin
        let camRel = SIMD3<Float>(Float(camera.position.x - origin.x), Float(camera.position.y - origin.y), Float(camera.position.z - origin.z))
        func f3(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        let right = f3(camera.right), up = f3(camera.up), fwd = f3(camera.forward)
        let focal = Float(W) / 2 / Float(tan(camera.horizontalFOV / 2))
        stats.triangles = soup.triangleCount

        var t0 = Date()
        let shadowC = SIMD3<Float>(Float(shadowCentre.x - origin.x), Float(shadowCentre.y - origin.y), Float(shadowCentre.z - origin.z))
        let shadow = ShadowMap(soup: soup, sunDirection: L.toSun, centre: shadowC, halfExtent: Float(shadowHalfExtent), size: 4096)
        stats.shadowSeconds = Date().timeIntervalSince(t0)

        t0 = Date()
        var g = GBuffer(width: W, height: H)
        let tris = Raster.project(soup, cameraOffset: camRel, right: right, up: up, forward: fwd, focal: focal, width: W, height: H)
        Raster.rasterize(tris, into: &g)
        stats.rasterSeconds = Date().timeIntervalSince(t0)

        t0 = Date()
        var hdr = [SIMD3<Float>](repeating: .zero, count: W * H)
        let cloudNoise = GradientNoise2D(seed: 0xC10D)
        let rippleNoise = GradientNoise2D(seed: 0x21BB)
        let groundNoise = GradientNoise2D(seed: 0x6D7A)
        let toSun = simd_normalize(L.toSun)
        let camAltitude = Float(camera.position.z)
        let gb = g
        let fields = fields ?? soup.fieldPattern
        // Screen-space change of the field weight (like fwidth on the GPU), for anti-aliased parcel switches.
        @Sendable func fieldBand(_ i: Int) -> Float {
            let x = i % W, f = gb.field[i]
            let dx = x + 1 < W ? abs(gb.field[i + 1] - f) : 0, dy = i + W < W * H ? abs(gb.field[i + W] - f) : 0
            return max(0.12, 2.5 * (dx + dy))
        }
        hdr.withUnsafeMutableBufferPointer { hb in
            let out = Shared(hb.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: H) { y in
                for x in 0..<W {
                    let idx = y * W + x
                    let sx = (Float(x) + 0.5 - Float(W) / 2) / focal
                    let sy = -(Float(y) + 0.5 - Float(H) / 2) / focal
                    let dir = simd_normalize(fwd + right * sx + up * sy)
                    let z = gb.depth[idx]
                    if !z.isFinite {
                        out[idx] = L.sky(dir, cloudNoise: cloudNoise)
                        continue
                    }
                    let dist = z / fdot(dir, fwd)
                    let p = camRel + dir * dist
                    var n = gb.normal[idx]
                    let nl = (n * n).sum().squareRoot()
                    n = nl > 0 ? n / nl : SIMD3(0, 0, 1)
                    // Two-sided shading: normals always face the viewer (robust to winding).
                    if fdot(n, dir) > 0 { n = -n }
                    var albedo = gb.albedo[idx]
                    var mat = gb.material[idx]
                    var imagery = false
                    if mat == Material.terrain.rawValue, let g = ground?.ground(Double(p.x) + origin.x, Double(p.y) + origin.y) {
                        albedo = g.albedo
                        imagery = true
                        if g.water > 0.5 { mat = Material.water.rawValue; albedo = g.albedo * 0.7 }
                    }
                    if mat == Material.terrain.rawValue && !imagery, let fpat = fields, gb.field[idx] < -0.003 {
                        // Suburb impostor beyond the building radius: lots, roofs, trees and streets per pixel.
                        let footprint = dist / focal / max(0.15, abs(fdot(dir, n)))
                        let wx = Float(Double(p.x) + origin.x), wy = Float(Double(p.y) + origin.y)
                        let t = fpat.town(wx, wy, footprint: footprint, lawn: albedo)
                        albedo += (t - albedo) * min(1, -gb.field[idx])
                    }
                    var fieldCov: Float = 0
                    if mat == Material.terrain.rawValue && !imagery, let fpat = fields, gb.field[idx] > 0.003 {
                        // Field parcels and hedgerows per pixel (the vertex grid blurred and stepped them).
                        let wx = Float(Double(p.x) + origin.x), wy = Float(Double(p.y) + origin.y)
                        fieldCov = fpat.coverage(wx, wy, weight: gb.field[idx], band: fieldBand(idx))
                        if fieldCov > 0 {
                            let footprint = dist / focal / max(0.15, abs(fdot(dir, n)))
                            let f = fpat.factor(wx, wy, footprint: footprint)
                            albedo *= SIMD3<Float>(repeating: 1) + (f - SIMD3<Float>(repeating: 1)) * fieldCov
                            let rt = fpat.rowTilt(wx, wy, footprint: footprint) * fieldCov
                            n = simd_normalize(n + SIMD3(rt.x, rt.y, 0))
                        }
                    }
                    if mat == Material.terrain.rawValue && dist < (imagery ? 350 : 700) {
                        // Per-pixel ground detail the vertex grid cannot carry: clumps (1.5 m), patches
                        // (6 m), dry/lush variation (40 m), and micro-relief shading; faded with distance
                        // so it never aliases.
                        // Fields carry their own rows and stripes; the generic mottle is calmed there (review:
                        // near parcels in (j) showed only blotches).
                        let fade = (1 - dist / (imagery ? 350 : 700)) * (imagery ? 0.5 : 1) * (1 - 0.7 * fieldCov)
                        let wx = Double(p.x) + origin.x, wy = Double(p.y) + origin.y
                        let fine = Float(groundNoise.fbm(wx / 1.5, wy / 1.5, octaves: 2))
                        let mid = Float(groundNoise.fbm(wx / 6 + 17, wy / 6 - 9, octaves: 2))
                        let dry = Float(groundNoise.fbm(wx / 40 - 31, wy / 40 + 5, octaves: 2))
                        albedo *= 1 + (fine * 0.05 + mid * 0.03) * fade   // calm: art review found the 0.16/0.12 mottle "camouflage"
                        let dryTint = SIMD3<Float>(1.10, 1.02, 0.80)
                        albedo *= SIMD3<Float>(repeating: 1) + (dryTint - SIMD3<Float>(repeating: 1)) * (max(0, dry) * 0.3 * fade)
                        let e: Double = 0.6
                        let gx = Float(groundNoise.fbm((wx + e) / 2.2, wy / 2.2, octaves: 2) - groundNoise.fbm((wx - e) / 2.2, wy / 2.2, octaves: 2))
                        let gy = Float(groundNoise.fbm(wx / 2.2, (wy + e) / 2.2, octaves: 2) - groundNoise.fbm(wx / 2.2, (wy - e) / 2.2, octaves: 2))
                        n = simd_normalize(n + SIMD3(-gx, -gy, 0) * (0.12 * fade))   // as Metal; low sun turned 0.3 into blotches
                    }
                    if mat == Material.terrain.rawValue && !imagery && n.z < 0.9 {
                        // Steep ground: rock texture and fall-line gullies per pixel, each octave faded by
                        // pixel footprint rather than distance, so big slopes keep detail kilometres away
                        // (art review: the shaded valley wall in (f) was one flat tone).
                        let steep = Float(smoothstep(0.9, 0.7, Double(n.z)))
                        let fpx = dist / focal
                        let wx = Double(p.x) + origin.x, wy = Double(p.y) + origin.y
                        let h = SIMD2<Float>(n.x, n.y), hl = (h * h).sum().squareRoot()
                        let fall = hl > 1e-4 ? h / hl : SIMD2<Float>(1, 0), perp = SIMD2<Float>(-fall.y, fall.x)
                        // Triplanar on the two vertical planes (horizontal axis × height): rotating world
                        // coordinates by the local fall direction swirled the pattern like wood grain, since tiny
                        // angle changes times kilometre-scale coordinates warp it (review round 11).
                        let wz = Double(p.z) + origin.z
                        let ax = Double(abs(n.x)), ay = Double(abs(n.y)), asum = max(1e-3, ax + ay)
                        func tri(_ ah: Double, _ bv: Double, _ off: Double, dh: Double = 0, dz: Double = 0, octaves: Int = 2) -> Float {
                            let a = ax > 0.02 ? groundNoise.fbm((wy + dh) / ah + off, (wz + dz) / bv, octaves: octaves) : 0
                            let b = ay > 0.02 ? groundNoise.fbm((wx + dh) / ah - off, (wz + dz) / bv - 7, octaves: octaves) : 0
                            return Float((ax * a + ay * b) / asum)
                        }
                        func w(_ cell: Float) -> Float { max(0, min(1, 1 - fpx * 2.5 / cell)) }
                        let gw = w(14) * steep
                        if gw > 0 {
                            // Gullies: 14 m across, 70 m down the fall line.
                            let g = tri(14, 70, 51), gp = tri(14, 70, 51, dh: 1.5)
                            let dg = (gp - g) / 1.5 * 14
                            let tilt = perp * (-dg * 0.35 * gw)
                            n = simd_normalize(n + SIMD3(tilt.x, tilt.y, 0))
                            albedo *= 1 - 0.28 * max(0, -g) * gw            // darker gully floors (also in shade)
                        }
                        // Buttresses and couloirs (45 m across, 160 m tall), dark weathering streaks down the fall
                        // line and pale ledge bands across it: the scale the camera sees on a far massif.
                        let bw = w(45) * steep
                        if bw > 0 {
                            let b0 = tri(45, 160, 91, octaves: 3), b1 = tri(45, 160, 91, dh: 4, octaves: 3)
                            let db = (b1 - b0) / 4 * 45
                            let tb = perp * (-db * 0.45 * bw)
                            n = simd_normalize(n + SIMD3(tb.x, tb.y, 0))
                            let streak = tri(9, 220, -41), ledge = tri(320, 28, 13)
                            let kStreak: Float = 1 - 0.22 * max(0, streak) * bw
                            let kLedge: Float = 1 + 0.12 * max(0, ledge) * bw
                            let kCouloir: Float = 1 - 0.10 * max(0, -b0) * bw
                            albedo *= kStreak * kLedge * kCouloir
                        }
                        // Fine crevices (4 m across, 10 m tall) and ledges (25 m wide, 3.5 m tall) for close range.
                        let cw = w(4) * steep
                        if cw > 0 {
                            let cr = tri(4, 10, -19), crp = tri(4, 10, -19, dh: 0.5)
                            let ld = tri(25, 3.5, 7), ldp = tri(25, 3.5, 7, dz: 0.5)
                            let dc = (crp - cr) / 0.5 * 4, dl = (ldp - ld) / 0.5 * 3.5
                            let t2 = perp * (-dc * 0.22 * cw) + fall * (dl * 0.18 * cw)
                            n = simd_normalize(n + SIMD3(t2.x, t2.y, 0))
                            albedo *= 1 - 0.12 * max(0, -cr) * cw
                        }
                        let big = Float(groundNoise.fbm(wx / 60 - 13, wy / 60 + 29, octaves: 2)) * w(60)
                        let small = Float(groundNoise.fbm(wx / 9 + 3, wy / 9 - 7, octaves: 2)) * w(9)
                        albedo *= 1 + (0.22 * big + 0.10 * small) * steep
                        // Scrub patches and pale scree on dark (non-snow) slopes: albedo variety reads even
                        // where the slope is in shadow and normal detail cannot.
                        let luma = albedo.x * 0.3 + albedo.y * 0.6 + albedo.z * 0.1
                        if luma < 0.3 {
                            let patch = Float(groundNoise.fbm(wx / 45 + 71, wy / 45 - 37, octaves: 3)) * w(45)
                            // Scrub holds on gentler ledges only, not on the steep upper faces (review: camouflage speckle).
                            let ledge = Float(smoothstep(0.76, 0.84, Double(n.z)))
                            let scrub = Float(smoothstep(0.14, 0.36, Double(patch))) * steep * ledge
                            let scree = Float(smoothstep(-0.2, -0.42, Double(patch))) * steep
                            albedo = albedo + (SIMD3<Float>(0.050, 0.072, 0.030) - albedo) * (scrub * 0.75)
                            albedo *= 1 + 0.35 * scree
                        }
                    }
                    var colour: SIMD3<Float>
                    let ndl = fdot(n, toSun)
                    let vis = toSun.z > -0.05 ? shadow.visibility(p, normalDotLight: max(0, ndl)) : 0
                    let hemi = n.z * 0.5 + 0.5
                    let ambient = L.ambientGround + (L.ambientSky - L.ambientGround) * hemi
                    switch mat {
                    case Material.water.rawValue:
                        // Gently rippled normal, Schlick Fresnel, sky reflection and sun glitter.
                        let wx = Double(p.x + Float(origin.x)), wy = Double(p.y + Float(origin.y))
                        let rx = Float(rippleNoise.fbm(wx / 9, wy / 13, octaves: 3)) * 0.08
                        let ry = Float(rippleNoise.fbm(wx / 13 + 40, wy / 9, octaves: 3)) * 0.08
                        let wn = simd_normalize(SIMD3(rx, ry, 1))
                        let r = dir - wn * (2 * fdot(dir, wn))
                        let cosT = max(0, -fdot(dir, wn))
                        let fres = 0.02 + 0.98 * powf(1 - cosT, 5)
                        var refl = L.sky(SIMD3(r.x, r.y, abs(r.z)), cloudNoise: cloudNoise)
                        refl += L.sunColour * (powf(max(0, fdot(r, toSun)), 600) * 30 * vis)
                        let body = albedo * (ambient * 0.6 + L.sunColour * max(0, toSun.z) * 0.15)
                        // Wind-roughened open water reflects a blurred, dimmer sky than a mirror would.
                        let reflScale: Float = imagery ? 0.5 : 1
                        // Ripples tilt facets toward the horizon, so rough water reflects some sky even seen
                        // from above (floor 0.10; art review: flat dark river).
                        let fresEff = imagery ? fres * 0.8 : 0.10 + 0.90 * fres
                        colour = body + (refl * reflScale - body) * min(1, fresEff)
                    case Material.foliage.rawValue:
                        let wrap = max(0, ndl * 0.55 + 0.45)
                        let back = powf(max(0, fdot(dir, toSun)), 4) * 0.35
                        colour = albedo * (L.sunColour * (wrap + back) * vis + ambient * 0.85)
                    case Material.glass.rawValue:
                        let r = dir - n * (2 * fdot(dir, n))
                        let fres = 0.04 + 0.96 * powf(1 - max(0, -fdot(dir, n)), 5)
                        let refl = L.sky(SIMD3(r.x, r.y, max(0.02, r.z)), cloudNoise: cloudNoise)
                        colour = albedo * ambient * 0.5 + refl * (0.18 + 0.6 * fres)
                        colour += L.sunColour * (powf(max(0, fdot(r, toSun)), 200) * 6 * vis)
                    default:
                        let diff = max(0, ndl)
                        colour = albedo * (L.sunColour * diff * vis + ambient)
                        if mat == Material.terrain.rawValue {
                            // Steep shaded terrain also sees the sunlit valley and opposite slopes: a bounce
                            // term keeps shadowed faces readable (art review: near-black mountain faces).
                            let steep = max(0, 1 - n.z)
                            colour += albedo * L.sunColour * (0.10 * steep * (1 - vis * diff))
                        }
                        if mat == Material.paint.rawValue {
                            // GGX dielectric (as the Metal pass) with a sky/ground environment term, so the
                            // aircraft reads as glossy paint instead of flat white (art review).
                            let v = -dir, nv = max(0.001, fdot(n, v)), nl = max(0, ndl)
                            let h = simd_normalize(toSun + v), nh = max(0, fdot(n, h)), vh = max(0, fdot(v, h))
                            let rough: Float = 0.24, a2 = rough * rough * rough * rough
                            let dd = nh * nh * (a2 - 1) + 1
                            let D = a2 / (Float.pi * dd * dd)
                            let Fh = 0.04 + 0.96 * powf(1 - vh, 5), Fv = 0.04 + 0.96 * powf(1 - nv, 5)
                            let k = (rough + 1) * (rough + 1) / 8
                            let G = (nl / (nl * (1 - k) + k)) * (nv / (nv * (1 - k) + k))
                            let spec = D * Fh * G / max(1e-4, 4 * nl * nv) * nl
                            let r = dir - n * (2 * fdot(dir, n))
                            let env = L.ambientGround + (L.ambientSky * 1.4 - L.ambientGround) * max(0, min(1, r.z * 0.5 + 0.5))
                            colour = albedo * 0.86 * (1 - Fv) * (L.sunColour * diff * vis + ambient)
                                + L.sunColour * spec * vis + env * Fv * (1 - rough * 0.7)
                        } else if mat == Material.road.rawValue {
                            let h = simd_normalize(toSun - dir)
                            colour += L.sunColour * powf(max(0, fdot(n, h)), 20) * 0.08 * vis
                        }
                    }
                    if let ph = L.physical {
                        let (ins, tr) = ph.aerial(dir, distanceMetres: dist)
                        out[idx] = colour * tr + ins
                        continue
                    }
                    // Aerial perspective: height-dependent extinction plus in-scattering toward the sun.
                    let avgH = max(0, (camAltitude + p.z + Float(origin.z)) * 0.5)
                    let ext = L.fogDensity * expf(-avgH / 1_400)
                    let trans = expf(-dist * ext)
                    let mie = powf(max(0, fdot(dir, toSun)), 8)
                    let inscatter = L.fogColour * (0.75 + 1.2 * mie)
                    out[idx] = colour * trans + inscatter * (1 - trans)
                }
            }
        }
        stats.shadeSeconds = Date().timeIntervalSince(t0)
        return post(hdr: hdr, W: W, H: H, ss: ss, width: width, height: height, exposure: L.exposure)
    }

    static func post(hdr: [SIMD3<Float>], W: Int, H: Int, ss: Int, width: Int, height: Int, exposure: Float) -> PreviewImage {
        // Downsample (box filter over ss x ss).
        var img = [SIMD3<Float>](repeating: .zero, count: width * height)
        let inv = 1 / Float(ss * ss)
        for y in 0..<height {
            for x in 0..<width {
                var acc = SIMD3<Float>.zero
                for sy in 0..<ss { for sx in 0..<ss { acc += hdr[(y * ss + sy) * W + x * ss + sx] } }
                img[y * width + x] = acc * inv * exposure
            }
        }
        // Bloom: bright-pass at quarter resolution, separable blur, add back softly.
        let bw = max(1, width / 4), bh = max(1, height / 4)
        var bloom = [SIMD3<Float>](repeating: .zero, count: bw * bh)
        for y in 0..<bh {
            for x in 0..<bw {
                var acc = SIMD3<Float>.zero
                for sy in 0..<4 { for sx in 0..<4 {
                    let c = img[min(height - 1, y * 4 + sy) * width + min(width - 1, x * 4 + sx)]
                    acc += SIMD3(max(0, c.x - 1.0), max(0, c.y - 1.0), max(0, c.z - 1.0))
                } }
                bloom[y * bw + x] = acc / 16
            }
        }
        let kernel: [Float] = [0.06, 0.12, 0.18, 0.28, 0.18, 0.12, 0.06]
        for pass in 0..<2 {
            var tmp = bloom
            for y in 0..<bh {
                for x in 0..<bw {
                    var acc = SIMD3<Float>.zero
                    for k in -3...3 {
                        let xx = pass == 0 ? min(bw - 1, max(0, x + k)) : x
                        let yy = pass == 1 ? min(bh - 1, max(0, y + k)) : y
                        acc += bloom[yy * bw + xx] * kernel[k + 3]
                    }
                    tmp[y * bw + x] = acc
                }
            }
            bloom = tmp
        }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                var c = img[y * width + x]
                let bx = min(bw - 1, x / 4), by = min(bh - 1, y / 4)
                c += bloom[by * bw + bx] * 0.35
                // Gentle vignette.
                let u = Float(x) / Float(width) - 0.5, v = Float(y) / Float(height) - 0.5
                c *= 1 - 0.28 * (u * u + v * v) * 2
                let t = aces(c)
                let i = (y * width + x) * 3
                rgb[i] = UInt8(min(255, max(0, linearToSRGB(t.x) * 255 + 0.5)))
                rgb[i + 1] = UInt8(min(255, max(0, linearToSRGB(t.y) * 255 + 0.5)))
                rgb[i + 2] = UInt8(min(255, max(0, linearToSRGB(t.z) * 255 + 0.5)))
            }
        }
        return PreviewImage(width: width, height: height, rgb: rgb)
    }
}
