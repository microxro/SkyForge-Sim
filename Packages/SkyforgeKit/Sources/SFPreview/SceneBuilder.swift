// SKYFORGE — Apache-2.0
// Converts SkyWorld generator output into triangles for the CPU preview.
import Foundation
import SFMath
import SFWorldGen

public struct SceneBuilder {
    public let generator: WorldGenerator
    public let terrain: TerrainRecipe
    public var soup: TriangleSoup
    let macroNoise: GradientNoise2D
    let moistureNoise: GradientNoise2D
    public private(set) var stats: [String: Int] = [:]

    public init(generator: WorldGenerator, origin: SIMD3<Double>) {
        self.generator = generator
        terrain = generator.terrain
        soup = TriangleSoup(origin: origin)
        macroNoise = GradientNoise2D(seed: Hash.combine(generator.terrain.seed, 0x3AC0))
        moistureNoise = GradientNoise2D(seed: Hash.combine(generator.terrain.seed, 0x3015))
    }

    static func f(_ c: LinearRGB) -> SIMD3<Float> { c }

    // MARK: Ground colour

    func groundColour(_ x: Double, _ y: Double, _ z: Double, normal n: SIMD3<Double>, far: Bool = false) -> SIMD3<Float> {
        let slope = acos(min(1, n.z))
        let rd = terrain.riverDistance(x, y)
        let moisture = clamp(0.55 + moistureNoise.fbm(x / 700, y / 700, octaves: 3) * 0.6 + (rd < 300 ? 0.2 : 0), 0, 1)
        let distWater = terrain.kind == .coastline ? max(0, z - terrain.seaLevel) * 12 : rd
        let biome = BiomeClassifier.classify(ClimateInputs(latitude: generator.latitude, elevation: z, slope: slope,
                                                           moisture: moisture, distanceToWater: distWater))
        var c = GroundPalette.colour(biome, season: generator.season)
        let settle = generator.settlementDensity(x, y)
        let forestMask = smoothstep(-0.25, 0.15, moistureNoise.fbm(x / 1_100 + 9, y / 1_100, octaves: 3))
        if (biome == .temperateForest || biome == .boreal) && settle < 0.32 {
            // Distant forest canopy tint (trees are only instanced near the camera).
            let canopy: LinearRGB = biome == .boreal ? srgb(40, 56, 40) : (generator.season == .autumn ? srgb(92, 84, 50) : srgb(52, 76, 40))
            c = c + (canopy - c) * Float(forestMask * 0.85)
            if forestMask < 0.4 && slope < 0.12 && terrain.kind != .mountainValley { c = fieldColour(x, y, base: c) }
        } else if settle > 0.32 && !far {
            c = srgb(92, 106, 62) * Float(0.92 + 0.08 * macroNoise.fbm(x / 30, y / 30, octaves: 2))   // lawns
        } else if settle > 0.32 {
            // Built-up texture: lawns mottled with roof, pavement and canopy colours at ~25 m scale,
            // so suburbs beyond the instancing radius still read as suburbs, not as a flat lawn.
            let cell = Hash.int(Int((x / 25).rounded(.down)), Int((y / 25).rounded(.down)), seed: Hash.combine(terrain.seed, 0x5B))
            let pick = Hash.unit(cell)
            let lawn = srgb(92, 106, 62)
            let roofs = generator.palette.roofs
            if pick < 0.28 { c = roofs[Int(cell % UInt64(roofs.count))] * 0.9 + lawn * 0.1 }
            else if pick < 0.42 { c = srgb(96, 96, 98) }
            else if pick < 0.62 { c = generator.season == .autumn ? srgb(118, 92, 52) : srgb(62, 84, 44) }
            else { c = lawn }
        } else if slope < 0.12 && (biome == .grassland || biome == .temperateForest) {
            c = terrain.kind == .mountainValley
                ? srgb(84, 108, 58) * Float(0.9 + 0.12 * macroNoise.fbm(x / 90, y / 90, octaves: 2))   // alpine meadow
                : fieldColour(x, y, base: c)
        }
        // Rock on steep slopes, snow by temperature and slope.
        let rock = Float(smoothstep(0.55, 0.9, slope))
        c = c + (GroundPalette.colour(.rock, season: generator.season) - c) * rock
        let t = BiomeClassifier.temperature(latitude: generator.latitude, elevation: z + macroNoise.fbm(x / 400, y / 400) * 120)
        let snow = Float(smoothstep(-1, -4, t) * (1 - smoothstep(0.7, 1.0, slope)))
        c = c + (srgb(236, 240, 246) - c) * snow
        if terrain.kind == .coastline && z < 4 && z > terrain.seaLevel - 1 { c = srgb(206, 190, 150) }
        if let r = terrain.river, rd < r.width / 2 + 14 {
            let bank = Float(1 - smoothstep(r.width / 2, r.width / 2 + 14, rd))
            c = c + (srgb(112, 100, 78) - c) * bank
        }
        // Macro variation breaks up uniformity (no visible tiling).
        let v = Float(1 + macroNoise.fbm(x / 260, y / 260, octaves: 3) * 0.16)
        return c * v
    }

