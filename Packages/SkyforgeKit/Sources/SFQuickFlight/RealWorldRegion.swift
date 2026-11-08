// SKYFORGE — Apache-2.0
// Real-world Quick Flight region: an airport from the bundled OurAirports data, Terrarium
// elevation, free orthoimagery, colour-derived water, indexed terrain chunks for culling and
// tree instances grown on forest pixels (rendered instanced on the GPU).
import Foundation
import SFMath
import SFContent
import SFTerrainCore
import SFImagery
import SFNavData
import SFPreview

public struct TreeInstance: Sendable, Equatable {
    public var position: SIMD3<Float>     // local metres (x east, y north, z AMSL)
    public var height: Float
    public var conifer: Bool
    public var colour: SIMD3<Float>       // linear albedo
}

/// A square of terrain with shared-vertex indexing and bounds for frustum culling.
public struct TerrainChunk: Sendable {
    public var positions: [SIMD3<Float>]  // local metres
    public var normals: [SIMD3<Float>]
    public var indices: [UInt32]
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
}

public struct RealWorldDetail: Sendable, Equatable {
    public var nearHalf: Double, nearStep: Double, midHalf: Double, midStep: Double, farHalf: Double, farStep: Double
    public var imageryNearSize: Int, imageryFarSize: Int
    public var treeRadius: Double, maxTrees: Int
    public init(nearHalf: Double, nearStep: Double, midHalf: Double, midStep: Double, farHalf: Double, farStep: Double,
                imageryNearSize: Int, imageryFarSize: Int, treeRadius: Double, maxTrees: Int) {
        self.nearHalf = nearHalf; self.nearStep = nearStep; self.midHalf = midHalf; self.midStep = midStep
        self.farHalf = farHalf; self.farStep = farStep; self.imageryNearSize = imageryNearSize; self.imageryFarSize = imageryFarSize
        self.treeRadius = treeRadius; self.maxTrees = maxTrees
    }
    public static let phone = RealWorldDetail(nearHalf: 3_000, nearStep: 16, midHalf: 12_000, midStep: 80, farHalf: 40_000, farStep: 400,
                                              imageryNearSize: 2_048, imageryFarSize: 1_024, treeRadius: 1_800, maxTrees: 40_000)
    public static let tablet = RealWorldDetail(nearHalf: 3_200, nearStep: 12, midHalf: 12_000, midStep: 60, farHalf: 40_000, farStep: 300,
                                               imageryNearSize: 3_072, imageryFarSize: 2_048, treeRadius: 2_400, maxTrees: 90_000)
    public static let desktop = RealWorldDetail(nearHalf: 3_200, nearStep: 8, midHalf: 12_000, midStep: 40, farHalf: 40_000, farStep: 200,
                                                imageryNearSize: 4_096, imageryFarSize: 2_048, treeRadius: 3_000, maxTrees: 160_000)
}

public struct RealWorldRegion: FlightWorld {
    public let name: String
    public let airportIdent: String
    public let origin: GeoOrigin
    public let runwayThreshold: SIMD2<Double>
    public let runwayHeading: Double
    public let runwayLengthMetres: Double
    public let runwayWidthMetres: Double
    public let runwayElevation: Double
    public let nearHeights: HeightMosaic
    public let farHeights: HeightMosaic
    public let ground: ImageryGround
    public let attribution: [String]
    public let detail: RealWorldDetail
    /// OpenStreetMap buildings and roads around the airfield (nil when Overpass was unreachable and
    /// nothing was cached; the renderer then shows imagery only).
    public var osm: OSMData? = nil

    public enum LoadError: Error, Equatable { case unknownAirport(String), noRunwayGeometry(String) }

