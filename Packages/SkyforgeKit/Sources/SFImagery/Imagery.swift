// SKYFORGE — Apache-2.0
// Free orthoimagery for the real-world ground: providers (public domain USGS NAIP-based
// orthoimagery for the US, CC BY 4.0 Sentinel-2 cloudless 2016 worldwide), a cached streaming
// actor, local tangent-plane mapping and mosaics resampled to metres. No keys, no accounts.
import Foundation
import SFMath
import SFContent
import SFTerrainCore

public protocol ImageryProvider: Sendable {
    var id: String { get }
    var attribution: String { get }
    var maxZoom: Int { get }
    func covers(latitude: Double, longitude: Double) -> Bool
    func url(_ t: TileCoord) -> URL
}

/// USGS The National Map orthoimagery (USDA NAIP and others). US Government work: public domain.
public struct USGSImageryProvider: ImageryProvider {
    public let id = "usgs-imagery"
    public let attribution = "Imagery: USGS The National Map / USDA NAIP (public domain)"
    public let maxZoom: Int
    public init(maxZoom: Int = 16) { self.maxZoom = maxZoom }
    public func covers(latitude: Double, longitude: Double) -> Bool {
        let conus = latitude > 24 && latitude < 49.5 && longitude > -125 && longitude < -66.5
        let alaska = latitude > 51 && latitude < 71.5 && longitude > -170 && longitude < -129
        let hawaii = latitude > 18.8 && latitude < 22.4 && longitude > -160.5 && longitude < -154.6
        return conus || alaska || hawaii
    }
    public func url(_ t: TileCoord) -> URL {
        URL(string: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/\(t.z)/\(t.y)/\(t.x)")!
    }
}

/// EOX Sentinel-2 cloudless 2016 (the CC BY 4.0 edition; later editions are non-commercial).
public struct Sentinel2CloudlessProvider: ImageryProvider {
    public let id = "s2cloudless-2016"
    public let attribution = "Sentinel-2 cloudless 2016 by EOX IT Services GmbH (contains modified Copernicus Sentinel data 2016), CC BY 4.0"
    public let maxZoom = 14
    public init() {}
    public func covers(latitude: Double, longitude: Double) -> Bool { abs(latitude) < 85 }
    public func url(_ t: TileCoord) -> URL {
        URL(string: "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/\(t.z)/\(t.y)/\(t.x).jpg")!
    }
}

/// Local east/north metres around an origin ↔ latitude/longitude, using the WGS84 meridional
/// and prime-vertical radii at the sample latitude (≲ 0.1 % error over ±40 km).
public struct GeoOrigin: Sendable, Equatable {
    public let latitude: Double, longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    static let a = 6_378_137.0, e2 = 0.006_694_379_990_14

    static func radii(_ latDeg: Double) -> (m: Double, n: Double) {
        let s = sin(latDeg * .pi / 180)
        let w = (1 - e2 * s * s).squareRoot()
        return (a * (1 - e2) / (w * w * w), a / w)
    }
    public func coordinate(east x: Double, north y: Double) -> (latitude: Double, longitude: Double) {
        let lat = latitude + y / Self.radii(latitude).m * 180 / .pi
        let mid = (lat + latitude) / 2
        let lon = longitude + x / (Self.radii(mid).n * cos(mid * .pi / 180)) * 180 / .pi
        return (lat, lon)
    }
    public func local(latitude lat: Double, longitude lon: Double) -> (east: Double, north: Double) {
        let mid = (lat + latitude) / 2
        return ((lon - longitude) * .pi / 180 * Self.radii(mid).n * cos(mid * .pi / 180),
                (lat - latitude) * .pi / 180 * Self.radii(latitude).m)
    }
}

public actor ImageryStreamer {
    public enum Source: String, Sendable { case memory, disk, network, missing }
    private let provider: any ImageryProvider
    private let transport: any HTTPTransport
    private let cache: KeyedCache?
    private var memory: [TileCoord: RGBImage] = [:]
    private var order: [TileCoord] = []
    private var inFlight: [TileCoord: Task<(Data, RGBImage)?, Never>] = [:]
    private let memoryLimit: Int
    public private(set) var networkRequests = 0

    public init(provider: any ImageryProvider, transport: any HTTPTransport, cache: KeyedCache?, memoryLimit: Int = 512) {
        self.provider = provider; self.transport = transport; self.cache = cache; self.memoryLimit = memoryLimit
    }

    func key(_ t: TileCoord) -> String { "imagery/\(provider.id)/\(t.z)/\(t.x)/\(t.y)" }

    public func tile(_ t: TileCoord) async -> (RGBImage?, Source) {
        if let m = memory[t] { return (m, .memory) }
        if let c = cache, let d = await c.get(key(t)), let img = try? JPEGDecoder.decode([UInt8](d)) {
            remember(t, img); return (img, .disk)
        }
        if let task = inFlight[t] { let r = await task.value; return (r?.1, r == nil ? .missing : .network) }
        let url = provider.url(t), transport = self.transport
        networkRequests += 1
        let task = Task<(Data, RGBImage)?, Never> {
            guard let data = try? await transport.get(url), let img = try? JPEGDecoder.decode([UInt8](data)) else { return nil }
            return (data, img)
        }
        inFlight[t] = task
        let result = await task.value
        inFlight[t] = nil
        guard let (data, img) = result else { return (nil, .missing) }
        remember(t, img)
        if let c = cache { try? await c.put(key(t), data) }
        return (img, .network)
    }

    private func remember(_ t: TileCoord, _ img: RGBImage) {
        memory[t] = img
        order.append(t)
        if order.count > memoryLimit { memory[order.removeFirst()] = nil }
    }
}

/// Imagery resampled onto a square of the local metre grid (x east, y north), row 0 = north edge.
public struct ImageryMosaic: Sendable {
    public let centre: SIMD2<Double>
    public let halfExtent: Double
    public let size: Int
    public var rgb: [UInt8]
    public var coverage: [UInt8]       // 255 = imagery, 0 = missing
    public let zoom: Int
    public var metresPerPixel: Double { 2 * halfExtent / Double(size) }

