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
        let toSun = simd_normalize(L.toSun)
        let camAltitude = Float(camera.position.z)
        let gb = g
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
                    let albedo = gb.albedo[idx]
                    let mat = gb.material[idx]
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
                        colour = body + (refl - body) * min(1, fres)
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
                        if mat == Material.paint.rawValue || mat == Material.road.rawValue {
                            let h = simd_normalize(toSun - dir)
                            let spec = powf(max(0, fdot(n, h)), mat == Material.paint.rawValue ? 80 : 20) * (mat == Material.paint.rawValue ? 0.6 : 0.08)
                            colour += L.sunColour * spec * vis
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
