// SKYFORGE — Apache-2.0
// Apple Background Assets binding for whole-Earth scenery. Each catalog segment is one Apple-hosted
// asset pack, named by its segment ID. Compiled only with SCENERY_BACKGROUND_ASSETS, so the default
// build (and main) never compiles it until the spike is verified on Apple CI.
#if SCENERY_BACKGROUND_ASSETS && canImport(BackgroundAssets)
import BackgroundAssets
import Foundation

/// Storage backend that asks the system for Apple-hosted asset packs.
public final class BackgroundAssetsSceneryBackend: SceneryPackBackend, Sendable {
    public init() {}

    public func installedSegmentIDs() async -> Set<String> {
        // BADownloadManager is main-actor isolated and its property can throw.
        let downloads: [BADownload] = (try? await MainActor.run { try BADownloadManager.shared.currentDownloads }) ?? []
        var ids = Set<String>()
        for download in downloads where download.state == .finished {
            ids.insert(download.identifier)
        }
        return ids
    }

    /// Not implemented yet: the spike has not found the request API for Apple-hosted packs.
    public func download(_ segment: ScenerySegment, progress: @escaping @Sendable (Int64) -> Void) async throws {
        throw TransportError.offline
    }

    /// Not implemented yet: the archive hash needs the pack's file location from the system.
    public func archiveHash(of segment: ScenerySegment) async throws -> String? {
        nil
    }

    public func remove(segmentID: String) async throws {}
}
#endif
