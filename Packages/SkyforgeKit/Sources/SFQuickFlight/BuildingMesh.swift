// SKYFORGE — Apache-2.0
// GPU-ready building geometry from footprints: indexed 32-byte vertices carrying wall coordinates
// (metres along the wall, storeys above the base) and a style, so the world shader draws storeys,
// window bays, glazing and cladding per pixel; pitched roofs on houses, parapets, rooftop plant and
// penthouses on larger buildings. Pure Swift (Linux-testable); the renderer uploads the bytes as they are.
import Foundation
import SFMath
import SFPreview
import SFWorldGen

/// Facade families (the shader's `style`).
public enum BuildingStyle: UInt8, Sendable, CaseIterable {
    case house = 0, residential = 1, commercial = 2, industrial = 3, tower = 4, civic = 5

    /// Storey height in metres (the wall coordinate v counts storeys).
    public var storeyHeight: Double {
        switch self {
        case .house: return 2.9
        case .residential: return 3.0
        case .commercial: return 3.8
        case .industrial: return 5.0
        case .tower: return 3.9
        case .civic: return 4.0
        }
    }
}

public struct BuildingMesh: Sendable {
    /// Bytes per vertex: float3 position | int8 normal xyz, int8 flags | uint8 rgb (sqrt-encoded linear
    /// albedo), uint8 material | float2 uv | uint8 seed, style, half length (0.5 m units), storeys.
    public static let stride = 32
    public struct Cell: Sendable, Equatable {
        public var indexStart: Int, indexCount: Int
        public var min: SIMD3<Float>, max: SIMD3<Float>
    }
    public var vertices: [UInt8] = []
    public var indices: [UInt32] = []
    public var cells: [Cell] = []
    public var buildingCount = 0
    public var vertexCount: Int { vertices.count / Self.stride }
    public var triangleCount: Int { indices.count / 3 }
    public init() {}

    /// Position of vertex `i` (tests, CPU preview).
    public func position(_ i: Int) -> SIMD3<Float> {
        vertices.withUnsafeBytes { SIMD3($0.loadUnaligned(fromByteOffset: i * 32, as: Float.self), $0.loadUnaligned(fromByteOffset: i * 32 + 4, as: Float.self),
                                         $0.loadUnaligned(fromByteOffset: i * 32 + 8, as: Float.self)) }
    }
    public func normal(_ i: Int) -> SIMD3<Float> {
        SIMD3(Float(Int8(bitPattern: vertices[i * 32 + 12])), Float(Int8(bitPattern: vertices[i * 32 + 13])), Float(Int8(bitPattern: vertices[i * 32 + 14]))) / 127
    }
    public func material(_ i: Int) -> UInt8 { vertices[i * 32 + 19] }
    public func albedo(_ i: Int) -> SIMD3<Float> {
        let c = SIMD3(Float(vertices[i * 32 + 16]), Float(vertices[i * 32 + 17]), Float(vertices[i * 32 + 18])) / 255
        return c * c
    }

