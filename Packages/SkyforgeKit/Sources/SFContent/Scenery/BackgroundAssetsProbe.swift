// SKYFORGE — Apache-2.0
// Compile-only probe round 3: where downloaded files live, and how a download is scheduled.
#if SCENERY_BACKGROUND_ASSETS && canImport(BackgroundAssets)
import BackgroundAssets

func _backgroundAssetsProbe(_ m: BADownloadManager, _ d: BADownload) {
    _ = m.scheduleDownload
    _ = m.startForegroundDownload
    _ = m.cancel
    _ = d.contentURL
    _ = d.fileLocation
    _ = d.location
    _ = d.destinationURL
    _ = d.downloadURL
    _ = d.packURL
    _ = d.request
    _ = d.priority
    _ = d.isEssential
    _ = d.info
    _ = d.downloadPolicy
    _ = BADownload.State.finished
    _ = BADownload.State.waiting
    _ = BADownload.State.failed
    _ = BAContentRequest.self
    _ = BAURLDownload.self
}
#endif
