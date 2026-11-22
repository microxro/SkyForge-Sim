// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Metal
import SFPerf

/// GPU-side helpers for the quality governor. Separate from WorldRenderer so they can ship without
/// touching the frame encoder; the host calls `attach` once per command buffer before `commit()`.
public enum GPUTelemetry {
    /// Reports GPU time (ms) from the command buffer timestamps when it completes. The handler runs on
    /// a Metal thread, so `sink` must be thread-safe. Reports nothing if the driver gave no timestamps.
    public static func attach(to cmd: MTLCommandBuffer, sink: @escaping @Sendable (Double) -> Void) {
        cmd.addCompletedHandler { cb in
            let seconds = cb.gpuEndTime - cb.gpuStartTime
            if seconds > 0 { sink(seconds * 1_000) }
        }
    }
}

/// ASTC upload for streamed, pre-encoded tiles (offline `astcenc`; Metal has no runtime encoder).
public enum ASTCTextures {
    /// ASTC needs an Apple-family GPU (A8 and later, every Apple-silicon Mac). Intel Macs fall back to RGBA8.
    public static func isSupported(_ device: MTLDevice) -> Bool { device.supportsFamily(.apple2) }

    public static func pixelFormat(_ block: ASTCBlock, srgb: Bool) -> MTLPixelFormat {
        switch (block, srgb) {
        case (.b4x4, false): .astc_4x4_ldr
        case (.b4x4, true): .astc_4x4_srgb
        case (.b5x5, false): .astc_5x5_ldr
        case (.b5x5, true): .astc_5x5_srgb
        case (.b6x6, false): .astc_6x6_ldr
        case (.b6x6, true): .astc_6x6_srgb
        case (.b8x8, false): .astc_8x8_ldr
        case (.b8x8, true): .astc_8x8_srgb
        }
    }

    /// Builds a texture from mip data ordered from the top level down; `levels[0]` is `width × height`.
    /// Tile headers are untrusted, so every size is checked first. Returns nil (never asserts) on an
    /// unsupported device, bad dimensions, too many or too short levels, or allocation failure.
    public static func makeTexture(device: MTLDevice, block: ASTCBlock, srgb: Bool, width: Int, height: Int,
                                   levels: [[UInt8]]) -> MTLTexture? {
        guard isSupported(device), !levels.isEmpty,
              width >= 1, height >= 1, width <= ASTCBlock.maxDimension, height <= ASTCBlock.maxDimension,
              levels.count <= ASTCBlock.mipCount(width: width, height: height) else { return nil }
        var w = width, h = height
        for bytes in levels {
            // Reject short data up front; oversized data is fine and only the needed prefix is read.
            guard bytes.count >= block.byteSize(width: w, height: h) else { return nil }
            w = max(1, w / 2); h = max(1, h / 2)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat(block, srgb: srgb), width: width, height: height,
                                                         mipmapped: false)
        d.mipmapLevelCount = levels.count
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        w = width; h = height
        for (i, bytes) in levels.enumerated() {
            bytes.withUnsafeBytes {
                guard let base = $0.baseAddress else { return }
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: i, withBytes: base,
                          bytesPerRow: block.bytesPerRow(width: w))
            }
            w = max(1, w / 2); h = max(1, h / 2)
        }
        return t
    }
}
#endif
