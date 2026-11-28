import Testing
import Foundation
@testable import SFContent

private enum FakeNetworkError: Error { case dropped }

/// In-memory backend: records installed IDs, and can fail or corrupt a named segment.
private actor FakeSceneryBackend: SceneryPackBackend {
    var installed: Set<String> = []
    var corruptHashes: [String: String] = [:]
    var failingIDs: Set<String> = []
    private(set) var removed: [String] = []

    func setCorrupt(_ id: String, hash: String) { corruptHashes[id] = hash }
    func setFailing(_ id: String) { failingIDs.insert(id) }
    func clearFailures() { failingIDs.removeAll() }

    func installedSegmentIDs() async -> Set<String> { installed }

    func download(_ segment: ScenerySegment, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if failingIDs.contains(segment.id) { throw FakeNetworkError.dropped }
        progress(segment.bytes)
        installed.insert(segment.id)
    }

    func archiveHash(of segment: ScenerySegment) async throws -> String? {
        corruptHashes[segment.id] ?? segment.sha256
    }

    func remove(segmentID: String) async throws {
        installed.remove(segmentID)
        removed.append(segmentID)
    }
}

@Suite struct SceneryInstallerTests {
    let gb = ScenerySpace.gigabyte
    let hash = String(repeating: "a", count: 64)
    let box = SceneryBounds(minLat: 50, maxLat: 60, minLon: -10, maxLon: 0)

    func catalog() -> SceneryCatalog {
        SceneryCatalog(release: "earth-test", segments: [
            ScenerySegment(id: "eu-west-z6", bytes: 2_000, sha256: hash, bounds: box),
            ScenerySegment(id: "na-east-z6", bytes: 3_000, sha256: hash,
                           bounds: SceneryBounds(minLat: 30, maxLat: 45, minLon: -80, maxLon: -70)),
        ], attribution: ["Test data"])
    }

    @Test func fullInstallRunsAfterConsent() async {
        let backend = FakeSceneryBackend()
        let installer = SceneryInstaller(backend: backend)
        await installer.prepare(catalog: catalog(), advisor: ScenerySpaceAdvisor(), storage: (100 * gb, 256 * gb), network: ScenerySyncNetworkPolicy(link: .wifi))
        let v1 = await installer.phase == .awaitingConsent(requiredBytes: 5_000)
        #expect(v1)
        await installer.consent()
        await installer.waitForTransfer()
        let v2 = await installer.phase == .installed(release: "earth-test", bytes: 5_000)
        #expect(v2)
        let v3 = await backend.installed == ["eu-west-z6", "na-east-z6"]
        #expect(v3)
    }

    @Test func declineLeavesNothingInstalled() async {
        let backend = FakeSceneryBackend()
        let installer = SceneryInstaller(backend: backend)
        await installer.prepare(catalog: catalog(), advisor: ScenerySpaceAdvisor(), storage: (100 * gb, 256 * gb), network: ScenerySyncNetworkPolicy(link: .wifi))
        await installer.decline()
        let v4 = await installer.phase == .notInstalled
        #expect(v4)
        let v5 = await backend.installed.isEmpty
        #expect(v5)
    }

    @Test func notEnoughSpaceFailsBeforeAnyDownload() async {
        let backend = FakeSceneryBackend()
        let installer = SceneryInstaller(backend: backend)
        await installer.prepare(catalog: catalog(), advisor: ScenerySpaceAdvisor(), storage: (1 * gb, 256 * gb), network: ScenerySyncNetworkPolicy(link: .wifi))
        if case .failed(.insufficientStorage, let retryable, _) = await installer.phase {
            #expect(!retryable)
        } else {
            Issue.record("expected insufficientStorage, got \(await installer.phase)")
        }
        let v6 = await backend.installed.isEmpty
        #expect(v6)
    }

    @Test func cellularWithoutPermissionWaitsForWiFiAndCanRetry() async {
        let installer = SceneryInstaller(backend: FakeSceneryBackend())
        await installer.prepare(catalog: catalog(), advisor: ScenerySpaceAdvisor(), storage: (100 * gb, 256 * gb), network: ScenerySyncNetworkPolicy(link: .cellular))
        if case .failed(.waitingForWiFi, let retryable, _) = await installer.phase {
            #expect(retryable)
        } else {
            Issue.record("expected waitingForWiFi, got \(await installer.phase)")
        }
    }

    @Test func corruptArchiveFailsWithIntegrityAndIsRemoved() async {
        let backend = FakeSceneryBackend()
        await backend.setCorrupt("na-east-z6", hash: String(repeating: "b", count: 64))
        let installer = SceneryInstaller(backend: backend)
        await installer.prepare(catalog: catalog(), advisor: ScenerySpaceAdvisor(), storage: (100 * gb, 256 * gb), network: ScenerySyncNetworkPolicy(link: .wifi))
        await installer.consent()
        await installer.waitForTransfer()
        let v7 = await installer.phase == .failed(.integrity(segment: "na-east-z6"), retryable: false, totalBytes: 5_000)
        #expect(v7)
        let v8 = await backend.removed == ["na-east-z6"]
        #expect(v8)
    }

    @Test func networkDropIsRetryableAndResumeFinishes() async {
        let backend = FakeSceneryBackend()
        await backend.setFailing("na-east-z6")
        let installer = SceneryInstaller(backend: backend)
        await installer.prepare(catalog: catalog(), advisor: ScenerySpaceAdvisor(), storage: (100 * gb, 256 * gb), network: ScenerySyncNetworkPolicy(link: .wifi))
        await installer.consent()
        await installer.waitForTransfer()
        if case .failed(.network, let retryable, _) = await installer.phase {
            #expect(retryable)
        } else {
            Issue.record("expected network failure, got \(await installer.phase)")
        }
        // The connection comes back: resume only downloads what is still missing.
        await backend.clearFailures()
        await installer.resume(probe: SceneryDeviceProbe(availableCapacity: 100 * gb, totalCapacity: 256 * gb, network: ScenerySyncNetworkPolicy(link: .wifi)))
        await installer.waitForTransfer()
        let v9 = await installer.phase == .installed(release: "earth-test", bytes: 5_000)
        #expect(v9)
    }

    @Test func removeDeletesEverySegment() async {
        let backend = FakeSceneryBackend()
        let installer = SceneryInstaller(backend: backend)
        await installer.prepare(catalog: catalog(), advisor: ScenerySpaceAdvisor(), storage: (100 * gb, 256 * gb), network: ScenerySyncNetworkPolicy(link: .wifi))
        await installer.consent()
        await installer.waitForTransfer()
        await installer.remove()
        let v10 = await installer.phase == .notInstalled
        #expect(v10)
        let v11 = await backend.installed.isEmpty
        #expect(v11)
    }

    @Test func observersSeeEveryPhaseInOrder() async {
        let installer = SceneryInstaller(backend: FakeSceneryBackend())
        let stream = await installer.updates()
        await installer.prepare(catalog: catalog(), advisor: ScenerySpaceAdvisor(), storage: (100 * gb, 256 * gb), network: ScenerySyncNetworkPolicy(link: .wifi))
        await installer.consent()
        await installer.waitForTransfer()
        var seen: [ScenerySyncPhase] = []
        for await phase in stream {
            seen.append(phase)
            if case .installed = phase { break }
        }
        #expect(seen.first == .notInstalled)
        #expect(seen.last == .installed(release: "earth-test", bytes: 5_000))
        #expect(seen.contains(.awaitingConsent(requiredBytes: 5_000)))
    }
}