    func fieldColour(_ x: Double, _ y: Double, base: SIMD3<Float>) -> SIMD3<Float> {
        // Patchwork of fields in rotated 160 x 240 m parcels, colour by crop and season.
        let a = 0.35, c = cos(a), s = sin(a)
        let u = c * x + s * y, v = -s * x + c * y
        let iu = Int((u / 160).rounded(.down)), iv = Int((v / 240).rounded(.down))
        let h = Hash.int(iu, iv, seed: Hash.combine(terrain.seed, 0xF1E1D))
        // Muted, art-directed crop palette (stubble, ploughed soil, winter wheat, pasture).
        let crops: [LinearRGB] = generator.season == .autumn
            ? [srgb(138, 124, 84), srgb(104, 92, 70), srgb(86, 104, 58), srgb(120, 112, 78), srgb(96, 112, 62), srgb(146, 132, 92), srgb(78, 96, 54)]
            : [srgb(98, 126, 62), srgb(122, 130, 72), srgb(86, 112, 56), srgb(136, 132, 86), srgb(110, 104, 72)]
        var col = crops[Int(h % UInt64(crops.count))]
        // Row texture along the field orientation.
        let rows = Hash.unit(Hash.mix(h)) < 0.5 ? u : v
        col *= Float(0.94 + 0.06 * sin(rows * 1.3))
        return base * 0.25 + col * 0.75
    }

    // MARK: Terrain

    public mutating func addTerrain(centre: SIMD2<Double>, halfExtent: Double, step: Double, skipInside: Double = 0, lower: Double = 0, far: Bool = false) {
        let n = Int((2 * halfExtent / step).rounded())
        let x0 = (centre.x / step).rounded() * step - halfExtent, y0 = (centre.y / step).rounded() * step - halfExtent
        var heights = [Double](repeating: 0, count: (n + 1) * (n + 1))
        var normals = [SIMD3<Float>](repeating: .zero, count: (n + 1) * (n + 1))
        var colours = [SIMD3<Float>](repeating: .zero, count: (n + 1) * (n + 1))
        for j in 0...n {
            for i in 0...n {
                let x = x0 + Double(i) * step, y = y0 + Double(j) * step
                let z = terrain.height(x, y)
                let nn = terrain.normal(x, y, step: max(2, step / 2))
                heights[j * (n + 1) + i] = z - lower
                normals[j * (n + 1) + i] = SIMD3(Float(nn.x), Float(nn.y), Float(nn.z))
                colours[j * (n + 1) + i] = groundColour(x, y, z, normal: nn, far: far)
            }
        }
        let cx = (centre.x / step).rounded() * step, cy = (centre.y / step).rounded() * step
        var count = 0
        for j in 0..<n {
            for i in 0..<n {
                let x = x0 + Double(i) * step, y = y0 + Double(j) * step
                if skipInside > 0 && abs(x + step / 2 - cx) < skipInside && abs(y + step / 2 - cy) < skipInside { continue }
                let i00 = j * (n + 1) + i, i10 = i00 + 1, i01 = i00 + n + 1, i11 = i01 + 1
                let p00 = SIMD3(x, y, heights[i00]), p10 = SIMD3(x + step, y, heights[i10])
                let p01 = SIMD3(x, y + step, heights[i01]), p11 = SIMD3(x + step, y + step, heights[i11])
                let c1 = (colours[i00] + colours[i10] + colours[i11]) / 3
                let c2 = (colours[i00] + colours[i11] + colours[i01]) / 3
                soup.add(p00, p10, p11, na: normals[i00], nb: normals[i10], nc: normals[i11], colour: c1, material: .opaque)
                soup.add(p00, p11, p01, na: normals[i00], nb: normals[i11], nc: normals[i01], colour: c2, material: .opaque)
                count += 2
            }
        }
        stats["terrain", default: 0] += count
    }

