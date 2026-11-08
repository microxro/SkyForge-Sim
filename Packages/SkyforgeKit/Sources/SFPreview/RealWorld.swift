// SKYFORGE — Apache-2.0
// Real-world preview scenes: Terrarium elevation, free orthoimagery as ground albedo (two
// resolutions), water and forest from imagery land cover, and 3D trees grown on forest pixels.
import Foundation
import SFMath
import SFWorldGen
import SFImagery

/// Per-pixel ground albedo for the CPU renderer (linear RGB) plus a water score.
public protocol GroundAlbedo: Sendable {
    func ground(_ x: Double, _ y: Double) -> (albedo: SIMD3<Float>, water: Float)?
}

@inline(__always) func srgbToLinear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }

public struct ImageryGround: GroundAlbedo {
    public let near: ImageryMosaic
    public let far: ImageryMosaic?
    /// Water score averaged over 8 × 8 imagery pixels (≈16 m) so shorelines are smooth and dark
    /// roofs or tree shadows in town are not mistaken for ponds.
    public let waterMask: [Float]
    public let maskSize: Int
    public static let block = 8

    /// `grade`: de-haze the far mosaic and colour-match the near mosaic to it (after the water mask is
    /// classified from the untouched photo).
    public init(near: ImageryMosaic, far: ImageryMosaic?, grade: Bool = false) {
        let b = Self.block, n = near.size / b
        var mask = [Float](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                var w: Float = 0, k: Float = 0
                for y in stride(from: j * b, to: j * b + b, by: 2) {
                    for x in stride(from: i * b, to: i * b + b, by: 2) {
                        let o = 3 * (y * near.size + x)
                        let c = SIMD3(Float(near.rgb[o]), Float(near.rgb[o + 1]), Float(near.rgb[o + 2])) / 255
                        w += LandCover.classify(c).water; k += 1
                    }
                }
                mask[j * n + i] = w / k
            }
        }
        waterMask = mask; maskSize = n
        if grade, var f = far {
            ImageryGrading.dehaze(&f)
            var nm = near
            ImageryGrading.match(&nm, to: f)
            self.near = nm; self.far = f
        } else {
            self.near = near; self.far = far
        }
    }

    func water(_ x: Double, _ y: Double) -> Float? {
        let mpp = near.metresPerPixel * Double(Self.block)
        let fx = (x - (near.centre.x - near.halfExtent)) / mpp - 0.5
        let fy = ((near.centre.y + near.halfExtent) - y) / mpp - 0.5
        guard fx >= 0, fy >= 0, fx < Double(maskSize - 1), fy < Double(maskSize - 1) else { return nil }
        let i = Int(fx), j = Int(fy), ax = Float(fx - Double(i)), ay = Float(fy - Double(j))
        let a = waterMask[j * maskSize + i], b = waterMask[j * maskSize + i + 1]
        let c = waterMask[(j + 1) * maskSize + i], d = waterMask[(j + 1) * maskSize + i + 1]
        return (a + (b - a) * ax) * (1 - ay) + (c + (d - c) * ax) * ay
    }

    public func ground(_ x: Double, _ y: Double) -> (albedo: SIMD3<Float>, water: Float)? {
        // Near layer feathered into the far one over its outer 6 % (as the Metal shader).
        let nc = near.sample(x, y), fc = far?.sample(x, y)
        var cOpt = nc ?? fc
        if let n = nc, let f = fc {
            let u = (x - (near.centre.x - near.halfExtent)) / (2 * near.halfExtent), v = (y - (near.centre.y - near.halfExtent)) / (2 * near.halfExtent)
            let e = Float(min(min(u, v), min(1 - u, 1 - v)))
            let t = max(0, min(1, (e - 0.002) / 0.058)), wN = t * t * (3 - 2 * t)
            cOpt = f + (n - f) * wN
        }
        guard let c = cOpt else { return nil }
        // Orthophotos already contain sunlight, shadows and camera exposure: convert to a plausible
        // albedo (darker, slightly more contrast) so the renderer's own lighting does not double it.
        var lin = SIMD3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z))
        lin = SIMD3(powf(lin.x, 1.12), powf(lin.y, 1.12), powf(lin.z, 1.12)) * 0.72
        let w = water(x, y) ?? LandCover.classify(c).water
        let sharpened = max(0, min(1, (w - 0.35) / 0.25))
        return (lin, sharpened)
    }
}

