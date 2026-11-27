// SKYFORGE — Apache-2.0
// Compile-only probe round 2: type names and members. Unknown names report errors.
#if SCENERY_BACKGROUND_ASSETS && canImport(BackgroundAssets)
import BackgroundAssets

func _backgroundAssetsProbe(_ m: BADownloadManager, _ d: BADownload) {
    _ = BAAssetPack.self
    _ = BAAssetPackManager.self
    _ = BAContentRequest.self
    _ = BAURLDownload.self
    _ = BAManagedDownload.self
    _ = BADownloadState.self
    _ = BAAssetPackStatus.self
    _ = m.startForegroundDownload
    _ = m.cancel
    _ = m.fetchCurrentDownloads
    _ = m.currentDownloads
    _ = m.assetPacks
    _ = m.downloads
    _ = m.status(forPack:)
    _ = m.statusForPack
    _ = d.identifier
    _ = d.state
    _ = d.url
    _ = d.error
    _ = BADownloadState.finished
    _ = BADownloadState.downloading
    _ = BADownloadState.failed
    _ = BADownloadState.waiting
    _ = BADownloadState.paused
}
#endif