    /// The same triangles as a soup (CPU preview and tests).
    public func soup() -> TriangleSoup {
        var s = TriangleSoup(origin: .zero)
        for t in 0..<triangleCount {
            let i = (0..<3).map { Int(indices[3 * t + $0]) }
            let p = i.map { position($0) }, n = i.map { normal($0) }
            func d(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
            s.add(d(p[0]), d(p[1]), d(p[2]), na: n[0], nb: n[1], nc: n[2], colour: albedo(i[0]), material: .opaque)
        }
        return s
    }
}

public enum BuildingMeshBuilder {
    // Linear-albedo palettes per style.
    static let housePalette: [SIMD3<Float>] = [
        srgb(232, 226, 212), srgb(214, 208, 196), srgb(196, 200, 204), srgb(178, 168, 150), srgb(160, 172, 184), srgb(204, 190, 160),
        srgb(140, 124, 108), srgb(150, 92, 76), srgb(120, 134, 128), srgb(226, 220, 200), srgb(170, 150, 126), srgb(108, 116, 128),
    ]
    static let residentialPalette: [SIMD3<Float>] = [
        srgb(158, 98, 80), srgb(176, 120, 96), srgb(206, 196, 178), srgb(188, 184, 176), srgb(170, 150, 128), srgb(214, 210, 200), srgb(136, 110, 96),
    ]
    static let commercialPalette: [SIMD3<Float>] = [
        srgb(188, 186, 180), srgb(170, 166, 158), srgb(204, 198, 186), srgb(148, 150, 154), srgb(180, 170, 154), srgb(126, 128, 132), srgb(196, 180, 160),
    ]
    static let industrialPalette: [SIMD3<Float>] = [
        srgb(206, 206, 202), srgb(188, 190, 190), srgb(214, 208, 194), srgb(170, 176, 180), srgb(196, 198, 190), srgb(160, 170, 160),
    ]
    static let towerPalette: [SIMD3<Float>] = [
        srgb(86, 98, 110), srgb(104, 112, 116), srgb(70, 84, 96), srgb(122, 120, 112), srgb(92, 104, 100), srgb(140, 144, 148), srgb(78, 80, 86),
    ]
    static let roofPalette: [SIMD3<Float>] = [srgb(92, 90, 88), srgb(70, 70, 74), srgb(112, 104, 96), srgb(128, 82, 66), srgb(84, 88, 84), srgb(130, 128, 124)]
    static let flatRoofPalette: [SIMD3<Float>] = [srgb(150, 150, 146), srgb(124, 124, 122), srgb(176, 176, 170), srgb(98, 98, 100), srgb(200, 200, 196)]

    public static func style(for b: OSMBuilding, area: Double) -> BuildingStyle {
        if b.heightMetres >= 45 { return .tower }
        switch b.kind {
        case "house", "detached", "semidetached_house", "terrace", "bungalow", "cabin", "farm", "garage", "shed", "outbuilding":
            return .house
        case "industrial", "warehouse", "hangar", "factory", "manufacture", "agricultural", "service", "transportation":
            return .industrial
        case "apartments", "residential", "hotel":
            return (area < 330 && b.heightMetres < 11) ? .house : .residential
        case "commercial", "office", "retail", "entertainment":
            return .commercial
        case "church", "religious", "school", "education", "hospital", "medical", "civic", "military":
            return .civic
        default:
            if area < 330 && b.heightMetres < 11 { return .house }
            if area > 2_200 && b.heightMetres < 15 { return .industrial }
            return b.heightMetres >= 15 ? .commercial : (area > 700 ? .commercial : .residential)
        }
    }

    /// Inward offset of a counter-clockwise ring by `d` metres (mitred). Nil when an edge would flip or
    /// the result self-intersects (the offset is deeper than the footprint is wide).
    static func inset(_ ring: [SIMD2<Double>], by d: Double) -> [SIMD2<Double>]? {
        let n = ring.count
        guard n >= 3 else { return nil }
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let p = ring[i], a = ring[(i + n - 1) % n], b = ring[(i + 1) % n]
            let e0 = simdNormalize(p - a), e1 = simdNormalize(b - p)
            let n0 = SIMD2(-e0.y, e0.x), n1 = SIMD2(-e1.y, e1.x)
            let k = 1 + (n0 * n1).sum()
            if k < 0.2 { return nil }
            out.append(p + (n0 + n1) / k * d)
        }
        for i in 0..<n {
            let o = ring[(i + 1) % n] - ring[i], q = out[(i + 1) % n] - out[i]
            if (o * q).sum() <= 1e-6 { return nil }
        }
        if OSMGeometry.signedArea(out) <= 0.02 { return nil }
        if n <= 24 {
            func ccw(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
            for i in 0..<n {
                for j in (i + 2)..<max(i + 2, n) where !(i == 0 && j == n - 1) {
                    let a = out[i], b = out[(i + 1) % n], c = out[j], e = out[(j + 1) % n]
                    if ccw(a, b, c) * ccw(a, b, e) < 0 && ccw(c, e, a) * ccw(c, e, b) < 0 { return nil }
                }
            }
        }
        return out
    }

