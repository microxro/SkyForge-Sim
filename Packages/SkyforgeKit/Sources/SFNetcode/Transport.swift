// SKYFORGE — Apache-2.0. See LICENSE at the repository root.
// Transport abstraction for multiplayer. GameKit is the first implementation; a dedicated
// server can implement the same protocol later without touching gameplay code.

/// Identifies a remote participant inside one session.
public struct PeerID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Real-time session limit. Matches the GameKit real-time match maximum; no paid server is used.
public enum SessionLimits {
    public static let maxPlayers = 16
}

public enum DeliveryMode: Sendable {
    /// May be dropped or reordered. Used for aircraft state at 10 to 20 Hz.
    case unreliable
    /// Ordered and retransmitted. Used for chat, mission events and session control.
    case reliable
}

public struct InboundPacket: Sendable {
    public let from: PeerID
    public let payload: [UInt8]
    public init(from: PeerID, payload: [UInt8]) {
        self.from = from
        self.payload = payload
    }
}

public enum TransportEvent: Sendable {
    case peerJoined(PeerID)
    case peerLeft(PeerID)
    case packet(InboundPacket)
}

public enum NetError: Error, Equatable, Sendable {
    case sessionFull
    case duplicatePeer
    case notConnected
}

/// One session of up to `SessionLimits.maxPlayers` peers. Implementations: `LoopbackTransport` (tests), GameKit (next milestone).
public protocol MultiplayerTransport: Sendable {
    var localPeer: PeerID { get }
    /// Peers in the session, excluding the local peer.
    func currentPeers() async -> [PeerID]
    /// Join, leave and packet events for this session.
    var events: AsyncStream<TransportEvent> { get }
    /// Sends to `peers`, or to everyone else when `peers` is nil.
    func send(_ payload: [UInt8], to peers: [PeerID]?, mode: DeliveryMode) async throws
    func disconnect() async
}
