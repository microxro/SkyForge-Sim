// SKYFORGE — Apache-2.0. See LICENSE at the repository root.
// In-memory transport. Delivers packets between peers in one process, with no loss. Used by tests
// and by local dry runs of the multiplayer code.

public actor LoopbackNetwork {
    private var members: [PeerID: AsyncStream<TransportEvent>.Continuation] = [:]
    private let maxPlayers: Int

    public init(maxPlayers: Int = SessionLimits.maxPlayers) {
        self.maxPlayers = maxPlayers
    }

    public func join(_ peer: PeerID) throws -> LoopbackTransport {
        guard members[peer] == nil else { throw NetError.duplicatePeer }
        guard members.count < maxPlayers else { throw NetError.sessionFull }
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        for (id, existing) in members {
            existing.yield(.peerJoined(peer))
            continuation.yield(.peerJoined(id))
        }
        members[peer] = continuation
        return LoopbackTransport(localPeer: peer, network: self, events: stream)
    }

    func peers(except peer: PeerID) -> [PeerID] {
        members.keys.filter { $0 != peer }
    }

    func deliver(from sender: PeerID, payload: [UInt8], to recipients: [PeerID]?) {
        let packet = InboundPacket(from: sender, payload: payload)
        for (id, continuation) in members where id != sender {
            if recipients == nil || recipients!.contains(id) {
                continuation.yield(.packet(packet))
            }
        }
    }

    func leave(_ peer: PeerID) {
        guard let continuation = members.removeValue(forKey: peer) else { return }
        continuation.finish()
        for existing in members.values {
            existing.yield(.peerLeft(peer))
        }
    }
}

public struct LoopbackTransport: MultiplayerTransport {
    public let localPeer: PeerID
    private let network: LoopbackNetwork
    public let events: AsyncStream<TransportEvent>

    init(localPeer: PeerID, network: LoopbackNetwork, events: AsyncStream<TransportEvent>) {
        self.localPeer = localPeer
        self.network = network
        self.events = events
    }

    public func currentPeers() async -> [PeerID] {
        await network.peers(except: localPeer)
    }

    public func send(_ payload: [UInt8], to peers: [PeerID]?, mode: DeliveryMode) async throws {
        // Loopback never drops or reorders, so the delivery mode has no effect here.
        await network.deliver(from: localPeer, payload: payload, to: peers)
    }

    public func disconnect() async {
        await network.leave(localPeer)
    }
}
