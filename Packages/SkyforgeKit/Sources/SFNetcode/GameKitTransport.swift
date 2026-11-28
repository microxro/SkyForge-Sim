// SKYFORGE — Apache-2.0. See LICENSE at the repository root.
// GameKit real-time transport: one GKMatch per session, capped at SessionLimits.maxPlayers.
// Game Center is free and needs no paid server. The App ID needs the Game Center capability.
#if canImport(GameKit)
import Foundation
import GameKit
#if canImport(UIKit)
import UIKit
#endif

/// GameKit-backed `MultiplayerTransport`. Peer IDs are Game Center player IDs.
public final class GameKitTransport: NSObject, MultiplayerTransport, GKMatchDelegate, @unchecked Sendable {
    public let localPeer: PeerID
    public let events: AsyncStream<TransportEvent>

    private let match: GKMatch
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    /// Connected remote players by peer ID. Guarded by `lock`.
    private var players: [PeerID: GKPlayer] = [:]

    private init(match: GKMatch) {
        self.match = match
        self.localPeer = PeerID(GKLocalPlayer.local.gamePlayerID)
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        super.init()
        match.delegate = self
        for player in match.players {
            setConnected(player, connected: true)
        }
    }

    /// Finds a free Game Center match with `minPlayers` to `maxPlayers` pilots. Throws when cancelled or when GameKit fails.
    public static func findMatch(minPlayers: Int = 2, maxPlayers: Int = SessionLimits.maxPlayers) async throws -> GameKitTransport {
        let request = GKMatchRequest()
        request.minPlayers = max(2, minPlayers)
        request.maxPlayers = min(maxPlayers, SessionLimits.maxPlayers)
        let match = try await GKMatchmaker.shared().findMatch(for: request)
        return GameKitTransport(match: match)
    }

    /// Stops an in-progress `findMatch` search.
    public static func cancelSearch() {
        GKMatchmaker.shared().cancel()
    }

    public func currentPeers() async -> [PeerID] {
        lock.lock()
        defer { lock.unlock() }
        return players.keys.sorted { $0.rawValue < $1.rawValue }
    }

    public func send(_ payload: [UInt8], to peers: [PeerID]?, mode: DeliveryMode) async throws {
        let dataMode: GKMatch.SendDataMode = mode == .reliable ? .reliable : .unreliable
        let data = Data(payload)
        if let peers {
            let targets = targetPlayers(for: peers)
            guard !targets.isEmpty else { return }
            try match.send(data, to: targets, dataMode: dataMode)
        } else {
            guard !currentPlayers().isEmpty else { return }
            try match.sendData(toAllPlayers: data, with: dataMode)
        }
    }

    public func disconnect() async {
        match.disconnect()
        finish()
    }

    // MARK: GKMatchDelegate

    public func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        switch state {
        case .connected:
            setConnected(player, connected: true)
        case .disconnected:
            setConnected(player, connected: false)
        default:
            break
        }
    }

    public func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let peer = PeerID(player.gamePlayerID)
        continuation.yield(.packet(InboundPacket(from: peer, payload: [UInt8](data))))
    }

    public func match(_ match: GKMatch, didFailWithError error: Error?) {
        finish()
    }

    // MARK: Helpers

    private func setConnected(_ player: GKPlayer, connected: Bool) {
        let peer = PeerID(player.gamePlayerID)
        lock.lock()
        let changed: Bool
        if connected {
            changed = players[peer] == nil
            if changed { players[peer] = player }
        } else {
            changed = players.removeValue(forKey: peer) != nil
        }
        lock.unlock()
        guard changed else { return }
        continuation.yield(connected ? .peerJoined(peer) : .peerLeft(peer))
    }

    private func currentPlayers() -> [GKPlayer] {
        lock.lock()
        defer { lock.unlock() }
        return Array(players.values)
    }

    private func targetPlayers(for peers: [PeerID]) -> [GKPlayer] {
        lock.lock()
        defer { lock.unlock() }
        return peers.compactMap { players[$0] }
    }

    private func finish() {
        continuation.finish()
    }
}

/// Game Center sign-in for the local player.
public enum GameCenter {
    public static var isSignedIn: Bool { GKLocalPlayer.local.isAuthenticated }

    /// Starts the system sign-in flow. On iOS the sign-in sheet is presented over the top view controller.
    /// On macOS the player signs in through the Game Center settings instead.
    @MainActor
    public static func beginSignIn() {
        GKLocalPlayer.local.authenticateHandler = { viewController, _ in
            #if canImport(UIKit)
            guard let viewController else { return }
            Task { @MainActor in presentOnTop(viewController) }
            #endif
        }
    }

    #if canImport(UIKit)
    @MainActor
    private static func presentOnTop(_ viewController: UIViewController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        top?.present(viewController, animated: true)
    }
    #endif
}
#endif
