// SKYFORGE — Apache-2.0
// Compile-only probe: each unknown member reports an error, which lists which Background Assets names exist.
// Removed once the real binding uses the verified calls.
#if SCENERY_BACKGROUND_ASSETS && canImport(BackgroundAssets)
import BackgroundAssets

func _backgroundAssetsProbe(_ m: BADownloadManager, _ d: BADownload) {
    _ = m.startForegroundDownload
    _ = m.startBackgroundDownload
    _ = m.fetchCurrentDownloads
    _ = m.ensureDownloaded
    _ = m.statusForPack
    _ = m.fetchStatus
    _ = m.beginDownload
    _ = m.schedule
    _ = m.cancel
    _ = m.remove
    _ = m.delete
    _ = m.download
    _ = m.currentDownloads
    _ = d.identifier
    _ = d.state
    _ = d.fileURL
    _ = d.localURL
    _ = d.url
    _ = d.path
    _ = d.fileSize
    _ = d.expectedBytes
    _ = d.bytesReceived
    _ = d.progress
    _ = d.isBackground
    _ = d.error
}
#endif