    // MARK: Water

    public mutating func addWater(centre: SIMD2<Double>, halfExtent: Double, step: Double) {
        let up = SIMD3<Float>(0, 0, 1)
        let deep: SIMD3<Float> = terrain.kind == .coastline ? srgb(18, 46, 60) : srgb(26, 44, 40)
        if terrain.kind == .coastline {
            let e = halfExtent * 3
            let z = terrain.seaLevel
            let a = SIMD3(centre.x - e, centre.y - e, z), b = SIMD3(centre.x + e, centre.y - e, z)
            let c = SIMD3(centre.x + e, centre.y + e, z), d = SIMD3(centre.x - e, centre.y + e, z)
            soup.add(a, b, c, na: up, nb: up, nc: up, colour: deep, material: .water)
            soup.add(a, c, d, na: up, nb: up, nc: up, colour: deep, material: .water)
            stats["water", default: 0] += 2
            return
        }
        guard let river = terrain.river else { return }
        // Smooth ribbon along the centre-line, wider than the channel so banks hide the edge.
        let w = river.width / 2 + 6
        for i in 0..<(river.points.count - 1) {
            let a = river.points[i], b = river.points[i + 1]
            if ((a - centre) * (a - centre)).sum() > halfExtent * halfExtent * 4 { continue }
            let pa = river.points[max(0, i - 1)], pb = river.points[min(river.points.count - 1, i + 2)]
            func nrm(_ t: SIMD2<Double>) -> SIMD2<Double> { let l = (t * t).sum().squareRoot(); return SIMD2(-t.y, t.x) / max(l, 1e-9) }
            let na = nrm(b - pa), nb = nrm(pb - a)
            let pieces = 6
            for k in 0..<pieces {
                let t0 = Double(k) / Double(pieces), t1 = Double(k + 1) / Double(pieces)
                let c0 = a + (b - a) * t0, c1 = a + (b - a) * t1
                let n0 = normalize2(na + (nb - na) * t0), n1 = normalize2(na + (nb - na) * t1)
                let z0 = terrain.waterHeight(c0.x, c0.y), z1 = terrain.waterHeight(c1.x, c1.y)
                let q0 = SIMD3(c0.x - n0.x * w, c0.y - n0.y * w, z0), q1 = SIMD3(c1.x - n1.x * w, c1.y - n1.y * w, z1)
                let q2 = SIMD3(c1.x + n1.x * w, c1.y + n1.y * w, z1), q3 = SIMD3(c0.x + n0.x * w, c0.y + n0.y * w, z0)
                soup.add(q0, q1, q2, na: up, nb: up, nc: up, colour: deep, material: .water)
                soup.add(q0, q2, q3, na: up, nb: up, nc: up, colour: deep, material: .water)
                stats["water", default: 0] += 2
            }
        }
        _ = step
    }

    func normalize2(_ v: SIMD2<Double>) -> SIMD2<Double> {
        let l = (v * v).sum().squareRoot()
        return l > 0 ? v / l : v
    }

    // MARK: Roads

