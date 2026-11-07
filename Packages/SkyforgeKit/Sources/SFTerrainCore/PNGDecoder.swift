// SKYFORGE — Apache-2.0
// PNG decoder for 8-bit greyscale/RGB/RGBA, non-interlaced (enough for Terrarium tiles and fixtures).

public struct DecodedImage: Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public let pixels: [UInt8]
}

public enum PNGDecodeError: Error, Equatable {
    case notPNG
    case unsupported(String)
    case corrupt(String)
}

public enum PNGDecoder {
    public static func decode(_ bytes: [UInt8]) throws -> DecodedImage {
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count > 8, Array(bytes[0..<8]) == sig else { throw PNGDecodeError.notPNG }
        var i = 8
        var width = 0, height = 0, channels = 0
        var idat = [UInt8]()
        func be32(_ p: Int) -> Int { Int(bytes[p]) << 24 | Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3]) }
        while i + 8 <= bytes.count {
            let len = be32(i)
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            guard len >= 0, i + 12 + len <= bytes.count else { throw PNGDecodeError.corrupt("chunk length") }
            let body = i + 8
            switch type {
            case "IHDR":
                width = be32(body); height = be32(body + 4)
                let depth = bytes[body + 8], colour = bytes[body + 9], interlace = bytes[body + 12]
                guard depth == 8 else { throw PNGDecodeError.unsupported("bit depth \(depth)") }
                guard interlace == 0 else { throw PNGDecodeError.unsupported("interlaced") }
                switch colour {
                case 0: channels = 1
                case 2: channels = 3
                case 4: channels = 2
                case 6: channels = 4
                default: throw PNGDecodeError.unsupported("colour type \(colour)")
                }
                guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { throw PNGDecodeError.corrupt("size") }
            case "IDAT":
                idat.append(contentsOf: bytes[body..<(body + len)])
            case "IEND":
                i = bytes.count
                continue
            default:
                break
            }
            i += 12 + len
        }
        guard channels > 0 else { throw PNGDecodeError.corrupt("missing IHDR") }
        let stride = width * channels
        let raw: [UInt8]
        do { raw = try Inflate.zlib(idat, expectedSize: (stride + 1) * height) } catch {
            throw PNGDecodeError.corrupt("inflate: \(error)")
        }
        guard raw.count >= (stride + 1) * height else { throw PNGDecodeError.corrupt("short image data") }
        var out = [UInt8](repeating: 0, count: stride * height)
        let bpp = channels
        for y in 0..<height {
            let filter = raw[y * (stride + 1)]
            let src = y * (stride + 1) + 1
            let dst = y * stride
            for x in 0..<stride {
                let rawByte = Int(raw[src + x])
                let a = x >= bpp ? Int(out[dst + x - bpp]) : 0
                let b = y > 0 ? Int(out[dst - stride + x]) : 0
                let c = (x >= bpp && y > 0) ? Int(out[dst - stride + x - bpp]) : 0
                let v: Int
                switch filter {
                case 0: v = rawByte
                case 1: v = rawByte + a
                case 2: v = rawByte + b
                case 3: v = rawByte + (a + b) / 2
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    v = rawByte + ((pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c))
                default: throw PNGDecodeError.corrupt("filter \(filter)")
                }
                out[dst + x] = UInt8(truncatingIfNeeded: v)
            }
        }
        return DecodedImage(width: width, height: height, channels: channels, pixels: out)
    }
}
