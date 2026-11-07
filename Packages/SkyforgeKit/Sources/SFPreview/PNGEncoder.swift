// SKYFORGE — Apache-2.0
// Minimal PNG writer: RGB8, zlib "stored" deflate blocks, CRC-32 and Adler-32. No external libraries.
import Foundation

public enum PNGEncoder {
    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32<S: Sequence>(_ bytes: S, initial: UInt32 = 0xFFFF_FFFF) -> UInt32 where S.Element == UInt8 {
        var c = initial
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {
            let end = min(i + 5552, data.count)
            while i < end { a += UInt32(data[i]); b += a; i += 1 }
            a %= 65521; b %= 65521
        }
        return (b << 16) | a
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        var out = be32(UInt32(body.count))
        out += t
        out += body
        out += be32(crc32(t + body) ^ 0xFFFF_FFFF)
        return out
    }

    /// Encodes tightly packed RGB8 pixels (row-major, top-down).
    public static func encodeRGB(width: Int, height: Int, rgb: [UInt8]) -> Data {
        precondition(rgb.count == width * height * 3, "pixel buffer size mismatch")
        var raw = [UInt8]()
        raw.reserveCapacity((width * 3 + 1) * height)
        for y in 0..<height {
            raw.append(0) // filter: none
            raw.append(contentsOf: rgb[(y * width * 3)..<((y + 1) * width * 3)])
        }
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65_535, raw.count - i)
            let final: UInt8 = (i + n >= raw.count) ? 1 : 0
            z.append(final)
            z.append(UInt8(n & 0xFF)); z.append(UInt8(n >> 8))
            z.append(UInt8(~n & 0xFF)); z.append(UInt8((~n >> 8) & 0xFF))
            z.append(contentsOf: raw[i..<(i + n)])
            i += n
        } while i < raw.count
        z += be32(adler32(raw))
        var ihdr = be32(UInt32(width)) + be32(UInt32(height))
        ihdr += [8, 2, 0, 0, 0] // 8-bit, truecolour, deflate, adaptive filter, no interlace
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", ihdr)
        png += chunk("IDAT", z)
        png += chunk("IEND", [])
        return Data(png)
    }
}