    /// Web Mercator ground resolution (m per pixel of a 256-px tile) at a latitude.
    public static func tileResolution(zoom: Int, latitude: Double) -> Double {
        156_543.033_92 * cos(latitude * .pi / 180) / Double(1 << zoom)
    }

    public static func zoom(for metresPerPixel: Double, latitude: Double, maxZoom: Int) -> Int {
        var z = 1
        while z < maxZoom && tileResolution(zoom: z, latitude: latitude) > metresPerPixel { z += 1 }
        return z
    }

    public static func build(origin: GeoOrigin, centre: SIMD2<Double>, halfExtent: Double, size: Int,
                             provider: any ImageryProvider, streamer: ImageryStreamer) async -> ImageryMosaic {
        let mpp = 2 * halfExtent / Double(size)
        let z = zoom(for: mpp, latitude: origin.latitude, maxZoom: provider.maxZoom)
        let nw = origin.coordinate(east: centre.x - halfExtent, north: centre.y + halfExtent)
        let se = origin.coordinate(east: centre.x + halfExtent, north: centre.y - halfExtent)
        let t0 = TileCoord.containing(latitude: nw.latitude, longitude: nw.longitude, zoom: z)
        let t1 = TileCoord.containing(latitude: se.latitude, longitude: se.longitude, zoom: z)
        var tiles: [TileCoord: RGBImage] = [:]
        await withTaskGroup(of: (TileCoord, RGBImage?).self) { g in
            for ty in t0.y...t1.y { for tx in t0.x...t1.x {
                let t = TileCoord(z: z, x: tx, y: ty)
                g.addTask { (t, await streamer.tile(t).0) }
            } }
            for await (t, img) in g { if let img { tiles[t] = img } }
        }
        // Offline or a hole in the provider: fall back to ancestors (up to 3 levels coarser), so a
        // bundled pack built at a lower zoom, or a partial cache, still covers the area.
        var missing = Set<TileCoord>()
        for ty in t0.y...t1.y { for tx in t0.x...t1.x where tiles[TileCoord(z: z, x: tx, y: ty)] == nil {
            for k in 1...3 where z - k >= 0 { missing.insert(TileCoord(z: z - k, x: tx >> k, y: ty >> k)) }
        } }
        if !missing.isEmpty {
            await withTaskGroup(of: (TileCoord, RGBImage?).self) { g in
                for t in missing { g.addTask { (t, await streamer.tile(t).0) } }
                for await (t, img) in g { if let img { tiles[t] = img } }
            }
        }
        var rgb = [UInt8](repeating: 0, count: size * size * 3)
        var cov = [UInt8](repeating: 0, count: size * size)
        let n = Double(1 << z)
        for j in 0..<size {
            let y = centre.y + halfExtent - (Double(j) + 0.5) * mpp
            for i in 0..<size {
                let x = centre.x - halfExtent + (Double(i) + 0.5) * mpp
                let ll = origin.coordinate(east: x, north: y)
                let fx = (ll.longitude + 180) / 360 * n
                let fy = (1 - asinh(tan(ll.latitude * .pi / 180)) / .pi) / 2 * n
                var lx = fx, ly = fy, found: (RGBImage, Int, Int)?
                for k in 0...3 where z - k >= 0 {
                    let tx = Int(lx.rounded(.down)), ty = Int(ly.rounded(.down))
                    if let img = tiles[TileCoord(z: z - k, x: tx, y: ty)] { found = (img, tx, ty); break }
                    lx /= 2; ly /= 2
                }
                guard let (img, tx, ty) = found else { continue }
                let px = (lx - Double(tx)) * Double(img.width) - 0.5, py = (ly - Double(ty)) * Double(img.height) - 0.5
                let x0 = max(0, min(img.width - 1, Int(px.rounded(.down)))), y0 = max(0, min(img.height - 1, Int(py.rounded(.down))))
                let x1 = min(img.width - 1, x0 + 1), y1 = min(img.height - 1, y0 + 1)
                let ax = max(0, min(1, px - Double(x0))), ay = max(0, min(1, py - Double(y0)))
                let o = 3 * (j * size + i)
                for c in 0..<3 {
                    let a = Double(img.rgb[3 * (y0 * img.width + x0) + c]), b = Double(img.rgb[3 * (y0 * img.width + x1) + c])
                    let d = Double(img.rgb[3 * (y1 * img.width + x0) + c]), e = Double(img.rgb[3 * (y1 * img.width + x1) + c])
                    rgb[o + c] = UInt8(((a + (b - a) * ax) * (1 - ay) + (d + (e - d) * ax) * ay).rounded())
                }
                cov[j * size + i] = 255
            }
        }
        return ImageryMosaic(centre: centre, halfExtent: halfExtent, size: size, rgb: rgb, coverage: cov, zoom: z)
    }