    public mutating func addRoads(_ roads: [Road], near: SIMD2<Double>, radius: Double) {
        for r in roads {
            let w = r.roadClass.width
            let asphalt: SIMD3<Float> = r.roadClass == .highway ? srgb(58, 58, 60) : srgb(70, 70, 72)
            for i in 0..<(r.points.count - 1) {
                let a = r.points[i], b = r.points[i + 1]
                let mid = (a + b) / 2
                if ((mid - near) * (mid - near)).sum() > radius * radius { continue }
                let d = b - a
                let len = (d * d).sum().squareRoot()
                guard len > 0.1 else { continue }
                let dirv = d / len
                let nrm = SIMD2(-dirv.y, dirv.x)
                let pieces = max(1, Int((len / 8).rounded(.up)))
                for k in 0..<pieces {
                    let p0 = a + d * (Double(k) / Double(pieces)), p1 = a + d * (Double(k + 1) / Double(pieces))
                    func pt(_ p: SIMD2<Double>, _ off: Double) -> SIMD3<Double> {
                        let q = p + nrm * off
                        return SIMD3(q.x, q.y, terrain.height(q.x, q.y) + 0.35)
                    }
                    soup.addQuad(pt(p0, -w / 2), pt(p1, -w / 2), pt(p1, w / 2), pt(p0, w / 2), colour: asphalt, material: .road)
                    // Markings: dashed centre line for arterials/locals, solid edge lines + lane dashes on highways.
                    let markColour: SIMD3<Float> = r.roadClass == .arterial ? srgb(196, 170, 70) : srgb(200, 200, 196)
                    if r.roadClass == .highway {
                        for off in [-w / 2 + 0.6, w / 2 - 0.6] {
                            soup.addQuad(pt(p0, off - 0.12), pt(p1, off - 0.12), pt(p1, off + 0.12), pt(p0, off + 0.12), colour: markColour, material: .road)
                        }
                        if k % 2 == 0 {
                            for off in [-w / 4, w / 4] {
                                soup.addQuad(pt(p0, off - 0.1), pt(p1, off - 0.1), pt(p1, off + 0.1), pt(p0, off + 0.1), colour: markColour, material: .road)
                            }
                        }
                        soup.addQuad(pt(p0, -0.9), pt(p1, -0.9), pt(p1, 0.9), pt(p0, 0.9), colour: srgb(96, 104, 70), material: .road) // median
                    } else if r.roadClass != .local || k % 2 == 0 {
                        soup.addQuad(pt(p0, -0.1), pt(p1, -0.1), pt(p1, 0.1), pt(p0, 0.1), colour: markColour, material: .road)
                    }
                    stats["roads", default: 0] += 2
                }
            }
        }
    }

    // MARK: Buildings

