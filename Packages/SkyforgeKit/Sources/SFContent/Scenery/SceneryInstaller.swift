// SKYFORGE — Apache-2.0
// Drives the whole-Earth scenery install: checks, consent, download per segment, hash check, install.
// The actual transfer is behind `SceneryPackBackend` (Background Assets on Apple platforms; a fake in tests).
import Foundation

/// What the device reports when the player asks to download: free space, capacity and the network link.
public struct SceneryDeviceProbe: Sendable {
    public var availableCapacity: Int64
    public var totalCapacity: Int64
    public var network: ScenerySyncNetworkPolicy

    public init(availableCapacity: Int64, totalCapacity: Int64, network: ScenerySyncNetworkPolicy) {
        self.availableCapacity = availableCapacity
        self.totalCapacity = totalCapacity
        self.network = network
    }
}

/// The storage side of the install. Implementations must make `download` resumable: a call for a
/// segment that was interrupted continues where it left off, and `progress` reports bytes of that segment.
public protocol SceneryPackBackend: Sendable {
    /// Segment IDs whose archives are complete on disk.
    func installedSegmentIDs() async -> Set<String>
    /// Downloads one segment. Throws on network or disk errors, and `CancellationError` when cancelled.
    func download(_ segment: ScenerySegment, progress: @escaping @Sendable (Int64) -> Void) async throws
    /// SHA-256 (lowercase hex) of the stored archive, or nil when it is absent.
    func archiveHash(of segment: ScenerySegment) async throws -> String?
    /// Deletes a segment's archive. Missing archives are not an error.
    func remove(segmentID: String) async throws
}

/// Owns one install at a time. The UI reads `phase` and sends intent: prepare, consent, pause, resume, remove.
public actor SceneryInstaller {
    public private(set) var machine = ScenerySyncMachine()
    public private(set) var catalog: SceneryCatalog?
    /// True once the player has agreed to the download size. Only then may a failed transfer resume without a new check.
    public private(set) var consented = false
    private var advisor = ScenerySpaceAdvisor()

    private let backend: any SceneryPackBackend
    private var missing: [ScenerySegment] = []
    private var task: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<ScenerySyncPhase>.Continuation] = [:]

    public init(backend: any SceneryPackBackend) { self.backend = backend }

    /// Phase changes as a stream. The first value is the current phase. Ends when the observer stops listening.
    public func updates() -> AsyncStream<ScenerySyncPhase> {
        let (stream, continuation) = AsyncStream<ScenerySyncPhase>.makeStream()
        let id = UUID()
        observers[id] = continuation
        continuation.yield(machine.phase)
        continuation.onTermination = { @Sendable _ in
            Task { await self.dropObserver(id) }
        }
        return stream
    }

    private func dropObserver(_ id: UUID) { observers[id] = nil }

    /// Applies an event to the machine and tells observers about any change.
    @discardableResult
    private func emit(_ event: ScenerySyncEvent) -> Bool {
        let changed = machine.apply(event)
        if changed {
            for continuation in observers.values { continuation.yield(machine.phase) }
        }
        return changed
    }

    public var phase: ScenerySyncPhase { machine.phase }

    /// Checks the request and moves to consent, or to a failure the player can act on.
    public func prepare(catalog: SceneryCatalog, advisor: ScenerySpaceAdvisor,
                        storage: (available: Int64, total: Int64), network: ScenerySyncNetworkPolicy) async {
        if case .installed = machine.phase { return }
        if case .downloading = machine.phase { return }
        if case .verifying = machine.phase { return }

        let valid: SceneryCatalog
        do { valid = try catalog.validated() } catch {
            emit(.failed(.backend("Scenery catalog is invalid: \(error)"), retryable: false))
            return
        }
        self.catalog = valid
        self.advisor = advisor
        consented = false
        let installed = await backend.installedSegmentIDs()
        missing = ScenerySelection.missing(in: valid, installed: installed)
        let requiredBytes = missing.reduce(0) { $0 + $1.bytes }
        let installedBytes = valid.segments.filter { installed.contains($0.id) }.reduce(0) { $0 + $1.bytes }

        emit(.requestInstall(requiredBytes: requiredBytes))

        switch advisor.assess(requiredBytes: requiredBytes, installedBytes: installedBytes,
                              availableCapacity: storage.available, totalCapacity: storage.total) {
        case .ok: break
        case .overQuota(let over): emit(.failed(.quotaExceeded(overBy: over), retryable: false))
        case .insufficientDevice(let short): emit(.failed(.insufficientStorage(shortBy: short), retryable: false))
        }
        if case .failed = machine.phase { return }

        if let blocked = network.blockingFailure {
            emit(.failed(blocked, retryable: true))
        }
    }

    /// The player agreed to the download size. Starts the transfer.
    public func consent() {
        guard emit(.consentGiven) else { return }
        consented = true
        startTransfer()
    }

    /// The player declined. Nothing is downloaded.
    public func decline() {
        consented = false
        emit(.consentDeclined)
    }

    /// Pauses the transfer. Finished segments are kept; the rest resume later.
    public func pause() {
        guard emit(.pause) else { return }
        task?.cancel()
        task = nil
    }

    /// Retries after a pause or a retryable failure. Before consent it repeats the checks with the
    /// current device state, so the player is never asked to consent to a stale size or link.
    public func resume(probe: SceneryDeviceProbe) async {
        guard let catalog else { return }
        guard consented else {
            await prepare(catalog: catalog, advisor: advisor,
                          storage: (probe.availableCapacity, probe.totalCapacity), network: probe.network)
            return
        }
        guard probe.network.blockingFailure == nil else { return }
        guard emit(.resume) else { return }
        missing = ScenerySelection.missing(in: catalog, installed: await backend.installedSegmentIDs())
        startTransfer()
    }

    /// Removes the installed scenery and stops any transfer.
    public func remove() async {
        task?.cancel()
        task = nil
        consented = false
        let ids = catalog?.segments.map(\.id) ?? []
        for id in ids { try? await backend.remove(segmentID: id) }
        emit(.remove)
    }

    /// Waits for the running transfer to end. Used by tests and by the UI on shutdown.
    public func waitForTransfer() async { await task?.value }

    // MARK: - Transfer

    private func startTransfer() {
        task?.cancel()
        task = Task { await self.run() }
    }

    private func run() async {
        guard let catalog else { return }
        var completed: Int64 = 0
        do {
            for segment in missing {
                try Task.checkCancellation()
                let base = completed
                try await backend.download(segment) { bytes in
                    Task { await self.reportProgress(base + bytes) }
                }
                try Task.checkCancellation()
                let hash = try await backend.archiveHash(of: segment)
                guard hash == segment.sha256 else {
                    try? await backend.remove(segmentID: segment.id)
                    emit(.failed(.integrity(segment: segment.id), retryable: false))
                    return
                }
                completed += segment.bytes
            }
            emit(.downloadsFinished)
            emit(.verified(release: catalog.release))
        } catch is CancellationError {
            // Paused by the player: the phase was already set by `pause()`.
        } catch {
            emit(.failed(.network, retryable: true))
        }
    }

    private func reportProgress(_ bytes: Int64) {
        emit(.progress(completedBytes: bytes))
    }
}
