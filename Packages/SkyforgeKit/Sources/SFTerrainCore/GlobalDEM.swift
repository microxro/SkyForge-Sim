// SKYFORGE — Apache-2.0
// Bundled offline global elevation baseline (tools/make_global_dem.py): equirectangular Int16 metres,
// zlib-compressed 256x256 tiles decoded on demand and cached.
import Foundation
import Synchronization
import SFMath

public enum GlobalDEMError: Error, Equatable {
    case missingResource
    case badHeader
    case badTile(Int)
}

public final class GlobalDEM: Sendable {
    public let width: Int, height: Int, tileSize: Int, tilesX: Int, tilesY: Int
    let data: Data
    let table: [(offset: Int, length: Int)]
    private let cache = Mutex<[Int: [Int16]]>([:])

    public init(data: Data) throws {
        guard data.count > 28, data.prefix(6) == Data("SFDEM1".utf8) else { throw GlobalDEMError.badHeader }
        func u32(_ o: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self))) } }
        func u64(_ o: Int) -> Int { data.withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self))) } }
        width = u32(8); height = u32(12); tileSize = u32(16); tilesX = u32(20); tilesY = u32(24)
        guard width > 0, height > 0, tileSize > 0, tilesX * tileSize == width, tilesY * tileSize == height,
              data.count >= 28 + tilesX * tilesY * 12 else { throw GlobalDEMError.badHeader }
        var t: [(Int, Int)] = []
        for i in 0..<(tilesX * tilesY) {
            let o = u64(28 + i * 12), l = u32(36 + i * 12)
            guard o + l <= data.count else { throw GlobalDEMError.badHeader }
            t.append((o, l))
        }
        table = t
        self.data = data
    }

    /// Loads the copy bundled with SFTerrainCore.
    public static func bundled() throws -> GlobalDEM {
        guard let url = Bundle.module.url(forResource: "global_dem", withExtension: "sfdem", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "global_dem", withExtension: "sfdem") else { throw GlobalDEMError.missingResource }
        return try GlobalDEM(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    func tile(_ index: Int) throws -> [Int16] {
        if let t = cache.withLock({ $0[index] }) { return t }
        let e = table[index]
        let raw: [UInt8]
        do { raw = try Inflate.zlib([UInt8](data[e.offset..<(e.offset + e.length)]), expectedSize: tileSize * tileSize * 2) }
        catch { throw GlobalDEMError.badTile(index) }
        guard raw.count == tileSize * tileSize * 2 else { throw GlobalDEMError.badTile(index) }
        var out = [Int16](repeating: 0, count: tileSize * tileSize)
        for i in 0..<out.count { out[i] = Int16(bitPattern: UInt16(raw[2 * i]) | UInt16(raw[2 * i + 1]) << 8) }
        cache.withLock { c in
            if c.count > 64 { c.removeAll() }   // simple bound; the baseline is small
            c[index] = out
        }
        return out
    }

    /// Raw sample at a pixel (row 0 = 90°N), longitude wraps, latitude clamps.
    public func sample(column: Int, row: Int) -> Double {
        let c = ((column % width) + width) % width, r = min(max(row, 0), height - 1)
        let ti = (r / tileSize) * tilesX + c / tileSize
        guard let t = try? tile(ti) else { return 0 }
        return Double(t[(r % tileSize) * tileSize + c % tileSize])
    }

    /// Bilinear elevation (m) at a latitude/longitude in degrees.
    public func elevation(latitude: Double, longitude: Double) -> Double {
        let fx = (longitude + 180) / 360 * Double(width) - 0.5
        let fy = (90 - latitude) / 180 * Double(height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        return lerp(lerp(sample(column: x0, row: y0), sample(column: x0 + 1, row: y0), tx),
                    lerp(sample(column: x0, row: y0 + 1), sample(column: x0 + 1, row: y0 + 1), tx), ty)
    }
}