public struct RealWorldSite: Sendable {
    public var name: String
    public var origin: GeoOrigin
    public var camera: PreviewCamera
    public var time: TimePreset
    public var sunAzimuth: Double
    public var aircraft: (ahead: Double, below: Double, right: Double, headingOffset: Double, pitch: Double, roll: Double)?

    /// Merritt Island, Florida (KCOI area): chase view at ~1,200 ft heading north over forest,
    /// lagoons and the Indian/Banana River system — comparable to the user's reference.
    public static let merrittIsland: RealWorldSite = {
        let origin = GeoOrigin(latitude: 28.3416, longitude: -80.6855)
        let cam = PreviewCamera(position: SIMD3(-600, -2_600, 380), lookAt: SIMD3(-200, 4_000, 0), horizontalFOV: 68 * .pi / 180)
        return RealWorldSite(name: "merritt_island", origin: origin, camera: cam, time: .midday, sunAzimuth: 20,
                             aircraft: (ahead: 24, below: 4.5, right: 0, headingOffset: 0, pitch: 0.02, roll: 0.0))
    }()
}

public enum RealWorldScenes {
    public struct Inputs: Sendable {
        public var heights: HeightMosaic
        public var farHeights: HeightMosaic
        public var near: ImageryMosaic
        public var far: ImageryMosaic
        public init(heights: HeightMosaic, farHeights: HeightMosaic, near: ImageryMosaic, far: ImageryMosaic) {
            self.heights = heights; self.farHeights = farHeights; self.near = near; self.far = far
        }
    }