    public mutating func addBuilding(_ b: Building) {
        let c = cos(b.heading), s = sin(b.heading)
        func w(_ lx: Double, _ ly: Double, _ z: Double) -> SIMD3<Double> {
            SIMD3(b.center.x + c * lx - s * ly, b.center.y + s * lx + c * ly, b.baseHeight + z)
        }
        let hx = b.halfSize.x, hy = b.halfSize.y, h = b.wallHeight
        let base = -1.5 // sink into terrain so slopes never show a gap
        let corners = [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)]
        for k in 0..<4 {
            let (ax, ay) = corners[k], (bx, by) = corners[(k + 1) % 4]
            soup.addQuad(w(ax, ay, base), w(bx, by, base), w(bx, by, h), w(ax, ay, h), colour: b.wallColour)
        }
        // Windows: darker glass bands on the long walls (one per floor).
        if b.kind == .house || b.kind == .apartment || b.kind == .office || b.kind == .stripMall {
            let floors = max(1, Int((h / 2.9).rounded(.down)))
            let glass = srgb(40, 48, 58)
            for f in 0..<floors {
                let z0 = Double(f) * 2.9 + 1.0, z1 = z0 + 1.2
                for side in [-1.0, 1.0] {
                    let ly = side * (hy + 0.04)
                    let count = max(1, Int((2 * hx / 3.2).rounded(.down)))
                    for wi in 0..<count {
                        let cxw = -hx + (Double(wi) + 0.5) * (2 * hx / Double(count))
                        let a = w(cxw - 0.6, ly, z0), bq = w(cxw + 0.6, ly, z0), cq = w(cxw + 0.6, ly, z1), d = w(cxw - 0.6, ly, z1)
                        if side > 0 { soup.addQuad(a, bq, cq, d, colour: glass, material: .glass) }
                        else { soup.addQuad(bq, a, d, cq, colour: glass, material: .glass) }
                    }
                }
            }
        }
        let rise = b.roofPitch * hy
        switch b.roof {
        case .flat:
            soup.addQuad(w(-hx, -hy, h), w(hx, -hy, h), w(hx, hy, h), w(-hx, hy, h), colour: b.roofColour)
            // Parapet + HVAC box on larger roofs.
            if hx * hy > 150 {
                let u = srgb(170, 170, 166)
                let bx = hx * 0.3, by = hy * 0.2
                for k in 0..<4 {
                    let (ax, ay) = [(-bx, -by), (bx, -by), (bx, by), (-bx, by)][k], (cx2, cy2) = [(bx, -by), (bx, by), (-bx, by), (-bx, -by)][k]
                    soup.addQuad(w(ax, ay, h), w(cx2, cy2, h), w(cx2, cy2, h + 1.6), w(ax, ay, h + 1.6), colour: u)
                }
                soup.addQuad(w(-bx, -by, h + 1.6), w(bx, -by, h + 1.6), w(bx, by, h + 1.6), w(-bx, by, h + 1.6), colour: u)
            }
        case .gabled:
            let o = 0.4 // eave overhang
            soup.addQuad(w(-hx - o, -hy - o, h - 0.2), w(hx + o, -hy - o, h - 0.2), w(hx + o, 0, h + rise), w(-hx - o, 0, h + rise), colour: b.roofColour)
            soup.addQuad(w(hx + o, hy + o, h - 0.2), w(-hx - o, hy + o, h - 0.2), w(-hx - o, 0, h + rise), w(hx + o, 0, h + rise), colour: b.roofColour * 0.97)
            soup.addFlat(w(hx, -hy, h), w(hx, hy, h), w(hx, 0, h + rise), colour: b.wallColour)
            soup.addFlat(w(-hx, hy, h), w(-hx, -hy, h), w(-hx, 0, h + rise), colour: b.wallColour)
        case .hipped:
            let r = min(hx, hy) * 0.9
            let o = 0.4
            let top0 = w(-hx + r, 0, h + rise), top1 = w(hx - r, 0, h + rise)
            soup.addQuad(w(-hx - o, -hy - o, h - 0.2), w(hx + o, -hy - o, h - 0.2), top1, top0, colour: b.roofColour)
            soup.addQuad(w(hx + o, hy + o, h - 0.2), w(-hx - o, hy + o, h - 0.2), top0, top1, colour: b.roofColour * 0.97)
            soup.addFlat(w(hx + o, -hy - o, h - 0.2), w(hx + o, hy + o, h - 0.2), top1, colour: b.roofColour * 0.94)
            soup.addFlat(w(-hx - o, hy + o, h - 0.2), w(-hx - o, -hy - o, h - 0.2), top0, colour: b.roofColour * 0.94)
        case .sawtooth:
            let teeth = max(2, Int((2 * hx / 10).rounded()))
            let tw = 2 * hx / Double(teeth)
            for k in 0..<teeth {
                let xa = -hx + Double(k) * tw, xb = xa + tw
                soup.addQuad(w(xa, -hy, h), w(xa, hy, h), w(xb, hy, h + 3), w(xb, -hy, h + 3), colour: b.roofColour)
                soup.addQuad(w(xb, -hy, h + 3), w(xb, hy, h + 3), w(xb, hy, h), w(xb, -hy, h), colour: srgb(80, 96, 110), material: .glass)
            }
        }
        stats["buildings", default: 0] += 1
    }

    public mutating func addParkingLot(_ lot: ParkingLot) {
        let c = cos(lot.heading), s = sin(lot.heading)
        func w(_ lx: Double, _ ly: Double, _ z: Double) -> SIMD3<Double> {
            let x = lot.center.x + c * lx - s * ly, y = lot.center.y + s * lx + c * ly
            return SIMD3(x, y, terrain.height(x, y) + z)
        }
        let hx = lot.halfSize.x, hy = lot.halfSize.y
        soup.addQuad(w(-hx, -hy, 0.3), w(hx, -hy, 0.3), w(hx, hy, 0.3), w(-hx, hy, 0.3), colour: srgb(80, 80, 82), material: .road)
        let palette = generator.palette.cars
        for (i, car) in lot.cars.enumerated() {
            let ch = cos(car.z), sh = sin(car.z)
            let z0 = terrain.height(car.x, car.y)
            func cw(_ lx: Double, _ ly: Double, _ z: Double) -> SIMD3<Double> {
                SIMD3(car.x + ch * lx - sh * ly, car.y + sh * lx + ch * ly, z0 + z)
            }
            let colour = palette[(i * 7 + Int(car.x.magnitude)) % palette.count]
            addBox(cw, hx: 2.2, hy: 0.9, z0: 0.3, z1: 1.0, colour: colour, material: .paint)
            addBox(cw, hx: 1.2, hy: 0.8, z0: 1.0, z1: 1.45, colour: srgb(30, 36, 44), material: .glass)
        }
    }

    mutating func addBox(_ w: (Double, Double, Double) -> SIMD3<Double>, hx: Double, hy: Double, z0: Double, z1: Double, colour: SIMD3<Float>, material: Material = .opaque) {
        let cs = [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)]
        for k in 0..<4 {
            let (ax, ay) = cs[k], (bx, by) = cs[(k + 1) % 4]
            soup.addQuad(w(ax, ay, z0), w(bx, by, z0), w(bx, by, z1), w(ax, ay, z1), colour: colour, material: material)
        }
        soup.addQuad(w(-hx, -hy, z1), w(hx, -hy, z1), w(hx, hy, z1), w(-hx, hy, z1), colour: colour, material: material)
    }

    // MARK: Aircraft

    /// Adds the procedural aircraft at a world position (ENU) with heading (rad from north, clockwise), pitch and roll.
    public mutating func addAircraft(at p: SIMD3<Double>, heading: Double, pitch: Double, roll: Double, accent: SIMD3<Float>) {
        let q = Quaternion(roll: roll, pitch: pitch, yaw: heading)   // body -> NED
        func world(_ b: SIMD3<Double>) -> SIMD3<Double> {
            let ned = q.rotate(b)
            return p + SIMD3(ned.y, ned.x, -ned.z)                   // NED -> ENU
        }
        for t in AircraftMesh.build() {
            let colour: SIMD3<Float>, mat: Material
            switch t.part {
            case .paint: colour = srgb(232, 232, 228); mat = .paint
            case .accent: colour = accent; mat = .paint
            case .glass: colour = srgb(28, 34, 42); mat = .glass
            case .metal: colour = srgb(150, 152, 156); mat = .paint
            case .tyre: colour = srgb(24, 24, 26); mat = .opaque
            case .prop: continue // a spinning disc needs transparency; not drawn in the CPU preview
            }
            soup.addFlat(world(t.a), world(t.c), world(t.b), colour: colour, material: mat)
        }
        stats["aircraft", default: 0] += 1
    }

    // MARK: Trees

    public mutating func addTree(_ t: Tree, detail: Int) {
        let p = t.position
        let trunk = srgb(70, 54, 40)
        let jitter = Float(0.88 + 0.24 * Hash.unit(Hash.combine(UInt64(bitPattern: Int64(p.x * 10)), UInt64(bitPattern: Int64(p.y * 10)))))
        let col = t.colour * jitter
        if t.conifer {
            let sides = detail >= 2 ? 7 : 4
            let tiers = detail >= 2 ? 3 : 1
            let crownBase = t.height * 0.18
            for tier in 0..<tiers {
                let frac0 = Double(tier) / Double(tiers)
                let zb = p.z + crownBase + (t.height - crownBase) * frac0 * 0.75
                let zt = p.z + t.height * (tier == tiers - 1 ? 1.0 : 0.55 + 0.3 * frac0 + 0.25)
                let r = t.crownRadius * (1 - frac0 * 0.45)
                addCone(SIMD3(p.x, p.y, zb), radius: r, top: zt, sides: sides, colour: col * Float(0.9 + 0.1 * Double(tier)))
            }
            if detail >= 2 { addCone(SIMD3(p.x, p.y, p.z - 0.5), radius: 0.35, top: p.z + crownBase + 1, sides: 4, colour: trunk, material: .opaque) }
        } else {
            let cz = p.z + t.height - t.crownRadius * 1.05
            if detail >= 2 { addCone(SIMD3(p.x, p.y, p.z - 0.5), radius: 0.3, top: cz, sides: 4, colour: trunk, material: .opaque) }
            addBlob(SIMD3(p.x, p.y, cz), rx: t.crownRadius, rz: t.crownRadius * 1.1, detail: detail, colour: col)
        }
        stats["trees", default: 0] += 1
    }

    mutating func addCone(_ base: SIMD3<Double>, radius: Double, top: Double, sides: Int, colour: SIMD3<Float>, material: Material = .foliage) {
        let apex = SIMD3(base.x, base.y, top)
        let rot = Hash.unit(Hash.combine(UInt64(bitPattern: Int64(base.x * 7)), UInt64(bitPattern: Int64(base.y * 7)))) * 2 * .pi
        for k in 0..<sides {
            let a0 = rot + Double(k) / Double(sides) * 2 * .pi, a1 = rot + Double(k + 1) / Double(sides) * 2 * .pi
            let p0 = base + SIMD3(cos(a0) * radius, sin(a0) * radius, 0)
            let p1 = base + SIMD3(cos(a1) * radius, sin(a1) * radius, 0)
            // Smooth-ish normals: outward + up.
            let slope = radius / max(top - base.z, 0.1)
            func nrm(_ a: Double) -> SIMD3<Float> { simd_normalize(SIMD3(Float(cos(a)), Float(sin(a)), Float(slope))) }
            let am = (a0 + a1) / 2
            soup.add(p0, p1, apex, na: nrm(a0), nb: nrm(a1), nc: nrm(am), colour: colour, material: material)
        }
    }

    /// Low-poly ellipsoid crown (octahedron, subdivided once at detail >= 2) with smooth normals.
    mutating func addBlob(_ c: SIMD3<Double>, rx: Double, rz: Double, detail: Int, colour: SIMD3<Float>) {
        let v: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        let faces = [(0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)]
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = faces.map { (v[$0.0], v[$0.1], v[$0.2]) }
        if detail >= 2 {
            var next: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
            for (a, b, d) in tris {
                let ab = normalize(a + b), bd = normalize(b + d), da = normalize(d + a)
                next += [(a, ab, da), (ab, b, bd), (da, bd, d), (ab, bd, da)]
            }
            tris = next
        }
        // Per-tree lumpiness so crowns are not perfect spheres.
        let seed = Hash.combine(UInt64(bitPattern: Int64(c.x * 13)), UInt64(bitPattern: Int64(c.y * 13)))
        func lump(_ u: SIMD3<Double>) -> Double {
            1 + 0.16 * sin(u.x * 3.1 + Double(seed % 7)) * cos(u.y * 2.7 + Double(seed % 5)) + 0.08 * sin(u.z * 4.3)
        }
        for (a, b, d) in tris {
            func p(_ u: SIMD3<Double>) -> SIMD3<Double> { let l = lump(u); return c + SIMD3(u.x * rx * l, u.y * rx * l, u.z * rz * l) }
            func n(_ u: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(u.x), Float(u.y), Float(u.z)) }
            soup.add(p(a), p(b), p(d), na: n(a), nb: n(b), nc: n(d), colour: colour, material: .foliage)
        }
    }
}
