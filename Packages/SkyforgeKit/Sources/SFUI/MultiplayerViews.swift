// SKYFORGE — Apache-2.0
// Multiplayer lobby: Game Center sign-in, free auto-match up to the GameKit cap, and the live pilot list.
#if canImport(SwiftUI) && canImport(GameKit)
import SwiftUI
import SFNetcode

@MainActor @Observable
final class MultiplayerLobbyModel {
    enum Status: Equatable {
        case idle
        case searching
        case connected
        case failed(String)
    }

    var status: Status = .idle
    var signedIn = GameCenter.isSignedIn
    var peers: [PeerID] = []
    private(set) var session: MultiplayerSession?

    /// Refreshes sign-in and the pilot list. Called once a second while the lobby is on screen.
    func tick() async {
        signedIn = GameCenter.isSignedIn
        if let session {
            peers = await session.peers
        }
    }

    func findSession() async {
        status = .searching
        do {
            let transport = try await GameKitTransport.findMatch()
            let session = MultiplayerSession(transport: transport)
            await session.start()
            self.session = session
            peers = await session.peers
            status = .connected
        } catch {
            // A cancelled search has already been reset to idle by cancelSearch().
            if status == .searching {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSearch() {
        GameKitTransport.cancelSearch()
        status = .idle
    }

    func leave() async {
        await session?.stop()
        session = nil
        peers = []
        status = .idle
    }
}

public struct MultiplayerLobbyView: View {
    @State private var model = MultiplayerLobbyModel()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Fly with up to \(SessionLimits.maxPlayers) pilots in one free Game Center session. No paid servers. Missions and flights stay on your device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                statusCard
                actions
            }
            .padding(16)
        }
        .navigationTitle("Multiplayer")
        .task {
            while !Task.isCancelled {
                await model.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusTitle).font(.headline)
            Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actions: some View {
        if !model.signedIn {
            Button("Sign in to Game Center") { GameCenter.beginSignIn() }
                .buttonStyle(.borderedProminent)
        } else {
            switch model.status {
            case .idle, .failed:
                Button("Find a session") { Task { await model.findSession() } }
                    .buttonStyle(.borderedProminent)
            case .searching:
                Button("Cancel search") { model.cancelSearch() }
                    .buttonStyle(.bordered)
            case .connected:
                Button("Leave session", role: .destructive) { Task { await model.leave() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var statusTitle: String {
        if !model.signedIn { return "Not signed in to Game Center" }
        switch model.status {
        case .idle: return "Not in a session"
        case .searching: return "Searching for pilots"
        case .connected: return "In a session"
        case .failed: return "Could not join"
        }
    }

    private var statusDetail: String {
        if !model.signedIn { return "Sign in to Game Center to fly with other pilots." }
        switch model.status {
        case .idle: return "Find a session to match with pilots online right now."
        case .searching: return "Matching with pilots. This can take a minute."
        case .connected:
            let count = model.peers.count
            return count == 0 ? "Waiting for other pilots to join." : "\(count) other pilot\(count == 1 ? "" : "s") in the session."
        case .failed(let message): return message
        }
    }
}
#endif
