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
    /// Sharp camera-following imagery square (US aerial photo only, z18 ≈ 0.5 m/px); size 0 = none.
    /// The region loads it around the start view; the app re-streams it ahead of the aircraft.
    public var imageryDetailHalf: Double, imageryDetailSize: Int
    public init(nearHalf: Double, nearStep: Double, midHalf: Double, midStep: Double, farHalf: Double, farStep: Double,
                imageryNearSize: Int, imageryFarSize: Int, treeRadius: Double, maxTrees: Int,
                imageryDetailHalf: Double = 1_200, imageryDetailSize: Int = 0) {
        self.imageryDetailHalf = imageryDetailHalf; self.imageryDetailSize = imageryDetailSize
        self.nearHalf = nearHalf; self.nearStep = nearStep; self.midHalf = midHalf; self.midStep = midStep
        self.farHalf = farHalf; self.farStep = farStep; self.imageryNearSize = imageryNearSize; self.imageryFarSize = imageryFarSize
        self.treeRadius = treeRadius; self.maxTrees = maxTrees
    }
    public static let phone = RealWorldDetail(nearHalf: 3_000, nearStep: 16, midHalf: 12_000, midStep: 80, farHalf: 40_000, farStep: 400,
                                              imageryNearSize: 2_048, imageryFarSize: 1_024, treeRadius: 1_800, maxTrees: 40_000,
                                              imageryDetailHalf: 600, imageryDetailSize: 2_048)
    public static let tablet = RealWorldDetail(nearHalf: 3_200, nearStep: 12, midHalf: 12_000, midStep: 60, farHalf: 40_000, farStep: 300,
                                               imageryNearSize: 3_072, imageryFarSize: 2_048, treeRadius: 2_400, maxTrees: 90_000,
                                               imageryDetailHalf: 600, imageryDetailSize: 2_048)
    public static let desktop = RealWorldDetail(nearHalf: 3_200, nearStep: 12, midHalf: 12_000, midStep: 48, farHalf: 40_000, farStep: 240,
                                                imageryNearSize: 4_096, imageryFarSize: 2_048, treeRadius: 3_000, maxTrees: 75_000,
                                                imageryDetailHalf: 800, imageryDetailSize: 4_096)
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
    public internal(set) var ground: ImageryGround
    public let attribution: [String]
    public let detail: RealWorldDetail
    /// OpenStreetMap buildings and roads around the airfield (nil when Overpass was unreachable and
    /// nothing was cached; the renderer then shows imagery only).
    public var osm: OSMData? = nil
    /// Procedural buildings placed on built-up imagery where OSM has none (empty when OSM has buildings).
    public var fallbackBuildings: [OSMBuilding] = []

    /// Buildings to draw and to keep trees out of: OSM where available, otherwise the procedural fallback.
    public var buildings: [OSMBuilding] { (osm?.buildings.isEmpty == false) ? osm!.buildings : fallbackBuildings }

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
        // Sharp layer (about 0.6 m/px at phone tier, z18) over the start view's foreground: 1.5 km before
        // the threshold, just ahead of the chase camera on the 2 km final. Aerial photo (USGS) only:
        // Sentinel-2 is 10 m native. The app re-streams it ahead of the aircraft in flight.
        let detailCentre = thr - (v / max(len, 1)) * 1_500
        let wantDetail = detail.imageryDetailSize > 0 && nearProvider.id == usgs.id
        let detailProvider = USGSImageryProvider(maxZoom: 18)
        let sDetail = ImageryStreamer(provider: detailProvider, transport: transport, cache: cache)
        async let iDetail: ImageryMosaic? = wantDetail
            ? ImageryMosaic.build(origin: origin, centre: detailCentre, halfExtent: detail.imageryDetailHalf, size: detail.imageryDetailSize,
                                  provider: detailProvider, streamer: sDetail) : nil
        async let osmFetch = OSMService(transport: transport, cache: cache).data(around: origin, halfExtent: min(detail.nearHalf, 3_000))
        let (hn, hf, inr, ifr) = await (hNear, hFar, iNear, iFar)
        let idt = await iDetail
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
                               nearHeights: hn, farHeights: hf, ground: ImageryGround(near: inr, far: ifr, detail: idt, grade: true), attribution: attribution, detail: detail)
        // Dark runway and apron asphalt reads as water by colour; real water is flat and sizeable.
        region.ground = region.ground.cleaningWater(exclude: region.pavedArea) { x, y in max(0, hn.height(x, y)) }
        region.osm = osm
        if osm?.buildings.isEmpty != false { region.fallbackBuildings = region.proceduralBuildings() }
        return region
    }

    /// OSM buildings and roads as one mesh in local metres (nil without OSM data).
    public func osmMesh() -> TriangleSoup? {
        let roadList = osm?.roads ?? [], buildingList = buildings
        guard !(roadList.isEmpty && buildingList.isEmpty) else { return nil }
        let roads = OSMMeshBuilder.roads(roadList) { self.height($0, $1) }
        let buildings = OSMMeshBuilder.buildings(buildingList) { self.height($0, $1) }
        var soup = TriangleSoup(origin: .zero)
        let perVertex = !roads.vertexAlbedo.isEmpty || !buildings.vertexAlbedo.isEmpty
        for part in [roads, buildings] {
            soup.positions += part.positions; soup.normals += part.normals
            soup.albedo += part.albedo; soup.material += part.material
            if perVertex { soup.vertexAlbedo += part.vertexAlbedo.isEmpty ? part.albedo.flatMap { [$0, $0, $0] } : part.vertexAlbedo }
        }
        return soup
    }

    /// Procedural fallback: low buildings on built-up imagery that shows building texture (local contrast)
    /// and a nearby cast shadow, so parking lots and concrete aprons stay flat. Roofs take the photo's
    /// colour and footprints follow the local edge direction. Deterministic.
    public func proceduralBuildings(radius: Double = 2_400, cell: Double = 18, maxCount: Int = 6_000) -> [OSMBuilding] {
        let near = ground.near
        var out: [OSMBuilding] = []
        func lum(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        let c0 = nearHeights.centre
        var y = -radius
        while y < radius {
            var x = -radius
            while x < radius {
                defer { x += cell }
                let px = c0.x + x, py = c0.y + y
                if x * x + y * y > radius * radius || out.count >= maxCount { continue }
                guard let c = near.sample(px, py) else { continue }
                let lc = LandCover.classify(c)
                if lc.urban < 0.5 || lc.water > 0.2 || lc.forest > 0.3 { continue }
                if let g = ground.ground(px, py), g.water > 0.2 { continue }        // the renderer's smoothed water mask
                if apronOrRunway(px, py) { continue }
                // 5 × 5 samples at 3 m: contrast, darkest value, structure tensor.
                var sum: Float = 0, sq: Float = 0, darkest: Float = 1, n: Float = 0, roofSamples: [SIMD3<Float>] = []
                var jxx: Float = 0, jyy: Float = 0, jxy: Float = 0
                for j in -2...2 { for i in -2...2 {
                    guard let s = near.sample(px + Double(i) * 3, py + Double(j) * 3) else { continue }
                    let l = lum(s); sum += l; sq += l * l; darkest = min(darkest, l); n += 1
                    if abs(i) <= 1 && abs(j) <= 1 { roofSamples.append(s) }        // the 9 m around the roof centre
                    if let sx = near.sample(px + Double(i) * 3 + 1.5, py + Double(j) * 3),
                       let sy = near.sample(px + Double(i) * 3, py + Double(j) * 3 + 1.5) {
                        let gx = lum(sx) - l, gy = lum(sy) - l
                        jxx += gx * gx; jyy += gy * gy; jxy += gx * gy
                    }
                } }
                guard n > 20 else { continue }
                let mean = sum / n, variance = sq / n - mean * mean
                if variance < 0.004 || darkest > 0.16 { continue }
                let heading = 0.5 * Double(atan2(2 * jxy, jxx - jyy))   // dominant edge direction
                var rng = SplitMix64(seed: Hash.int(Int((px / cell).rounded()), Int((py / cell).rounded()), seed: 0xB01D))
                let hx = 4.5 + Hash.unit(rng.next()) * 3.5, hy = 4.5 + Hash.unit(rng.next()) * 3.5
                let jx = (Hash.unit(rng.next()) - 0.5) * (cell - 2 * hx) * 0.8, jy = (Hash.unit(rng.next()) - 0.5) * (cell - 2 * hy) * 0.8
                let cx = px + jx, cy = py + jy, ch = cos(heading), sh = sin(heading)
                let fp = [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)].map { SIMD2(cx + ch * $0.0 - sh * $0.1, cy + sh * $0.0 + ch * $0.1) }
                // Roof: the same photo→albedo conversion as the terrain (ImageryGround), so a roof is exactly
                // as bright as the photo around it (×0.9 made every box read 25 % paler than the ground).
                // Photo roof colour: the brighter half of the 3 × 3 samples, so the building's own cast shadow
                // and the asphalt around it do not darken the roof (a plain mean gave charcoal roofs, round 5).
                let lit = roofSamples.sorted { lum($0) > lum($1) }.prefix(max(1, (roofSamples.count + 1) / 2))
                let rc = lit.reduce(SIMD3<Float>.zero, +) / Float(lit.count)
                // Inside a large uniform surface (a warehouse roof or a car park the photo already shows): a
                // house-sized box standing on it reads as clutter (art round 17, KBFI).
                let ring = (0..<8).compactMap { k -> Float? in
                    let a = Double(k) * .pi / 4
                    return near.sample(px + 14 * cos(a), py + 14 * sin(a)).map(lum)
                }
                if Self.onLargeUniformSurface(roofLuminance: lum(rc), ring: ring) { continue }
                var roof = SIMD3(powf(powf(rc.x, 2.2), 1.12), powf(powf(rc.y, 2.2), 1.12), powf(powf(rc.z, 2.2), 1.12)) * 0.72
                if lum(roof) < 0.08 { roof *= 0.08 / max(lum(roof), 0.004) }       // asphalt-shingle floor
                // Walls: painted stucco, siding or concrete (linear albedo 0.30–0.48) with a little of the
                // roof's hue. Walls derived from the roof read as charcoal boxes (round 5).
                // Darker siding and brick too: five pale tones read as uniform pale cubes (round 18, KBFI).
                let palette: [SIMD3<Float>] = [SIMD3(0.46, 0.42, 0.35), SIMD3(0.40, 0.40, 0.38), SIMD3(0.48, 0.46, 0.43),
                                               SIMD3(0.38, 0.32, 0.25), SIMD3(0.34, 0.36, 0.37), SIMD3(0.24, 0.20, 0.17),
                                               SIMD3(0.28, 0.17, 0.12), SIMD3(0.22, 0.25, 0.27)]
                let base = palette[Int(rng.next() % UInt64(palette.count))]
                let wall = base * (1 + (roof / max(lum(roof), 0.01) - 1) * 0.15)
                out.append(OSMBuilding(id: -Int64(out.count + 1), footprint: fp, heightMetres: (4.5 + Hash.unit(rng.next()) * 3.5) * (Hash.unit(rng.next()) < 0.2 ? 1.6 : 1),   // a fifth two-storey
                                       kind: "house", roofColour: roof, wallColour: wall, tags: ["source": "procedural fallback"]))
            }
            y += cell
        }
        return Self.dropIsolated(out)
    }

    /// Whether a candidate's surroundings (photo luminance 14 m out in 8 directions) mostly match its roof:
    /// then it lies on one large roof or paved area rather than on a house among gardens and streets.
    static func onLargeUniformSurface(roofLuminance: Float, ring: [Float], tolerance: Float = 0.05, minMatches: Int = 5) -> Bool {
        ring.filter { abs($0 - roofLuminance) < tolerance }.count >= minMatches
    }

    /// Keeps buildings with at least `minNeighbours` other within `radius` m: real built-up areas are
    /// clusters, while a lone box is usually a bright car park or roof misread by the colour classifier.
    static func dropIsolated(_ list: [OSMBuilding], radius: Double = 50, minNeighbours: Int = 1) -> [OSMBuilding] {
        func centre(_ b: OSMBuilding) -> SIMD2<Double> { b.footprint.reduce(.zero, +) / Double(max(1, b.footprint.count)) }
        let cs = list.map(centre)
        var grid: [SIMD2<Int>: [Int]] = [:]
        func key(_ p: SIMD2<Double>) -> SIMD2<Int> { SIMD2(Int((p.x / radius).rounded(.down)), Int((p.y / radius).rounded(.down))) }
        for (i, c) in cs.enumerated() { grid[key(c), default: []].append(i) }
        return list.indices.filter { i in
            let k = key(cs[i]); var n = 0
            for dy in -1...1 { for dx in -1...1 {
                for j in grid[k &+ SIMD2(dx, dy)] ?? [] where j != i {
                    let d = cs[j] - cs[i]
                    if (d * d).sum() <= radius * radius { n += 1 }
                }
            } }
            return n >= minNeighbours
        }.map { list[$0] }
    }

    /// Discs the photo's own tree (crown plus its shadow) can occupy around each placed 3D tree.
    public static func photoCrowns(_ trees: [TreeInstance]) -> [ImageryDelighting.Crown] {
        trees.map { t in
            let h = Double(t.height)
            return ImageryDelighting.Crown(centre: SIMD2(Double(t.position.x), Double(t.position.y)),
                                           radius: h * (t.conifer ? 0.25 : 0.42) + h * 0.25)
        }
    }

    /// Whether the sharp camera-following layer exists here (US aerial photo coverage).
    public var detailStreamable: Bool { ground.detail != nil && detail.imageryDetailSize > 0 }

    /// Where the sharp layer should be centred for an aircraft at `position` moving along `velocity`
    /// (horizontal): 75 % of its half extent ahead, which covers what a chase or cockpit view sees closest.
    public func detailCentre(position: SIMD3<Double>, velocity: SIMD3<Double>) -> SIMD2<Double> {
        let h = SIMD2(velocity.x, velocity.y), l = (h * h).sum().squareRoot()
        let dir = l > 1 ? h / l : SIMD2(sin(runwayHeading), cos(runwayHeading))
        return SIMD2(position.x, position.y) + dir * detail.imageryDetailHalf * 0.75
    }

    /// Builds the sharp layer around `centre` (tile cache and packs first, network otherwise), colour-matched
    /// to the near mosaic. Nil where there is no aerial photo coverage.
    public func streamDetail(around centre: SIMD2<Double>, transport: any HTTPTransport, cache: KeyedCache?) async -> ImageryMosaic? {
        guard detailStreamable else { return nil }
        let provider = USGSImageryProvider(maxZoom: 18)
        var m = await ImageryMosaic.build(origin: origin, centre: centre, halfExtent: detail.imageryDetailHalf, size: detail.imageryDetailSize,
                                          provider: provider, streamer: ImageryStreamer(provider: provider, transport: transport, cache: cache))
        guard m.coverage.contains(where: { $0 > 0 }) else { return nil }
        ImageryGrading.match(&m, to: ground.near)
        return m
    }

    /// The runway with its taxiways (120 m either side of the centreline): never water.
    func pavedArea(_ x: Double, _ y: Double) -> Bool {
        let d = SIMD2(x, y) - runwayThreshold
        let along = (d * runwayDirection).sum()
        let across = abs(d.x * runwayDirection.y - d.y * runwayDirection.x)
        return along > -300 && along < runwayLengthMetres + 300 && across < 120
    }

    /// The runway, its strip and a 250 m apron band either side (no fallback buildings there).
    func apronOrRunway(_ x: Double, _ y: Double) -> Bool {
        let d = SIMD2(x, y) - runwayThreshold
        let along = (d * runwayDirection).sum()
        let across = abs(d.x * runwayDirection.y - d.y * runwayDirection.x)
        return along > -400 && along < runwayLengthMetres + 400 && across < 250
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
        var paved: [Bool] = []
        let r = detail.treeRadius, cell = 7.0
        // OSM footprints by 40 m grid cell, so trees never grow through buildings.
        var footprints: [SIMD2<Int>: [[SIMD2<Double>]]] = [:]
        for b in buildings {
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
        // Stands: low-frequency noise (~300 m) sets the conifer share, brightness and height of a patch of
        // forest, so a valley is darker conifer stands beside lighter broadleaf ones instead of one uniform
        // texture from the camera to the far slope (art round 18, LSZS).
        let standNoise = GradientNoise2D(seed: 0x57A4D)
        // Two foci: the near layer's centre, and the final-approach foreground (the showcase start is a 2 km
        // final, whose foreground lay outside the first disc and kept flat photo trees, art round 8). Grid
        // offsets stay relative to the near centre so each cell's random stream is the same either way.
        let c0 = nearHeights.centre
        let f1 = runwayThreshold - runwayDirection * 2_000 - c0, r1 = r * 0.6
        func inDisc(_ x: Double, _ y: Double) -> Bool {
            x * x + y * y <= r * r || ((x - f1.x) * (x - f1.x) + (y - f1.y) * (y - f1.y)) <= r1 * r1
        }
        let lo = SIMD2(min(-r, f1.x - r1), min(-r, f1.y - r1)), hi = SIMD2(max(r, f1.x + r1), max(r, f1.y + r1))
        var y = (lo.y / cell).rounded(.down) * cell
        while y < hi.y {
            var x = (lo.x / cell).rounded(.down) * cell
            while x < hi.x {
                defer { x += cell }
                if !inDisc(x, y) { continue }
                var rng = SplitMix64(seed: Hash.int(Int((x / cell).rounded()), Int((y / cell).rounded()), seed: 0x7EE5))
                var px = nearHeights.centre.x + x + Hash.unit(rng.next()) * cell, py = nearHeights.centre.y + y + Hash.unit(rng.next()) * cell
                // Snap to the greenest point within ±3 m (the photo crown), so the 3D crown covers its photo tree
                // instead of standing beside it (art round 8). The darkest point (round 9) drifted onto the
                // tree's own baked shadow, which is darker but grey-blue (round 10).
                func greenAt(_ x: Double, _ y: Double) -> Float? {
                    near.sample(x, y).map { c in
                        let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                        return (c.y - 0.5 * (c.x + c.z)) - max(0, l - 0.30)   // green excess; bright ground loses
                    }
                }
                if var best = greenAt(px, py) {
                    var bx = px, by = py
                    for (dx, dy) in [(-3.0, 0.0), (3, 0), (0, -3), (0, 3), (-2.1, -2.1), (2.1, -2.1), (-2.1, 2.1), (2.1, 2.1)] {
                        if let gx = greenAt(px + dx, py + dy), gx > best { best = gx; bx = px + dx; by = py + dy }
                    }
                    px = bx; py = by
                }
                guard let c = near.sample(px, py), let g = ground.ground(px, py) else { continue }
                let lc = LandCover.classify(c)
                // Canopy: the classifier's forest, or dark crowns that are not redder than green. Oak woodland
                // and shaded crowns photograph grey- or blue-green, below the forest score's green margin,
                // and stayed flat photo blobs (art round 7); a 3D crown on each hides the soft photo tree.
                let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                func ss(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t) }
                // Green at least as strong as blue: a shaded crown stays green-dominant, a shadow on asphalt or a
                // rail bed turns blue (art round 8: trees on roads and lots at KBFI).
                // (Round 9: green ≥ blue still let faintly green asphalt shadow through; now green clearly above
                // blue and at least 0.9 × red.)
                let canopy = max(lc.forest, ss(0.30, 0.15, l) * ss(-0.02, 0.01, c.y - 0.9 * c.x) * ss(0.015, 0.04, c.y - c.z) * (1 - lc.water))
                if Hash.unit(rng.next()) > Double(canopy) * 0.9 || g.water > 0.3 { continue }
                if nearRunway(px, py) || inBuilding(px, py) { continue }
                let sA = standNoise.fbm(px / 320, py / 320, octaves: 2), sB = standNoise.fbm(px / 210 + 17.3, py / 210 - 9.1, octaves: 2)
                let coniferShare = 0.12 + 0.76 * Double(ss(-0.22, 0.22, Float(sA)))
                let h = 9 + 10 * (0.5 * Hash.unit(rng.next()) + 0.5 * Double(ss(-0.4, 0.4, Float(sB))))   // half per stand
                let conifer = Hash.unit(rng.next()) < coniferShare
                var tint = g.albedo * 1.9 * Float(0.85 + 0.3 * Hash.unit(rng.next()))
                // Per-tree hue: ±4 % on the red/green balance, so neighbouring crowns differ (round 11).
                tint.x *= Float(0.96 + 0.08 * Hash.unit(rng.next()))
                // Foliage albedo floor (hue kept): dark Sentinel-2 forest gave near-black crowns (LSZS).
                let tl = 0.2126 * tint.x + 0.7152 * tint.y + 0.0722 * tint.z
                if tl < 0.08 { tint *= 0.08 / max(tl, 0.002) }   // (0.05 left dark crowns grey after the tone map)
                // Foliage hue range in linear albedo: blue ≤ 0.55 × green, red 0.62–0.85 × green, so saturation is
                // at least ~0.4 and survives the tone map. Shaded photo canopy carries the sky's blue (teal crowns,
                // round 8); red up to 1.05 × green turned alpine forest khaki (round 9); a 0.25 floor could not
                // act under the blue clamp and the screen saturation stayed at 18 against 29 (round 10).
                tint.z = min(tint.z, tint.y * 0.55)
                tint.x = min(max(tint.x, tint.y * 0.62), tint.y * 0.85)
                // Brightness ±8 % after the floor (the floor flattened the earlier jitter on dark canopy, round 12).
                tint *= Float(0.92 + 0.16 * Hash.unit(rng.next()))
                // Stand tone: conifer stands darker and bluer-green, broadleaf stands lighter.
                tint *= conifer ? SIMD3<Float>(0.86, 0.90, 0.92) : SIMD3<Float>(1.08, 1.07, 1.0)
                tint *= Float(0.93 + 0.14 * Double(ss(-0.4, 0.4, Float(sB))))
                out.append(TreeInstance(position: SIMD3(Float(px), Float(py), Float(height(px, py))), height: Float(h), conifer: conifer, colour: tint))
                // Paved surroundings: most of the ring 4 m out bright and unsaturated (lots, roads, roofs).
                var bright = 0
                for (dx, dy) in [(-4.0, 0.0), (4, 0), (0, -4), (0, 4), (-2.8, -2.8), (2.8, -2.8), (-2.8, 2.8), (2.8, 2.8)] {
                    guard let q = near.sample(px + dx, py + dy) else { continue }
                    let ql = 0.2126 * q.x + 0.7152 * q.y + 0.0722 * q.z
                    let qmax = max(q.x, q.y, q.z), qmin = min(q.x, q.y, q.z)
                    if ql > 0.35 && (qmax - qmin) / max(qmax, 1e-3) < 0.18 { bright += 1 }
                }
                paved.append(bright >= 5)
            }
            y += cell
        }
        let c = SIMD2<Float>(Float(c0.x), Float(c0.y)), c1 = c + SIMD2<Float>(Float(f1.x), Float(f1.y))
        func d2(_ t: TreeInstance) -> Float {
            let p = SIMD2(t.position.x, t.position.y), a = p - c, b = p - c1
            return min((a * a).sum(), (b * b).sum())             // thin by distance to the nearer focus
        }
        out = Self.dropLoneTrees(out, paved: paved)
        out.sort { d2($0) < d2($1) }
        return Self.thin(out, max: detail.maxTrees, d2: d2)
    }

    /// Keeps trees with at least `minNeighbours` others within `radius` m: real canopy, street rows and park
    /// clusters have neighbours, while a lone tree on a bare lot is usually a dark car or shadow read as a
    /// crown and stood there as a prop (art round 11, KBFI). One within 20 m: suburban oaks stand 10–25 m
    /// apart, and two within 10 m removed half of KMRY's real foreground trees (round 12).
    /// `paved[i]` (optional) marks trees on bright, unsaturated surroundings, which need `pavedNeighbours`
    /// within `pavedRadius` instead (round 13: the loose rule brought KBFI's lot props back).
    static func dropLoneTrees(_ list: [TreeInstance], paved: [Bool] = [], radius: Float = 20, minNeighbours: Int = 1,
                              pavedRadius: Float = 10, pavedNeighbours: Int = 2) -> [TreeInstance] {
        var grid: [SIMD2<Int32>: [Int]] = [:]
        func key(_ t: TreeInstance) -> SIMD2<Int32> { SIMD2(Int32((t.position.x / radius).rounded(.down)), Int32((t.position.y / radius).rounded(.down))) }
        for (i, t) in list.enumerated() { grid[key(t), default: []].append(i) }
        return list.indices.filter { i in
            let strict = i < paved.count && paved[i]
            let rr = strict ? pavedRadius : radius, need = strict ? pavedNeighbours : minNeighbours
            let k = key(list[i]); var n = 0
            for dy: Int32 in -1...1 { for dx: Int32 in -1...1 {
                for j in grid[k &+ SIMD2(dx, dy)] ?? [] where j != i {
                    let d = SIMD2(list[j].position.x - list[i].position.x, list[j].position.y - list[i].position.y)
                    if (d * d).sum() <= rr * rr { n += 1; if n >= need { return true } }
                }
            } }
            return false
        }.map { list[$0] }
    }

    /// Keeps at most `max` trees with full density out to a radius d0 and density ∝ (d0/d)² beyond
    /// (about as many trees per screen area at every distance), instead of cutting at the nearest
    /// `max`: in dense forest that cut stopped trees ~800 m from the centre. Each tree keeps a fixed
    /// random rank, so thinning is stable. Input and output are sorted nearest first.
    static func thin(_ trees: [TreeInstance], max: Int, d2: (TreeInstance) -> Float) -> [TreeInstance] {
        guard trees.count > max else { return trees }
        let dd = trees.map(d2)
        let rank = trees.indices.map { i -> Float in
            Float(Hash.unit(Hash.int(Int(trees[i].position.x * 4), Int(trees[i].position.y * 4), seed: 0x7417)))
        }
        func keep(_ i: Int, _ d0sq: Float) -> Bool { dd[i] <= d0sq || rank[i] < d0sq / dd[i] }
        var lo: Float = 0, hi = dd.last ?? 1
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            var n = 0
            for i in trees.indices where keep(i, mid) { n += 1 }
            if n > max { hi = mid } else { lo = mid }
        }
        return trees.indices.filter { keep($0, lo) }.map { trees[$0] }
    }

    func nearRunway(_ x: Double, _ y: Double) -> Bool {
        let d = SIMD2(x, y) - runwayThreshold
        let along = (d * runwayDirection).sum()
        let across = abs(d.x * runwayDirection.y - d.y * runwayDirection.x)
        if along > -60 && along < runwayLengthMetres + 60 && across < runwayWidthMetres / 2 + 75 { return true }
        let past = along < 0 ? -along : along - runwayLengthMetres
        // Approach-light zone only (900 m): farther out, 9–19 m trees sit well under the 34:1 obstacle
        // surface (~25 m at 900 m), and the 2 km final's foreground had no trees at all.
        return past > 0 && past < 900 && across < runwayWidthMetres / 2 + 60 + past * 0.15
    }
}

@inline(__always) func simdMin(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)) }
@inline(__always) func simdMax(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)) }