    public func height(_ x: Double, _ y: Double) -> Double {
        // Runways are flat: hold the published elevation over the paved area and blend 60 m out.
        let d = SIMD2(x, y) - runwayThreshold
        let along = (d * runwayDirection).sum()
        let across = abs(d.x * runwayDirection.y - d.y * runwayDirection.x)
        let over = max(max(-along, along - runwayLengthMetres), across - runwayWidthMetres)
        // Near (z14) heights blend into the far (z10) mosaic over the outer 15 % of the near square, so
        // there is no cliff where the two elevation models disagree (mountains: tens of metres).
        let ex = nearHeights.halfExtent - max(abs(x - nearHeights.centre.x), abs(y - nearHeights.centre.y))
        let blendWidth = 0.15 * nearHeights.halfExtent
        let natural: Double
        if ex <= 0 {
            natural = max(0, farHeights.height(x, y))
        } else if ex >= blendWidth {
            natural = max(0, nearHeights.height(x, y))
        } else {
            let t = ex / blendWidth, w = t * t * (3 - 2 * t)
            natural = max(0, farHeights.height(x, y) + (nearHeights.height(x, y) - farHeights.height(x, y)) * w)
        }
        if over <= 0 { return runwayElevation }
        let t = min(1, over / 60)
        return runwayElevation + (natural - runwayElevation) * (t * t * (3 - 2 * t))
    }

