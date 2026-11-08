// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFWeather
import SFContent

/// Scripted transport: never touches the network.
actor ScriptedTransport: HTTPTransport {
    var responses: [Result<Data, TransportError>]
    private(set) var requests: [URL] = []
    var delayNanos: UInt64 = 0
    init(_ r: [Result<Data, TransportError>]) { responses = r }
    func setDelay(_ n: UInt64) { delayNanos = n }
    func get(_ url: URL) async throws -> Data {
        requests.append(url)
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        guard !responses.isEmpty else { throw TransportError.offline }
        return try responses.removeFirst().get()
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

@Suite struct METARServiceTests {
    static let ksfo = "KSFO 080156Z 29012KT 10SM FEW008 SCT200 14/09 A3002 RMK AO2 SLP165"
    static let ksfo2 = "KSFO 080256Z 30015G22KT 10SM CLR 13/08 A3004"

    @Test func requestUsesThePublicRawEndpoint() async {
        let svc = METARService(transport: ScriptedTransport([]))
        let url = await svc.requestURL(for: "KSFO")
        #expect(url.absoluteString == "https://aviationweather.gov/api/data/metar?ids=KSFO&format=raw")
    }

    @Test func cachesForTenMinutesThenRefetches() async throws {
        let clock = Clock()
        let t = ScriptedTransport([.success(Data((Self.ksfo + "\n").utf8)), .success(Data(Self.ksfo2.utf8))])
        let svc = METARService(transport: t, now: { clock.now })
        let a = try await svc.report(for: "ksfo")
        #expect(a.freshness == .fresh && a.metar.wind?.speedKnots == 12)
        clock.advance(599)
        _ = try await svc.report(for: "KSFO")
        #expect(await t.requests.count == 1)
        clock.advance(2)
        let b = try await svc.report(for: "KSFO")
        #expect(await t.requests.count == 2)
        #expect(b.metar.wind?.gustKnots == 22)
    }

    @Test func networkFailureServesStaleReport() async throws {
        let clock = Clock()
        let t = ScriptedTransport([.success(Data(Self.ksfo.utf8)), .failure(.offline)])
        let svc = METARService(transport: t, now: { clock.now })
        _ = try await svc.report(for: "KSFO")
        clock.advance(3_600)
        let r = try await svc.report(for: "KSFO")
        #expect(r.freshness == .stale(ageSeconds: 3_600))
        #expect(r.metar.raw == Self.ksfo)
    }

    @Test func offlineWithNothingCachedThrowsUnavailable() async {
        let svc = METARService(transport: ScriptedTransport([.failure(.offline)]))
        await #expect(throws: METARService.ServiceError.unavailable("EGLL")) { try await svc.report(for: "EGLL") }
    }

    @Test func emptyResponseIsNoReportAndInvalidIdsAreRejected() async {
        let svc = METARService(transport: ScriptedTransport([.success(Data())]))
        await #expect(throws: METARService.ServiceError.noReport("ZZZZ")) { try await svc.report(for: "ZZZZ") }
        await #expect(throws: METARService.ServiceError.invalidStation("SF O")) { try await svc.report(for: "SF O") }
        await #expect(throws: METARService.ServiceError.invalidStation("KSFO&x=1")) { try await svc.report(for: "KSFO&x=1") }
    }

    @Test func garbageIsNeverCached() async throws {
        let clock = Clock()
        let t = ScriptedTransport([.success(Data(Self.ksfo.utf8)), .success(Data("<html>maintenance</html>".utf8))])
        let svc = METARService(transport: t, now: { clock.now })
        _ = try await svc.report(for: "KSFO")
        clock.advance(700)
        let r = try await svc.report(for: "KSFO")   // bad body → stale good report
        #expect(r.metar.raw == Self.ksfo)
        if case .stale = r.freshness {} else { Issue.record("expected stale") }
    }

    @Test func picksTheMatchingLineAndKeepsSPECI() {
        let body = "KOAK 080153Z 28010KT 10SM CLR 15/08 A3001\nSPECI KSFO 080210Z 29014KT 6SM BR BKN007 13/10 A3002\n"
        #expect(METARService.firstReport(in: body, station: "KSFO")?.hasPrefix("SPECI KSFO") == true)
        #expect(METARService.firstReport(in: body, station: "KSJC") == nil)
    }

    @Test func diskCacheSurvivesRestartWhileOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-metar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let cache = try KeyedCache(root: dir)
        let first = METARService(transport: ScriptedTransport([.success(Data(Self.ksfo.utf8))]), cache: cache, now: { clock.now })
        _ = try await first.report(for: "KSFO")
        clock.advance(120)
        let reopened = METARService(transport: ScriptedTransport([.failure(.offline)]), cache: try KeyedCache(root: dir), now: { clock.now })
        let fresh = try await reopened.report(for: "KSFO")
        #expect(fresh.freshness == .fresh)           // within TTL: served from disk, no request
        clock.advance(3_000)
        let stale = try await reopened.report(for: "KSFO")
        #expect(stale.freshness == .stale(ageSeconds: 3_120))
    }

    @Test func concurrentCallersShareOneRequest() async throws {
        let t = ScriptedTransport([.success(Data(Self.ksfo.utf8)), .success(Data(Self.ksfo.utf8))])
        await t.setDelay(50_000_000)
        let svc = METARService(transport: t)
        async let a = svc.report(for: "KSFO")
        async let b = svc.report(for: "KSFO")
        _ = try await (a, b)
        #expect(await t.requests.count == 1)
    }
}
