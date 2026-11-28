// SKYFORGE — Apache-2.0. See LICENSE at the repository root.
import Testing
@testable import SFNetcode

private func state(_ seq: UInt32, _ t: Double) -> AircraftSnapshot {
    AircraftSnapshot(
        sequence: seq,
        simTime: t,
        positionECEF: SIMD3(6_500_000, 0, 0),
        velocityECEF: SIMD3(80, 0, 0),
        orientation: SIMD4(0, 0, 0, 1),
        flags: 0
    )
}

/// Polls until `condition` holds or about one second passes.
private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite struct MultiplayerSessionTests {
    @Test func remoteStateBecomesPoseAndLeaveRemovesIt() async throws {
        let network = LoopbackNetwork()
        let alice = try await network.join(PeerID("alice"))
        let bob = try await network.join(PeerID("bob"))
        let bobSession = MultiplayerSession(transport: bob, timeSource: { 0 })
        await bobSession.start()

        try await alice.send(state(1, 0).encode(), to: nil, mode: .unreliable)
        try await waitUntil { await bobSession.pose(of: PeerID("alice"), at: 0) != nil }
        #expect(await bobSession.pose(of: PeerID("alice"), at: 0) != nil)
        #expect(await bobSession.peers == [PeerID("alice")])

        await alice.disconnect()
        try await waitUntil { await bobSession.peers.isEmpty }
        #expect(await bobSession.peers.isEmpty)
        #expect(await bobSession.pose(of: PeerID("alice"), at: 0) == nil)
    }

    @Test func malformedPacketIsCountedAndIgnored() async throws {
        let network = LoopbackNetwork()
        let alice = try await network.join(PeerID("alice"))
        let bob = try await network.join(PeerID("bob"))
        let bobSession = MultiplayerSession(transport: bob, timeSource: { 0 })
        await bobSession.start()

        try await alice.send([1, 2, 3], to: nil, mode: .unreliable)
        try await waitUntil { await bobSession.rejectedPackets == 1 }
        #expect(await bobSession.rejectedPackets == 1)
        #expect(await bobSession.pose(of: PeerID("alice"), at: 0) == nil)
    }

    @Test func broadcastReachesEveryOtherPeer() async throws {
        let network = LoopbackNetwork()
        let alice = try await network.join(PeerID("alice"))
        let bob = try await network.join(PeerID("bob"))
        let aliceSession = MultiplayerSession(transport: alice, timeSource: { 0 })
        let bobSession = MultiplayerSession(transport: bob, timeSource: { 0 })
        await aliceSession.start()
        await bobSession.start()

        try await aliceSession.broadcast(state(7, 0))
        try await waitUntil { await bobSession.pose(of: PeerID("alice"), at: 0) != nil }
        #expect(await bobSession.pose(of: PeerID("alice"), at: 0) != nil)
        // Our own state is never echoed back to us.
        #expect(await aliceSession.pose(of: PeerID("alice"), at: 0) == nil)
    }
}
