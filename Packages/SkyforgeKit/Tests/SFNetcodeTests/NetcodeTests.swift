// SKYFORGE — Apache-2.0. See LICENSE at the repository root.
import Testing
@testable import SFNetcode

private func snapshot(_ seq: UInt32, _ t: Double, x: Double = 6_500_000, vx: Float = 0) -> AircraftSnapshot {
    AircraftSnapshot(
        sequence: seq,
        simTime: t,
        positionECEF: SIMD3(x, 0, 0),
        velocityECEF: SIMD3(vx, 0, 0),
        orientation: SIMD4(0, 0, 0, 1),
        flags: 0
    )
}

@Suite struct SnapshotWireTests {
    @Test func roundTripPreservesFields() throws {
        let s = AircraftSnapshot(
            sequence: 42,
            simTime: 12.5,
            positionECEF: SIMD3(6_400_000.25, -1_200_000.5, 300_000.0),
            velocityECEF: SIMD3(120, -3, 0.5),
            orientation: SIMD4(0, 0.7071068, 0, 0.7071068),
            flags: 0b101
        )
        let bytes = s.encode()
        #expect(bytes.count == AircraftSnapshot.encodedSize)
        #expect(try AircraftSnapshot.decode(bytes) == s)
    }

    @Test func rejectsTruncatedPacket() {
        let bytes = snapshot(1, 0).encode()
        #expect(throws: WireError.truncated) {
            try AircraftSnapshot.decode(Array(bytes.prefix(10)))
        }
    }

    @Test func rejectsUnknownVersion() {
        var bytes = snapshot(1, 0).encode()
        bytes[0] = 99
        #expect(throws: WireError.badVersion(99)) {
            try AircraftSnapshot.decode(bytes)
        }
    }

    @Test func rejectsImpossibleSpeed() {
        let s = snapshot(1, 0, vx: 2_000)
        #expect(throws: WireError.invalidValue) {
            try s.validate()
        }
    }

    @Test func rejectsPositionUnderSurface() {
        let s = snapshot(1, 0, x: 1_000_000)
        #expect(throws: WireError.invalidValue) {
            try s.validate()
        }
    }

    @Test func rejectsNonFiniteValues() {
        let s = snapshot(1, .nan)
        #expect(throws: WireError.invalidValue) {
            try s.validate()
        }
    }
}

@Suite struct RemoteAircraftBufferTests {
    @Test func interpolatesBetweenSnapshots() {
        var buffer = RemoteAircraftBuffer(interpolationDelay: 0.1)
        buffer.insert(snapshot(1, 0.0, x: 6_500_000), arrival: 0.0)
        buffer.insert(snapshot(2, 1.0, x: 6_600_000), arrival: 1.0)
        // Render time 0.6 maps to sender time 0.5 with zero clock offset.
        let pose = buffer.pose(at: 0.6)
        #expect(pose?.extrapolated == false)
        #expect(abs((pose?.positionECEF.x ?? 0) - 6_550_000) < 1)
    }

    @Test func extrapolatesWithVelocityAndCapsIt() {
        var buffer = RemoteAircraftBuffer(interpolationDelay: 0.1, maxExtrapolation: 0.5)
        buffer.insert(snapshot(1, 0.0, x: 6_500_000, vx: 100), arrival: 0.0)
        // Far past the newest sample, so prediction is capped at 0.5 s of motion.
        let pose = buffer.pose(at: 10.0)
        #expect(pose?.extrapolated == true)
        #expect(abs((pose?.positionECEF.x ?? 0) - 6_500_050) < 1)
    }

    @Test func rejectsStaleAndDuplicateSequences() {
        var buffer = RemoteAircraftBuffer()
        #expect(buffer.insert(snapshot(5, 1.0), arrival: 1.0))
        #expect(buffer.insert(snapshot(4, 0.9), arrival: 1.1) == false)
        #expect(buffer.insert(snapshot(5, 1.0), arrival: 1.2) == false)
    }

    @Test func noPoseBeforeFirstSnapshot() {
        let buffer = RemoteAircraftBuffer()
        #expect(buffer.pose(at: 0) == nil)
    }
}

@Suite struct LoopbackTransportTests {
    @Test func deliversToOtherPeersOnly() async throws {
        let net = LoopbackNetwork()
        let a = try await net.join(PeerID("a"))
        let b = try await net.join(PeerID("b"))
        try await a.send([1, 2, 3], to: nil, mode: .unreliable)

        var events = b.events.makeAsyncIterator()
        // b joined after a, so its first event is a join for a, then the packet.
        guard case .peerJoined(let joined)? = await events.next() else {
            Issue.record("expected a join event")
            return
        }
        #expect(joined == PeerID("a"))
        guard case .packet(let packet)? = await events.next() else {
            Issue.record("expected a packet")
            return
        }
        #expect(packet.from == PeerID("a"))
        #expect(packet.payload == [1, 2, 3])
    }

    @Test func enforcesSessionCap() async throws {
        let net = LoopbackNetwork(maxPlayers: 2)
        _ = try await net.join(PeerID("a"))
        _ = try await net.join(PeerID("b"))
        var sawFull = false
        do {
            _ = try await net.join(PeerID("c"))
        } catch NetError.sessionFull {
            sawFull = true
        }
        #expect(sawFull)
    }

    @Test func defaultCapIsSixteen() {
        #expect(SessionLimits.maxPlayers == 16)
    }
}