    /// Drops repeated points and vertices on nearly straight runs, so walls are whole facades.
    static func simplified(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var r: [SIMD2<Double>] = []
        for p in ring where r.last.map({ simdLength($0 - p) > 0.25 }) ?? true { r.append(p) }
        if r.count > 1, simdLength(r[0] - r[r.count - 1]) <= 0.25 { r.removeLast() }
        guard r.count > 4 else { return r }
        var keep = [Bool](repeating: true, count: r.count)
        for i in r.indices {
            let a = r[(i + r.count - 1) % r.count], p = r[i], b = r[(i + 1) % r.count]
            let e0 = simdNormalize(p - a), e1 = simdNormalize(b - p)
            if abs(e0.x * e1.y - e0.y * e1.x) < 0.035 && (e0 * e1).sum() > 0 { keep[i] = false }
        }
        let s = r.indices.filter { keep[$0] }.map { r[$0] }
        return s.count >= 3 ? s : r
    }

    /// Builds the mesh. `ground`: terrain height (m). `roofPhoto`: one linear albedo for a footprint (centre,
    /// ring), from the ground photo under it (roofs take it as their fallback colour; nil = palette). Each
    /// roof is one uniform colour with procedural detail in the shader: per-pixel photo roofs carried the
    /// photo's projected blotches and shadows (art round 23). Buildings are grouped into `cell`-metre
    /// squares, each one contiguous index range with bounds for culling.
    public static func build(_ buildings: [OSMBuilding], cell: Double = 500, ground: (Double, Double) -> Double,
                             roofPhoto: ((SIMD2<Double>, [SIMD2<Double>]) -> SIMD3<Float>?)? = nil) -> BuildingMesh {
        var mesh = BuildingMesh()
        struct Item { var b: OSMBuilding; var ring: [SIMD2<Double>]; var centre: SIMD2<Double>; var key: SIMD2<Int> }
        var items: [Item] = []
        items.reserveCapacity(buildings.count)
        for b in buildings {
            var ring = simplified(b.footprint)
            guard ring.count >= 3 else { continue }
            if OSMGeometry.signedArea(ring) < 0 { ring.reverse() }
            let c = ring.reduce(.zero, +) / Double(ring.count)
            items.append(Item(b: b, ring: ring, centre: c, key: SIMD2(Int((c.x / cell).rounded(.down)), Int((c.y / cell).rounded(.down)))))
        }
        items.sort { ($0.key.y, $0.key.x, $0.centre.y, $0.centre.x, $0.b.heightMetres) < ($1.key.y, $1.key.x, $1.centre.y, $1.centre.x, $1.b.heightMetres) }
        mesh.vertices.reserveCapacity(items.count * 40 * 32)
        mesh.indices.reserveCapacity(items.count * 60)

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        func q(_ v: Double) -> UInt8 { UInt8(bitPattern: Int8(max(-127, min(127, (v * 127).rounded())))) }
        func enc(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (max(0, v).squareRoot() * 255).rounded()))) }
        func vertex(_ p: SIMD3<Double>, _ n: SIMD3<Double>, _ colour: SIMD3<Float>, _ material: Material, uv: SIMD2<Double>,
                    style: (UInt8, UInt8, UInt8, UInt8), flags: Int8 = 0) -> UInt32 {
            let i = UInt32(mesh.vertices.count / 32)
            let pf = SIMD3(Float(p.x), Float(p.y), Float(p.z))
            for v in [pf.x, pf.y, pf.z] { withUnsafeBytes(of: v.bitPattern.littleEndian) { mesh.vertices.append(contentsOf: $0) } }
            mesh.vertices.append(contentsOf: [q(n.x), q(n.y), q(n.z), UInt8(bitPattern: flags), enc(colour.x), enc(colour.y), enc(colour.z), material.rawValue])
            for v in [Float(uv.x), Float(uv.y)] { withUnsafeBytes(of: v.bitPattern.littleEndian) { mesh.vertices.append(contentsOf: $0) } }
            mesh.vertices.append(contentsOf: [style.0, style.1, style.2, style.3])
            lo = simdMin(lo, pf); hi = simdMax(hi, pf)
            return i
        }
        func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) { mesh.indices.append(contentsOf: [a, b, c, a, c, d]) }

        var cellStart = 0, current: SIMD2<Int>? = nil
        func closeCell() {
            if mesh.indices.count > cellStart {
                mesh.cells.append(BuildingMesh.Cell(indexStart: cellStart, indexCount: mesh.indices.count - cellStart, min: lo, max: hi))
            }
            cellStart = mesh.indices.count
            lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude); hi = -lo
        }

        for it in items {
            if current != it.key { closeCell(); current = it.key }
            let b = it.b, ring = it.ring, n = ring.count
            let area = OSMGeometry.signedArea(ring)
            guard area > 8 else { continue }
            let style = style(for: b, area: area)
            let h0 = Hash.int(Int((ring[0].x * 10).rounded()), Int((ring[0].y * 10).rounded()), seed: 0x0B17_D1A6)
            func rnd(_ k: UInt64) -> Double { Hash.unit(Hash.mix(h0 ^ (k &* 0x9E37_79B9))) }
            let seed = UInt8(truncatingIfNeeded: h0 >> 8)
            let base = OSMMeshBuilder.baseHeight(ring, ground: ground)
            let floating = b.minHeightMetres > 0.5
            let bottom = floating ? base + b.minHeightMetres : base - 1.5
            var perimeter = 0.0
            for i in 0..<n { perimeter += simdLength(ring[(i + 1) % n] - ring[i]) }

            // Roof form: pitched (an inset ring raised by the pitch) for houses, otherwise flat with a parapet.
            var pitched: (ring: [SIMD2<Double>], rise: Double, depth: Double)?
            let shape = b.tags["roof:shape"]
            if !floating && (style == .house || shape == "gabled" || shape == "hipped" || shape == "pyramidal") && shape != "flat" && n <= 16 && area < 700 {
                let pitch = (22 + 13 * rnd(1)) * Double.pi / 180
                for f in [1.9, 1.6, 1.3, 1.0, 0.7] {
                    let d = f * area / perimeter
                    if let r = inset(ring, by: d) { pitched = (r, d * tan(pitch), d); break }
                }
            }
            var height = max(2.4, b.heightMetres)
            if let p = pitched { height = max(2.5, height - 0.8 * p.rise) }     // surveyed heights are ridge heights
            let top = base + height
            let storeyH = style.storeyHeight
            let storeys = floating ? max(1, Int(((height - b.minHeightMetres) / storeyH).rounded())) : max(1, Int((height / storeyH).rounded()))
            let parapet = pitched != nil || floating ? 0.0 : (style == .house ? 0.25 : (style == .tower ? 1.4 : 0.5 + 0.5 * rnd(2)))
            let fh = (top - (floating ? bottom : base)) / Double(storeys)       // actual storey height

            // Colours.
            var wall: SIMD3<Float>
            if let c = b.wallColour { wall = c } else {
                let pal: [SIMD3<Float>]
                switch style {
                case .house: pal = housePalette
                case .residential: pal = residentialPalette
                case .commercial, .civic: pal = commercialPalette
                case .industrial: pal = industrialPalette
                case .tower: pal = towerPalette
                }
                wall = pal[Int(h0 % UInt64(pal.count))] * Float(0.9 + 0.2 * rnd(3))
            }
            var roof: SIMD3<Float>
            let photoRoof = false                                           // shader photo-roof bit: off (one colour per roof)
            if let c = b.roofColour { roof = c } else if let c = roofPhoto?(it.centre, it.ring) {
                roof = c
            } else {
                let pal = pitched != nil ? roofPalette : flatRoofPalette
                roof = pal[Int((h0 >> 16) % UInt64(pal.count))] * Float(0.9 + 0.2 * rnd(4))
            }
            if style == .tower { roof = flatRoofPalette[Int((h0 >> 16) % UInt64(flatRoofPalette.count))] * 0.8 }
            let wallStyle = { (halfLen: Double) -> (UInt8, UInt8, UInt8, UInt8) in
                (seed, style.rawValue, UInt8(max(1, min(255, (halfLen * 2).rounded()))), UInt8(min(255, storeys)))
            }

            // Walls: one quad per facade, u centred on the facade (metres), v in storeys above the base.
            for i in 0..<n {
                let p = ring[i], pn = ring[(i + 1) % n]
                let d = pn - p, len = simdLength(d)
                guard len > 0.05 else { continue }
                let nrm = SIMD3(d.y / len, -d.x / len, 0)
                let st = wallStyle(len / 2)
                let vb = (bottom - (floating ? bottom : base)) / fh, vt = Double(storeys) + parapet / fh
                let a = vertex(SIMD3(p.x, p.y, bottom), nrm, wall, .wall, uv: SIMD2(-len / 2, vb), style: st)
                let c1 = vertex(SIMD3(pn.x, pn.y, bottom), nrm, wall, .wall, uv: SIMD2(len / 2, vb), style: st)
                let c2 = vertex(SIMD3(pn.x, pn.y, top + parapet), nrm, wall, .wall, uv: SIMD2(len / 2, vt), style: st)
                let e = vertex(SIMD3(p.x, p.y, top + parapet), nrm, wall, .wall, uv: SIMD2(-len / 2, vt), style: st)
                quad(a, c1, c2, e)
            }

            // Roof. Style byte 2: bit 0 = may take the ground photo's colour, bit 1 = pitched.
            let up = SIMD3<Double>(0, 0, 1)
            func roofStyle(_ pitchedRoof: Bool, photo: Bool) -> (UInt8, UInt8, UInt8, UInt8) {
                (seed, style.rawValue, (photo ? 1 : 0) | (pitchedRoof ? 2 : 0), UInt8(min(255, storeys)))
            }
            func cap(_ r: [SIMD2<Double>], z: Double, colour: SIMD3<Float>, st: (UInt8, UInt8, UInt8, UInt8)) {
                let first = UInt32(mesh.vertices.count / 32)
                for p in r { _ = vertex(SIMD3(p.x, p.y, z), up, colour, .roof, uv: p - it.centre, style: st) }
                for t in OSMGeometry.triangulate(r) { mesh.indices.append(contentsOf: [first + UInt32(t.x), first + UInt32(t.y), first + UInt32(t.z)]) }
            }
            if let pr = pitched {
                let st = roofStyle(true, photo: photoRoof)
                let eave = 0.35                                              // overhang
                let outer = inset(ring, by: -eave) ?? ring
                for i in 0..<n {
                    let j = (i + 1) % n
                    let a = SIMD3(outer[i].x, outer[i].y, top - eave * pr.rise / max(0.5, pr.depth)), bq = SIMD3(outer[j].x, outer[j].y, a.z)
                    let c = SIMD3(pr.ring[j].x, pr.ring[j].y, top + pr.rise), e = SIMD3(pr.ring[i].x, pr.ring[i].y, top + pr.rise)
                    var nn = cross(bq - a, e - a)
                    let l = (nn * nn).sum().squareRoot()
                    guard l > 1e-9 else { continue }
                    nn /= l
                    if nn.z < 0 { nn = -nn }
                    let v0 = vertex(a, nn, roof, .roof, uv: outer[i] - it.centre, style: st), v1 = vertex(bq, nn, roof, .roof, uv: outer[j] - it.centre, style: st)
                    let v2 = vertex(c, nn, roof, .roof, uv: pr.ring[j] - it.centre, style: st), v3 = vertex(e, nn, roof, .roof, uv: pr.ring[i] - it.centre, style: st)
                    quad(v0, v1, v2, v3)
                }
                cap(pr.ring, z: top + pr.rise, colour: roof, st: st)
            } else {
                cap(ring, z: top, colour: roof, st: roofStyle(false, photo: photoRoof))
                if floating {                                                  // underside of a raised part
                    let first = UInt32(mesh.vertices.count / 32)
                    for p in ring { _ = vertex(SIMD3(p.x, p.y, bottom), -up, wall * 0.6, .roof, uv: p - it.centre, style: roofStyle(false, photo: false)) }
                    for t in OSMGeometry.triangulate(ring) { mesh.indices.append(contentsOf: [first + UInt32(t.x), first + UInt32(t.z), first + UInt32(t.y)]) }
                }
                // Rooftop plant: boxes on larger flat roofs; a set-back penthouse on towers.
                let plant = srgb(150, 152, 150) * Float(0.8 + 0.3 * rnd(5))
                let plantStyle = roofStyle(false, photo: false)
                func box(centre c: SIMD2<Double>, half hx: Double, _ hy: Double, angle: Double, z0: Double, z1: Double) {
                    let ca = cos(angle), sa = sin(angle)
                    let corners = [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)].map { SIMD2(c.x + ca * $0.0 - sa * $0.1, c.y + sa * $0.0 + ca * $0.1) }
                    guard corners.allSatisfy({ OSMGeometry.contains(ring, $0) }) else { return }
                    for i in 0..<4 {
                        let p = corners[i], pn = corners[(i + 1) % 4]
                        let d = simdNormalize(pn - p), nrm = SIMD3(d.y, -d.x, 0)
                        let a = vertex(SIMD3(p.x, p.y, z0), nrm, plant * 0.85, .roof, uv: p - it.centre, style: plantStyle)
                        let b1 = vertex(SIMD3(pn.x, pn.y, z0), nrm, plant * 0.85, .roof, uv: pn - it.centre, style: plantStyle)
                        let c1 = vertex(SIMD3(pn.x, pn.y, z1), nrm, plant * 0.85, .roof, uv: pn - it.centre, style: plantStyle)
                        let e = vertex(SIMD3(p.x, p.y, z1), nrm, plant * 0.85, .roof, uv: p - it.centre, style: plantStyle)
                        quad(a, b1, c1, e)
                    }
                    cap(corners, z: z1, colour: plant, st: plantStyle)
                }
                if !floating && style != .house && area > 260 {
                    let xs = ring.map(\.x), ys = ring.map(\.y)
                    let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
                    // The longest edge sets the plant's orientation.
                    var ang = 0.0, best = 0.0
                    for i in 0..<n { let d = ring[(i + 1) % n] - ring[i]; let l = simdLength(d); if l > best { best = l; ang = atan2(d.y, d.x) } }
                    if style == .tower, let pent = inset(ring, by: (0.22 + 0.12 * rnd(6)) * 2 * area / perimeter) {
                        let ph = 4 + 6 * rnd(7)
                        for i in 0..<pent.count {
                            let p = pent[i], pn = pent[(i + 1) % pent.count]
                            let d = pn - p, len = simdLength(d)
                            guard len > 0.05 else { continue }
                            let nrm = SIMD3(d.y / len, -d.x / len, 0)
                            let a = vertex(SIMD3(p.x, p.y, top), nrm, wall * 0.9, .roof, uv: p - it.centre, style: plantStyle)
                            let b1 = vertex(SIMD3(pn.x, pn.y, top), nrm, wall * 0.9, .roof, uv: pn - it.centre, style: plantStyle)
                            let c1 = vertex(SIMD3(pn.x, pn.y, top + ph), nrm, wall * 0.9, .roof, uv: pn - it.centre, style: plantStyle)
                            let e = vertex(SIMD3(p.x, p.y, top + ph), nrm, wall * 0.9, .roof, uv: p - it.centre, style: plantStyle)
                            quad(a, b1, c1, e)
                        }
                        cap(pent, z: top + ph, colour: roof * 0.9, st: plantStyle)
                    }
                    let count = min(7, max(1, Int(area / 450)))
                    for k in 0..<count {
                        let c = SIMD2(x0 + (x1 - x0) * (0.12 + 0.76 * rnd(UInt64(20 + 3 * k))), y0 + (y1 - y0) * (0.12 + 0.76 * rnd(UInt64(21 + 3 * k))))
                        let s = 1.2 + 2.2 * rnd(UInt64(22 + 3 * k))
                        box(centre: c, half: s, s * (0.6 + 0.6 * rnd(UInt64(40 + k))), angle: ang, z0: top, z1: top + 1.1 + 1.6 * rnd(UInt64(60 + k)))
                    }
                }
            }
            mesh.buildingCount += 1
        }
        closeCell()
        return mesh
    }

    @inline(__always) static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}
