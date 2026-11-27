import Testing
import Foundation
@testable import SFContent

@Suite struct SceneryCatalogTests {
    static let hash = String(repeating: "a", count: 64)
    static let box = SceneryBounds(minLat: 50, maxLat: 60, minLon: -10, maxLon: 0)

    static func catalog(_ segments: [ScenerySegment]? = nil) -> SceneryCatalog {
        SceneryCatalog(release: "earth-test", segments: segments ?? [
            ScenerySegment(id: "eu-west-z6", bytes: 2_000, sha256: hash, bounds: box),
            ScenerySegment(id: "na-east-z6", bytes: 3_000, sha256: hash,
                           bounds: SceneryBounds(minLat: 30, maxLat: 45, minLon: -80, maxLon: -70)),
        ], attribution: ["Test data"])
    }

    @Test func validCatalogPassesAndSumsBytes() throws {
        let c = try Self.catalog().validated()
        #expect(c.totalBytes == 5_000)
        #expect(c.segment(id: "na-east-z6")?.bytes == 3_000)
    }

    @Test func rejectsUnknownSchema() {
        var c = Self.catalog(); c.schema = 2
        #expect(throws: SceneryCatalogError.unsupportedSchema(2)) { _ = try c.validated() }
    }

    @Test func rejectsEmptyAndDuplicateSegments() {
        #expect(throws: SceneryCatalogError.noSegments) { _ = try Self.catalog([]).validated() }
        let dup = [ScenerySegment(id: "x", bytes: 1, sha256: Self.hash, bounds: Self.box),
                   ScenerySegment(id: "x", bytes: 1, sha256: Self.hash, bounds: Self.box)]
        #expect(throws: SceneryCatalogError.duplicateSegment("x")) { _ = try Self.catalog(dup).validated() }
    }

    @Test func rejectsUnsafeIDsSizesHashesAndBounds() {
        let base = ScenerySegment(id: "ok-1", bytes: 1, sha256: Self.hash, bounds: Self.box)
        var bad = base; bad.id = "../etc"
        #expect(throws: SceneryCatalogError.invalidSegmentID("../etc")) { _ = try Self.catalog([bad]).validated() }
        bad = base; bad.bytes = 0
        #expect(throws: SceneryCatalogError.nonPositiveSize("ok-1")) { _ = try Self.catalog([bad]).validated() }
        bad = base; bad.sha256 = "ABC"
        #expect(throws: SceneryCatalogError.invalidHash("ok-1")) { _ = try Self.catalog([bad]).validated() }
        bad = base; bad.bounds = SceneryBounds(minLat: 10, maxLat: 5, minLon: 0, maxLon: 1)
        #expect(throws: SceneryCatalogError.invalidBounds("ok-1")) { _ = try Self.catalog([bad]).validated() }
    }