    /// Builds the mesh: near/far terrain from real heights, trees on forest pixels near the camera.
    public static func buildSoup(site: RealWorldSite, inputs: Inputs, treeRadius: Double = 2_600) -> (TriangleSoup, [String: Int]) {
        let cam = site.camera
        var soup = TriangleSoup(origin: SIMD3(cam.position.x, cam.position.y, 0))
        var stats: [String: Int] = [:]
        let ground = ImageryGround(near: inputs.near, far: inputs.far, grade: true)
        func h(_ x: Double, _ y: Double) -> Double {
            let n = inputs.heights
            if abs(x - n.centre.x) < n.halfExtent && abs(y - n.centre.y) < n.halfExtent { return max(0, n.height(x, y)) }
            return max(0, inputs.farHeights.height(x, y))
        }
        func grid(centre: SIMD2<Double>, half: Double, step: Double, skip: Double, lower: Double) {
            let n = Int((2 * half / step).rounded())
            let x0 = (centre.x / step).rounded() * step - half, y0 = (centre.y / step).rounded() * step - half
            let cx = x0 + half, cy = y0 + half
            var count = 0
            for j in 0..<n {
                for i in 0..<n {
                    let x = x0 + Double(i) * step, y = y0 + Double(j) * step
                    if skip > 0 && abs(x + step / 2 - cx) < skip && abs(y + step / 2 - cy) < skip { continue }
                    let p00 = SIMD3(x, y, h(x, y) - lower), p10 = SIMD3(x + step, y, h(x + step, y) - lower)
                    let p01 = SIMD3(x, y + step, h(x, y + step) - lower), p11 = SIMD3(x + step, y + step, h(x + step, y + step) - lower)
                    let n1 = normalize(cross(p10 - p00, p11 - p00)), n2 = normalize(cross(p11 - p00, p01 - p00))
                    let f1 = SIMD3<Float>(Float(n1.x), Float(n1.y), Float(n1.z)), f2 = SIMD3<Float>(Float(n2.x), Float(n2.y), Float(n2.z))
                    let grey = SIMD3<Float>(0.15, 0.17, 0.12)
                    soup.add(p00, p10, p11, na: f1, nb: f1, nc: f1, colour: grey, material: .terrain)
                    soup.add(p00, p11, p01, na: f2, nb: f2, nc: f2, colour: grey, material: .terrain)
                    count += 2
                }
            }
            stats["terrain", default: 0] += count
        }
        let fwd = normalize(SIMD3(cam.forward.x, cam.forward.y, 0))
        let focus = SIMD2(cam.position.x + fwd.x * 2_500, cam.position.y + fwd.y * 2_500)
        grid(centre: focus, half: 3_000, step: 12, skip: 0, lower: 0)
        grid(centre: focus, half: 12_000, step: 60, skip: 3_000 - 60, lower: 0.4)
        grid(centre: focus, half: 40_000, step: 300, skip: 12_000 - 300, lower: 1.5)
        // Trees: a jittered 7 m lattice; each site keeps a tree with probability = forest score.
        let cell = 7.0
        let camXY = SIMD2(cam.position.x, cam.position.y)
        let r = treeRadius
        var trees = 0
        var y = (focus.y - r).rounded(.down)
        while y < focus.y + r {
            var x = (focus.x - r).rounded(.down)
            while x < focus.x + r {
                defer { x += cell }
                let hsh = Hash.int(Int((x / cell).rounded()), Int((y / cell).rounded()), seed: 0x7EE5)
                var rng = SplitMix64(seed: hsh)
                let px = x + Hash.unit(rng.next()) * cell, py = y + Hash.unit(rng.next()) * cell
                let d = SIMD2(px, py) - camXY
                let along = (d * SIMD2(fwd.x, fwd.y)).sum()
                if along < -40 || (d * d).sum() > r * r * 1.4 { continue }
                guard let g = ground.ground(px, py), let c = inputs.near.sample(px, py) else { continue }
                let shadeTint = g.albedo * 1.9   // canopy colour from the photo, lifted back from albedo
                let lc = LandCover.classify(c)
                if Hash.unit(rng.next()) > Double(lc.forest) * 0.9 || g.water > 0.3 { continue }
                let height = 9 + Hash.unit(rng.next()) * 10
                let conifer = Hash.unit(rng.next()) < 0.55          // slash/longleaf pine vs live oak
                let base = SIMD3(px, py, h(px, py))
                let tint = shadeTint * Float(0.85 + 0.3 * Hash.unit(rng.next()))
                let dist = (d * d).sum().squareRoot()
                addTree(&soup, base: base, height: height, conifer: conifer, colour: tint, detail: dist < 700 ? 2 : 1)
                trees += 1
            }
            y += cell
        }
        stats["trees"] = trees
        return (soup, stats)
    }

    static func addTree(_ soup: inout TriangleSoup, base p: SIMD3<Double>, height: Double, conifer: Bool, colour: SIMD3<Float>, detail: Int) {
        let sides = detail >= 2 ? 7 : 5
        if conifer {
            // Florida pines: tall bare trunk, compact crown at the top.
            let crownBase = p.z + height * 0.55, r = height * 0.22
            ring(&soup, centre: SIMD3(p.x, p.y, crownBase), r0: r, r1: r * 0.75, h: height * 0.25, sides: sides, colour: colour)
            cone(&soup, base: SIMD3(p.x, p.y, crownBase + height * 0.25), r: r * 0.75, top: p.z + height, sides: sides, colour: colour * 0.92)
            if detail >= 2 { cone(&soup, base: SIMD3(p.x, p.y, p.z - 0.5), r: 0.25, top: crownBase + 1, sides: 4, colour: SIMD3(0.09, 0.07, 0.05), mat: .opaque) }
        } else {
            // Live oak: broad, low dome.
            let r = height * 0.42, cz = p.z + height * 0.55
            ring(&soup, centre: SIMD3(p.x, p.y, cz - r * 0.35), r0: r * 0.7, r1: r, h: r * 0.45, sides: sides + 1, colour: colour * 0.9)
            cone(&soup, base: SIMD3(p.x, p.y, cz + r * 0.1), r: r, top: cz + r * 0.75, sides: sides + 1, colour: colour)
        }
    }

