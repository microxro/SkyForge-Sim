// SKYFORGE — Apache-2.0. See LICENSE at the repository root.
// Runs one multiplayer session on any MultiplayerTransport: sends our aircraft state, receives and
// validates remote states, and keeps one interpolation buffer per remote peer. Pure Swift.

import Foundation

public actor MultiplayerSession {
    /// Seconds on the local clock. Injected so tests can drive time.
    public typealias TimeSource = @Sendable () -> Double

    public let transport: any MultiplayerTransport
    private let timeSource: TimeSource
    private var buffers: [PeerID: RemoteAircraftBuffer] = [:]
    private var knownPeers: Set<PeerID> = []
    private var eventTask: Task<Void, Never>?

    /// Packets that failed wire validation. Counted for diagnostics and anti-cheat review.
    public private(set) var rejectedPackets = 0

    public init(
        transport: any MultiplayerTransport,
        timeSource: @escaping TimeSource = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.transport = transport
        self.timeSource = timeSource
    }

    /// Peers currently in the session, excluding the local pilot, sorted for stable display.
    public var peers: [PeerID] {
        knownPeers.sorted { $0.rawValue < $1.rawValue }
    }

    /// Starts consuming transport events. Calling it again has no effect.
    public func start() async {
        guard eventTask == nil else { return }
        knownPeers = Set(await transport.currentPeers())
        let events = transport.events
        eventTask = Task {
            for await event in events {
                self.handle(event)
            }
        }
    }

    /// Sends our aircraft state to every peer. Unreliable: a late or lost packet is replaced by the next one.
    public func broadcast(_ snapshot: AircraftSnapshot) async throws {
        try await transport.send(snapshot.encode(), to: nil, mode: .unreliable)
    }

    /// Interpolated pose of a remote peer at local render time `now`, in seconds. Nil when unknown.
    public func pose(of peer: PeerID, at now: Double) -> RemotePose? {
        buffers[peer]?.pose(at: now)
    }

    /// Leaves the session and forgets every remote peer.
    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await transport.disconnect()
        buffers = [:]
        knownPeers = []
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .peerJoined(let peer):
            knownPeers.insert(peer)
        case .peerLeft(let peer):
            knownPeers.remove(peer)
            buffers[peer] = nil
        case .packet(let packet):
            // Packets from peers we have not seen join are dropped: they may be stale or spoofed.
            guard knownPeers.contains(packet.from) else { return }
            guard let snapshot = try? AircraftSnapshot.decode(packet.payload) else {
                rejectedPackets += 1
                return
            }
            var buffer = buffers[packet.from] ?? RemoteAircraftBuffer()
            buffer.insert(snapshot, arrival: timeSource())
            buffers[packet.from] = buffer
        }
    }
}
