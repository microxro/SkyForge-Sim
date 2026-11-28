// SKYFORGE — Apache-2.0
// Apple Background Assets binding for whole-Earth scenery (iOS 26 API: AssetPackManager).
// Each catalog segment is one Apple-hosted asset pack, named by its segment ID. The pack holds one file,
// `segment.bin`, whose SHA-256 is the segment's `sha256` in the catalog. Compiled only with
// SCENERY_BACKGROUND_ASSETS, so the default build never compiles it until it is verified on Apple CI.
#if SCENERY_BACKGROUND_ASSETS && canImport(BackgroundAssets)
import BackgroundAssets
import Crypto
import Foundation
import System

/// Storage backend that asks the system for Apple-hosted asset packs.
public final class BackgroundAssetsSceneryBackend: SceneryPackBackend, Sendable {
    /// File inside each pack that holds the segment's archive.
    public static let archiveName = "segment.bin"

    public init() {}

    public func installedSegmentIDs() async -> Set<String> {
        let manager = AssetPackManager.shared
        guard let packs = try? await manager.allAssetPacks else { return [] }
        var ids = Set<String>()
        for pack in packs {
            if let status = try? await manager.status(ofAssetPackWithID: pack.id), status.contains(.upToDate) {
                ids.insert(pack.id)
            }
        }
        return ids
    }

    public func download(_ segment: ScenerySegment, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let manager = AssetPackManager.shared
        let pack = try await manager.assetPack(withID: segment.id)
        // Byte progress arrives on the pack's status stream while the system downloads it.
        let listener = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: segment.id) {
                if case .downloading(_, let fraction) = update {
                    progress(fraction.completedUnitCount)
                }
            }
        }
        defer { listener.cancel() }
        try await manager.ensureLocalAvailability(of: pack)
    }

    public func archiveHash(of segment: ScenerySegment) async throws -> String? {
        let manager = AssetPackManager.shared
        let descriptor: System.FileDescriptor
        do {
            descriptor = try manager.descriptor(for: System.FilePath(BackgroundAssetsSceneryBackend.archiveName),
                                                searchingInAssetPackWithID: segment.id)
        } catch {
            return nil
        }
        defer { try? descriptor.close() }
        // Hash in 1 MB chunks: segments are gigabytes, so the file is never read whole.
        var hasher = SHA256()
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = try chunk.withUnsafeMutableBytes { try descriptor.read(into: $0) }
            if count == 0 { break }
            hasher.update(data: Data(chunk[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func remove(segmentID: String) async throws {
        try await AssetPackManager.shared.remove(assetPackWithID: segmentID)
    }
}
#endif