    /// Loads an airport region (network once, then the content-store cache).
    public static func load(airport ident: String, detail: RealWorldDetail, transport: any HTTPTransport, cache: KeyedCache?,
                            navData: NavDatabase? = nil, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RealWorldRegion {
        let db = try navData ?? BundledNavData.load()
        guard let apt = db.airport(ident) else { throw LoadError.unknownAirport(ident) }
        guard let rwy = db.runways(at: ident).filter({ $0.hasGeometry && !$0.closed }).max(by: { $0.lengthFeet < $1.lengthFeet }),
              let lo = rwy.low.position, let hi = rwy.high.position else { throw LoadError.noRunwayGeometry(ident) }
        let latC = (lo.latitude + hi.latitude) / 2 * 180 / .pi, lonC = (lo.longitude + hi.longitude) / 2 * 180 / .pi
        let origin = GeoOrigin(latitude: latC, longitude: lonC)
        let a = origin.local(latitude: lo.latitude * 180 / .pi, longitude: lo.longitude * 180 / .pi)
        let b = origin.local(latitude: hi.latitude * 180 / .pi, longitude: hi.longitude * 180 / .pi)
        let thr = SIMD2(a.east, a.north), end = SIMD2(b.east, b.north)
        let v = end - thr
        let len = (v * v).sum().squareRoot()
        let heading = atan2(v.x, v.y)
        let elevFt = rwy.low.elevationFeet ?? apt.elevationFeet ?? 0
        progress("Elevation")
        let ts = TerrainStreamer(transport: transport, cache: cache, baseline: try? GlobalDEM.bundled())
        // The sharp near layer sits 900 m toward the approach, so both the final-approach start
        // (2 km before the threshold) and the departure end lie well inside it.
        let nearCentre = -(v / max(len, 1)) * 900
        async let hNear = HeightMosaic.build(origin: origin, centre: nearCentre, halfExtent: detail.nearHalf, size: 512, zoom: 14, streamer: ts)
        async let hFar = HeightMosaic.build(origin: origin, centre: .zero, halfExtent: detail.farHalf, size: 512, zoom: 10, streamer: ts)
        progress("Imagery")
        let usgs = USGSImageryProvider()
        let nearProvider: any ImageryProvider = usgs.covers(latitude: latC, longitude: lonC) ? usgs : Sentinel2CloudlessProvider()
        let farProvider = Sentinel2CloudlessProvider()
        let sNear = ImageryStreamer(provider: nearProvider, transport: transport, cache: cache)
        let sFar = ImageryStreamer(provider: farProvider, transport: transport, cache: cache)
        async let iNear = ImageryMosaic.build(origin: origin, centre: nearCentre, halfExtent: detail.nearHalf, size: detail.imageryNearSize,
                                              provider: nearProvider, streamer: sNear)
        async let iFar = ImageryMosaic.build(origin: origin, centre: .zero, halfExtent: detail.farHalf, size: detail.imageryFarSize,
                                             provider: farProvider, streamer: sFar)
        async let osmFetch = OSMService(transport: transport, cache: cache).data(around: origin, halfExtent: min(detail.nearHalf, 3_000))
        let (hn, hf, inr, ifr) = await (hNear, hFar, iNear, iFar)
        progress("Buildings")
        let osm = await osmFetch
        progress("Land cover")
        var attribution = [nearProvider.attribution]
        if farProvider.id != nearProvider.id { attribution.append(farProvider.attribution) }
        attribution.append("Elevation: Terrarium tiles (Mapzen/Tilezen; SRTM, USGS 3DEP and others)")
        attribution.append("Airports: OurAirports (public domain)")
        if let o = osm, !(o.buildings.isEmpty && o.roads.isEmpty) { attribution.append(OSMData.attribution) }
        var region = RealWorldRegion(name: apt.name, airportIdent: ident, origin: origin, runwayThreshold: thr, runwayHeading: heading,
                               runwayLengthMetres: len, runwayWidthMetres: rwy.widthMetres, runwayElevation: elevFt * Units.feetToMetres,
                               nearHeights: hn, farHeights: hf, ground: ImageryGround(near: inr, far: ifr, grade: true), attribution: attribution, detail: detail)
        region.osm = osm
        return region
    }

    /// OSM buildings and roads as one mesh in local metres (nil without OSM data).
    public func osmMesh() -> TriangleSoup? {
        guard let o = osm, !(o.buildings.isEmpty && o.roads.isEmpty) else { return nil }
        let roads = OSMMeshBuilder.roads(o.roads) { self.height($0, $1) }
        let buildings = OSMMeshBuilder.buildings(o.buildings) { self.height($0, $1) }
        var soup = TriangleSoup(origin: .zero)
        let perVertex = !roads.vertexAlbedo.isEmpty || !buildings.vertexAlbedo.isEmpty
        for part in [roads, buildings] {
            soup.positions += part.positions; soup.normals += part.normals
            soup.albedo += part.albedo; soup.material += part.material
            if perVertex { soup.vertexAlbedo += part.vertexAlbedo.isEmpty ? part.albedo.flatMap { [$0, $0, $0] } : part.vertexAlbedo }
        }
        return soup
    }

    // MARK: meshes

    /// Indexed terrain in rings (near/mid/far), split into chunks of `quads`² cells for culling.
    public func terrainChunks(quads: Int = 48) -> [TerrainChunk] {
        var chunks: [TerrainChunk] = []
        let d = detail
        let nc = nearHeights.centre
        // Ring squares: the near ring follows the near mosaic's centre; mid and far are centred on the field.
        func ring(centre: SIMD2<Double>, half: Double, step: Double, skipCentre: SIMD2<Double>, skip: Double, lower: Float) {
            let cellsPerSide = Int((2 * half / step).rounded())
            let chunksPerSide = (cellsPerSide + quads - 1) / quads
            // Snap the ring origin to its step so neighbouring rings share vertex lines.
            let ox = (centre.x / step).rounded() * step - half, oy = (centre.y / step).rounded() * step - half
            for cj in 0..<chunksPerSide {
                for ci in 0..<chunksPerSide {
                    let x0 = ox + Double(ci * quads) * step, y0 = oy + Double(cj * quads) * step
                    let span = Double(quads) * step
                    // Skip chunks fully inside the finer ring.
                    if skip > 0 && x0 >= skipCentre.x - skip && x0 + span <= skipCentre.x + skip
                        && y0 >= skipCentre.y - skip && y0 + span <= skipCentre.y + skip { continue }
                    let n = quads + 1
                    var pos = [SIMD3<Float>](), nrm = [SIMD3<Float>]()
                    pos.reserveCapacity(n * n); nrm.reserveCapacity(n * n)
                    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                    for j in 0..<n {
                        for i in 0..<n {
                            let x = x0 + Double(i) * step, y = y0 + Double(j) * step
                            let z = Float(height(x, y)) - lower
                            let hx = height(x + step, y) - height(x - step, y), hy = height(x, y + step) - height(x, y - step)
                            let nn = normalize(SIMD3(-hx / (2 * step), -hy / (2 * step), 1))
                            let p = SIMD3(Float(x), Float(y), z)
                            pos.append(p); nrm.append(SIMD3(Float(nn.x), Float(nn.y), Float(nn.z)))
                            lo = simdMin(lo, p); hi = simdMax(hi, p)
                        }
                    }
                    var idx = [UInt32]()
                    idx.reserveCapacity(quads * quads * 6)
                    for j in 0..<quads {
                        for i in 0..<quads {
                            let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), e = c + 1
                            idx += [a, b, e, a, e, c]
                        }
                    }
                    chunks.append(TerrainChunk(positions: pos, normals: nrm, indices: idx, boundsMin: lo, boundsMax: hi))
                }
            }
        }
        ring(centre: nc, half: d.nearHalf, step: d.nearStep, skipCentre: .zero, skip: 0, lower: 0)
        ring(centre: .zero, half: d.midHalf, step: d.midStep, skipCentre: nc, skip: d.nearHalf - d.midStep, lower: 0.4)
        ring(centre: .zero, half: d.farHalf, step: d.farStep, skipCentre: .zero, skip: d.midHalf - d.farStep, lower: 1.5)
        return chunks
    }