    /// sRGB-encoded colour at a local point (bilinear), nil outside or where imagery is missing.
    public func sample(_ x: Double, _ y: Double) -> SIMD3<Float>? {
        let fx = (x - (centre.x - halfExtent)) / metresPerPixel - 0.5
        let fy = ((centre.y + halfExtent) - y) / metresPerPixel - 0.5
        guard fx >= 0, fy >= 0, fx < Double(size - 1), fy < Double(size - 1) else { return nil }
        let i = Int(fx), j = Int(fy)
        guard coverage[j * size + i] != 0 else { return nil }
        let ax = Float(fx - Double(i)), ay = Float(fy - Double(j))
        func c(_ ii: Int, _ jj: Int) -> SIMD3<Float> {
            let o = 3 * (jj * size + ii)
            return SIMD3(Float(rgb[o]), Float(rgb[o + 1]), Float(rgb[o + 2])) / 255
        }
        let top = c(i, j) + (c(i + 1, j) - c(i, j)) * ax
        let bot = c(i, j + 1) + (c(i + 1, j + 1) - c(i, j + 1)) * ax
        return top + (bot - top) * ay
    }
}

/// Coarse land cover from true-colour imagery (no NIR band): water, forest and built-up scores.
public enum LandCover {
    public struct Scores: Sendable, Equatable { public var water: Float, forest: Float, urban: Float }

    public static func classify(_ c: SIMD3<Float>) -> Scores {
        let r = c.x, g = c.y, b = c.z
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let mx = max(r, g, b), mn = min(r, g, b)
        let sat = mx > 0 ? (mx - mn) / mx : 0
        func ss(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t) }
        // Water: blue at least as strong as green and red, or very dark and not green.
        let blueish = ss(-0.02, 0.06, b - max(r, g) * 0.92)
        let dark = ss(0.20, 0.10, lum) * ss(0.02, -0.02, g - b * 1.05)
        let water = max(blueish * ss(0.55, 0.35, lum), dark)
        // Forest: dark, green-dominant canopy.
        let greenDom = ss(0.0, 0.05, g - max(r, b))
        let forest = greenDom * ss(0.42, 0.22, lum) * (1 - water)
        // Built-up: bright, unsaturated.
        let urban = ss(0.40, 0.60, lum) * ss(0.25, 0.10, sat) * (1 - water)
        return Scores(water: water, forest: forest, urban: urban)
    }
}