    @Test func catalogRoundTripsThroughJSON() throws {
        let c = try Self.catalog().validated()
        let back = try JSONDecoder().decode(SceneryCatalog.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}

@Suite struct ScenerySyncMachineTests {
    @Test func happyPathConsentDownloadVerifyInstall() {
        var m = ScenerySyncMachine()
        let ok1 = m.apply(.requestInstall(requiredBytes: 100))
        #expect(ok1)
        #expect(m.phase == .awaitingConsent(requiredBytes: 100))
        let ok2 = m.apply(.consentGiven)
        #expect(ok2)
        let ok3 = m.apply(.progress(completedBytes: 40))
        #expect(ok3)
        #expect(m.phase == .downloading(completedBytes: 40, totalBytes: 100))
        let ok4 = m.apply(.downloadsFinished)
        #expect(ok4)
        #expect(m.phase == .verifying(totalBytes: 100))
        let ok5 = m.apply(.verified(release: "r1"))
        #expect(ok5)
        #expect(m.phase == .installed(release: "r1", bytes: 100))
    }

    @Test func consentDeclinedReturnsToNotInstalled() {
        var m = ScenerySyncMachine()
        m.apply(.requestInstall(requiredBytes: 5))
        let ok6 = m.apply(.consentDeclined)
        #expect(ok6)
        #expect(m.phase == .notInstalled)
    }

    @Test func progressNeverExceedsTotalOrGoesNegative() {
        var m = ScenerySyncMachine(phase: .downloading(completedBytes: 0, totalBytes: 10))
        m.apply(.progress(completedBytes: 99))
        #expect(m.phase == .downloading(completedBytes: 10, totalBytes: 10))
        m.apply(.progress(completedBytes: -5))
        #expect(m.phase == .downloading(completedBytes: 0, totalBytes: 10))
    }

    @Test func pauseAndResumeKeepProgress() {
        var m = ScenerySyncMachine(phase: .downloading(completedBytes: 30, totalBytes: 100))
        m.apply(.pause)
        #expect(m.phase == .paused(completedBytes: 30, totalBytes: 100))
        m.apply(.resume)
        #expect(m.phase == .downloading(completedBytes: 30, totalBytes: 100))
    }

    @Test func retryableFailureCanResumeButFatalFailureCannot() {
        var m = ScenerySyncMachine(phase: .downloading(completedBytes: 30, totalBytes: 100))
        m.apply(.failed(.network, retryable: true))
        #expect(m.phase == .failed(.network, retryable: true, totalBytes: 100))
        let ok7 = m.apply(.resume)
        #expect(ok7)
        var f = ScenerySyncMachine(phase: .downloading(completedBytes: 30, totalBytes: 100))
        f.apply(.failed(.integrity(segment: "eu-west-z6"), retryable: false))
        let ok8 = f.apply(.resume)
        #expect(!ok8)
        #expect(f.phase == .failed(.integrity(segment: "eu-west-z6"), retryable: false, totalBytes: 100))
    }

    @Test func illegalEventsLeaveStateUnchanged() {
        var m = ScenerySyncMachine()
        let ok9 = m.apply(.consentGiven)
        #expect(!ok9)
        let ok10 = m.apply(.pause)
        #expect(!ok10)
        let ok11 = m.apply(.progress(completedBytes: 1))
        #expect(!ok11)
        #expect(m.phase == .notInstalled)
    }

    @Test func removeIsAlwaysAllowed() {
        var m = ScenerySyncMachine(phase: .installed(release: "r1", bytes: 9))
        let ok12 = m.apply(.remove)
        #expect(ok12)
        #expect(m.phase == .notInstalled)
    }
}

@Suite struct ScenerySpaceTests {
    let gb = ScenerySpace.gigabyte

    @Test func reserveIsFivePercentFloorOrTenPercentOfCapacity() {
        #expect(ScenerySpace.reserve(totalCapacity: 64 * gb) == 6_400_000_000)
        #expect(ScenerySpace.reserve(totalCapacity: 128 * gb) == 12_800_000_000)
        #expect(ScenerySpace.reserve(totalCapacity: 20 * gb) == 5 * gb)
    }

    @Test func quotaIsClampedToRange() {
        #expect(ScenerySpace.clampQuota(0) == 1 * gb)
        #expect(ScenerySpace.clampQuota(900 * gb) == 500 * gb)
        #expect(ScenerySpaceAdvisor().quotaBytes == 10 * gb)
    }

    @Test func assessmentReportsQuotaAndDeviceShortfalls() {
        let advisor = ScenerySpaceAdvisor(quotaBytes: 10 * gb)
        #expect(advisor.assess(requiredBytes: 4 * gb, installedBytes: 0, availableCapacity: 100 * gb, totalCapacity: 256 * gb) == .ok)
        #expect(advisor.assess(requiredBytes: 4 * gb, installedBytes: 8 * gb, availableCapacity: 100 * gb, totalCapacity: 256 * gb) == .overQuota(overBy: 2 * gb))
        // Needs 4 GB + 25.6 GB reserve (10% of 256 GB); only 20 GB free.
        #expect(advisor.assess(requiredBytes: 4 * gb, installedBytes: 0, availableCapacity: 20 * gb, totalCapacity: 256 * gb) == .insufficientDevice(shortBy: 9_600_000_000))
    }

    @Test func missingSegmentsSkipInstalledOnes() throws {
        let c = try SceneryCatalogTests.catalog().validated()
        #expect(ScenerySelection.missing(in: c, installed: ["eu-west-z6"]).map(\.id) == ["na-east-z6"])
        #expect(ScenerySelection.missingBytes(in: c, installed: []) == 5_000)
    }
}

@Suite struct ScenerySourceTests {
    @Test func pointUsesInstalledSegmentOrFallsBackToProcedural() throws {
        let c = try SceneryCatalogTests.catalog().validated()
        // London is inside eu-west-z6 (50–60N, 10W–0).
        #expect(ScenerySourceResolver.source(latitude: 51.5, longitude: -0.1, catalog: c, installed: ["eu-west-z6"]) == .earthSegment(id: "eu-west-z6"))
        // Same point, segment not installed yet: procedural, so flight never blocks.
        #expect(ScenerySourceResolver.source(latitude: 51.5, longitude: -0.1, catalog: c, installed: []) == .procedural)
        // No catalog at all (base game only).
        #expect(ScenerySourceResolver.source(latitude: 51.5, longitude: -0.1, catalog: nil, installed: ["eu-west-z6"]) == .procedural)
        // Point outside every segment.
        #expect(ScenerySourceResolver.source(latitude: -33.9, longitude: 151.2, catalog: c, installed: ["eu-west-z6", "na-east-z6"]) == .procedural)
    }

    @Test func networkPolicyIsWiFiOnlyByDefault() {
        #expect(ScenerySyncNetworkPolicy(link: .wifi).blockingFailure == nil)
        #expect(ScenerySyncNetworkPolicy(link: .cellular).blockingFailure == .waitingForWiFi)
        #expect(ScenerySyncNetworkPolicy(allowCellular: true, link: .cellular).blockingFailure == nil)
        #expect(ScenerySyncNetworkPolicy(allowCellular: true, link: .cellular, isExpensiveOrConstrained: true).blockingFailure == .waitingForWiFi)
        #expect(ScenerySyncNetworkPolicy(link: .none).blockingFailure == .network)
    }
}