    /// Trees on forest pixels: a jittered 7 m lattice kept with probability ∝ forest score,
    /// excluding water, the runway strip and its approach surfaces. Nearest the airfield first.
    public func trees() -> [TreeInstance] {
        var out: [TreeInstance] = []
        let r = detail.treeRadius, cell = 7.0
        // OSM footprints by 40 m grid cell, so trees never grow through buildings.
        var footprints: [SIMD2<Int>: [[SIMD2<Double>]]] = [:]
        for b in osm?.buildings ?? [] {
            let xs = b.footprint.map(\.x), ys = b.footprint.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { continue }
            for cy in Int((y0 / 40).rounded(.down))...Int((y1 / 40).rounded(.down)) {
                for cx in Int((x0 / 40).rounded(.down))...Int((x1 / 40).rounded(.down)) { footprints[SIMD2(cx, cy), default: []].append(b.footprint) }
            }
        }
        func inBuilding(_ x: Double, _ y: Double) -> Bool {
            guard let list = footprints[SIMD2(Int((x / 40).rounded(.down)), Int((y / 40).rounded(.down)))] else { return false }
            return list.contains { OSMGeometry.contains($0, SIMD2(x, y)) }
        }
        let near = ground.near
        var y = -r
        while y < r {
            var x = -r
            while x < r {
                defer { x += cell }
                if x * x + y * y > r * r { continue }
                var rng = SplitMix64(seed: Hash.int(Int((x / cell).rounded()), Int((y / cell).rounded()), seed: 0x7EE5))
                let px = nearHeights.centre.x + x + Hash.unit(rng.next()) * cell, py = nearHeights.centre.y + y + Hash.unit(rng.next()) * cell
                guard let c = near.sample(px, py), let g = ground.ground(px, py) else { continue }
                let lc = LandCover.classify(c)
                if Hash.unit(rng.next()) > Double(lc.forest) * 0.9 || g.water > 0.3 { continue }
                if nearRunway(px, py) || inBuilding(px, py) { continue }
                let h = 9 + Hash.unit(rng.next()) * 10
                let conifer = Hash.unit(rng.next()) < 0.55
                let tint = g.albedo * 1.9 * Float(0.85 + 0.3 * Hash.unit(rng.next()))
                out.append(TreeInstance(position: SIMD3(Float(px), Float(py), Float(height(px, py))), height: Float(h), conifer: conifer, colour: tint))
            }
            y += cell
        }
        let c = SIMD2<Float>(Float(nearHeights.centre.x), Float(nearHeights.centre.y))
        func d2(_ t: TreeInstance) -> Float { let d = SIMD2(t.position.x, t.position.y) - c; return (d * d).sum() }
        out.sort { d2($0) < d2($1) }
        if out.count > detail.maxTrees { out.removeLast(out.count - detail.maxTrees) }
        return out
    }

    func nearRunway(_ x: Double, _ y: Double) -> Bool {
        let d = SIMD2(x, y) - runwayThreshold
        let along = (d * runwayDirection).sum()
        let across = abs(d.x * runwayDirection.y - d.y * runwayDirection.x)
        if along > -60 && along < runwayLengthMetres + 60 && across < runwayWidthMetres / 2 + 75 { return true }
        let past = along < 0 ? -along : along - runwayLengthMetres
        return past > 0 && past < 1_500 && across < runwayWidthMetres / 2 + 60 + past * 0.15
    }
}

@inline(__always) func simdMin(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)) }
@inline(__always) func simdMax(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)) }
