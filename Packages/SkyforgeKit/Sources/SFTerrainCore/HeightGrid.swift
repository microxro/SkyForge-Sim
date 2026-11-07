// SKYFORGE — Apache-2.0
import Foundation
import SFMath

/// Slippy-map (Web Mercator) tile coordinate.
public struct TileCoord: Hashable, Sendable, CustomStringConvertible {
    public let z: Int, x: Int, y: Int
    public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }
    public var description: String { "\(z)/\(x)/\(y)" }

    public static let maxLatitude = 85.051_128_779_806_59

    /// Tile containing a latitude/longitude (degrees).
    public static func containing(latitude: Double, longitude: Double, zoom: Int) -> TileCoord {
        let n = Double(1 << zoom)
        let lat = clamp(latitude, -maxLatitude, maxLatitude) * Units.degToRad
        let x = Int(((longitude + 180) / 360 * n).rounded(.down))
        let y = Int(((1 - asinh(tan(lat)) / Double.pi) / 2 * n).rounded(.down))
        let m = (1 << zoom) - 1
        return TileCoord(z: zoom, x: min(max(x, 0), m), y: min(max(y, 0), m))
    }

    /// Latitude/longitude (degrees) of a fractional position inside the tile (u, v in [0, 1], v down).
    public func coordinate(u: Double, v: Double) -> (latitude: Double, longitude: Double) {
        let n = Double(1 << z)
        let lon = (Double(x) + u) / n * 360 - 180
        let lat = atan(sinh(Double.pi * (1 - 2 * (Double(y) + v) / n))) * Units.radToDeg
        return (lat, lon)
    }

    /// Fractional position of a lat/lon inside this tile (may be outside [0,1]).
    public func fraction(latitude: Double, longitude: Double) -> (u: Double, v: Double) {
        let n = Double(1 << z)
        let lat = clamp(latitude, -TileCoord.maxLatitude, TileCoord.maxLatitude) * Units.degToRad
        let fx = (longitude + 180) / 360 * n
        let fy = (1 - asinh(tan(lat)) / Double.pi) / 2 * n
        return (fx - Double(x), fy - Double(y))
    }
}

/// A rectangular grid of elevations (metres), row-major, row 0 at the top (north).
public struct HeightGrid: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var samples: [Float]

    public init(width: Int, height: Int, samples: [Float]) {
        precondition(samples.count == width * height, "sample count mismatch")
        self.width = width; self.height = height; self.samples = samples
    }

    public subscript(x: Int, y: Int) -> Float {
        samples[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// Bilinear sample at fractional pixel coordinates (pixel centres at integer + 0.5).
    public func sample(px: Double, py: Double) -> Double {
        let fx = px - 0.5, fy = py - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let h00 = Double(self[x0, y0]), h10 = Double(self[x0 + 1, y0])
        let h01 = Double(self[x0, y0 + 1]), h11 = Double(self[x0 + 1, y0 + 1])
        return lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), ty)
    }

    /// Sample at normalised coordinates (u, v in [0,1], v down).
    public func sample(u: Double, v: Double) -> Double { sample(px: u * Double(width), py: v * Double(height)) }

    public var minMax: (min: Float, max: Float) {
        var lo = Float.infinity, hi = -Float.infinity
        for s in samples { lo = min(lo, s); hi = max(hi, s) }
        return (lo, hi)
    }
}

public enum TerrariumDecodeError: Error, Equatable {
    case notRGB
}

/// AWS Terrain Tiles "Terrarium" encoding: height = (R * 256 + G + B / 256) - 32768 metres.
public enum Terrarium {
    public static func decode(png: [UInt8]) throws -> HeightGrid {
        let img = try PNGDecoder.decode(png)
        guard img.channels >= 3 else { throw TerrariumDecodeError.notRGB }
        var out = [Float](repeating: 0, count: img.width * img.height)
        for i in 0..<(img.width * img.height) {
            let p = i * img.channels
            let r = Double(img.pixels[p]), g = Double(img.pixels[p + 1]), b = Double(img.pixels[p + 2])
            out[i] = Float(r * 256 + g + b / 256 - 32_768)
        }
        return HeightGrid(width: img.width, height: img.height, samples: out)
    }

    /// Tile URL (AWS Open Data, keyless). Listed in docs/DATA_SOURCES.md.
    public static func url(for t: TileCoord) -> String {
        "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(t.z)/\(t.x)/\(t.y).png"
    }
}