    static func ring(_ soup: inout TriangleSoup, centre c: SIMD3<Double>, r0: Double, r1: Double, h: Double, sides: Int, colour: SIMD3<Float>) {
        for k in 0..<sides {
            let a0 = Double(k) / Double(sides) * 2 * .pi, a1 = Double(k + 1) / Double(sides) * 2 * .pi
            let b0 = SIMD3(c.x + r0 * cos(a0), c.y + r0 * sin(a0), c.z), b1 = SIMD3(c.x + r0 * cos(a1), c.y + r0 * sin(a1), c.z)
            let t0 = SIMD3(c.x + r1 * cos(a0), c.y + r1 * sin(a0), c.z + h), t1 = SIMD3(c.x + r1 * cos(a1), c.y + r1 * sin(a1), c.z + h)
            soup.addFlat(b0, b1, t1, colour: colour, material: .foliage)
            soup.addFlat(b0, t1, t0, colour: colour, material: .foliage)
        }
    }

    static func cone(_ soup: inout TriangleSoup, base c: SIMD3<Double>, r: Double, top: Double, sides: Int, colour: SIMD3<Float>, mat: Material = .foliage) {
        let apex = SIMD3(c.x, c.y, top)
        for k in 0..<sides {
            let a0 = Double(k) / Double(sides) * 2 * .pi, a1 = Double(k + 1) / Double(sides) * 2 * .pi
            soup.addFlat(SIMD3(c.x + r * cos(a0), c.y + r * sin(a0), c.z), SIMD3(c.x + r * cos(a1), c.y + r * sin(a1), c.z), apex, colour: colour, material: mat)
        }
    }
}

extension RealWorldScenes {
    /// Fetches elevation and imagery (cached), builds and renders a real-world site.
    public static func render(site: RealWorldSite, inputs: Inputs, width: Int, height: Int, supersample: Int = 2,
                              time: TimePreset? = nil) -> (PreviewImage, RenderStats, [String: Int]) {
        var stats = RenderStats()
        let t0 = Date()
        var (soup, counts) = buildSoup(site: site, inputs: inputs)
        if let rig = site.aircraft {
            let cam = site.camera
            let fwdH = normalize(SIMD3(cam.forward.x, cam.forward.y, 0))
            let pos = cam.position + fwdH * rig.ahead - SIMD3(0, 0, rig.below) + SIMD3(fwdH.y, -fwdH.x, 0) * rig.right
            var b = SceneBuilder(generator: WorldGenerator(terrain: TerrainRecipe(kind: .suburbanPlain, seed: 1)), origin: soup.origin)
            b.addAircraft(at: pos, heading: atan2(fwdH.x, fwdH.y) + rig.headingOffset, pitch: rig.pitch, roll: rig.roll, accent: srgb(28, 62, 118))
            let a = b.soup
            if !a.vertexAlbedo.isEmpty || !soup.vertexAlbedo.isEmpty {
                if soup.vertexAlbedo.isEmpty { soup.vertexAlbedo = soup.albedo.flatMap { [$0, $0, $0] } }
                soup.vertexAlbedo += a.vertexAlbedo.isEmpty ? a.albedo.flatMap { [$0, $0, $0] } : a.vertexAlbedo
            }
            soup.positions += a.positions; soup.normals += a.normals; soup.albedo += a.albedo; soup.material += a.material
            counts["aircraft"] = 1
        }
        stats.buildSeconds = Date().timeIntervalSince(t0)
        let cam = site.camera
        let lighting = LightingSetup.physicalPreset(time ?? site.time, azimuthDegrees: site.sunAzimuth, cameraHeightMetres: cam.position.z)
        let fwd2 = normalize(SIMD3(cam.forward.x, cam.forward.y, 0))
        let shadowCentre = SIMD3(cam.position.x + fwd2.x * 900, cam.position.y + fwd2.y * 900, 0)
        let img = PreviewRenderer.render(soup: soup, camera: cam, lighting: lighting, width: width, height: height,
                                         supersample: supersample, shadowCentre: shadowCentre, shadowHalfExtent: 1_800,
                                         ground: ImageryGround(near: inputs.near, far: inputs.far, grade: true), stats: &stats)
        return (img, stats, counts)
    }
}
