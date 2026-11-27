// SKYFORGE — Apache-2.0
// Settings panel for the optional whole-Earth scenery download. Flight never waits on it: the status
// says what is installed and what the player can do next (download, pause, resume, remove).
#if canImport(SwiftUI)
import SwiftUI
import SFContent

public struct SceneryDownloadView: View {
    private let installer: SceneryInstaller
    private let catalog: SceneryCatalog
    private let advisor: ScenerySpaceAdvisor
    private let probe: @Sendable () -> SceneryDeviceProbe

    @State private var phase: ScenerySyncPhase = .notInstalled

    public init(installer: SceneryInstaller, catalog: SceneryCatalog, advisor: ScenerySpaceAdvisor,
                probe: @escaping @Sendable () -> SceneryDeviceProbe) {
        self.installer = installer
        self.catalog = catalog
        self.advisor = advisor
        self.probe = probe
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Status") { Text(statusText) }
                if let fraction = progressFraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Download progress")
                }
                actions
            } header: {
                Text("Whole-Earth scenery")
            } footer: {
                Text("Optional and free. Downloads over Wi-Fi by default. Flying works without it.")
            }
        }
        .task {
            for await next in await installer.updates() {
                phase = next
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch phase {
        case .notInstalled:
            Button("Download \(sizeText(catalog.totalBytes))") { startPrepare() }
        case .failed(_, let retryable, _):
            Button(retryable ? "Resume" : "Try again") { retry() }
        case .awaitingConsent(let bytes):
            Button("Download \(sizeText(bytes))") { Task { await installer.consent() } }
            Button("Not now", role: .cancel) { Task { await installer.decline() } }
        case .downloading:
            Button("Pause") { Task { await installer.pause() } }
        case .paused:
            Button("Resume") { retry() }
        case .verifying:
            EmptyView()
        case .installed:
            Button("Remove scenery", role: .destructive) { Task { await installer.remove() } }
        }
    }

    /// First request: checks space and link, then asks for consent.
    private func startPrepare() {
        let environment = probe()
        Task {
            await installer.prepare(catalog: catalog, advisor: advisor,
                                    storage: (environment.availableCapacity, environment.totalCapacity),
                                    network: environment.network)
        }
    }

    /// Resume, or repeat the checks before consent, using the device's current space and link.
    private func retry() {
        let environment = probe()
        Task { await installer.resume(probe: environment) }
    }

    private var progressFraction: Double? {
        switch phase {
        case .downloading(let done, let total), .paused(let done, let total):
            guard total > 0 else { return nil }
            return Double(done) / Double(total)
        case .verifying:
            return 1
        default:
            return nil
        }
    }

    private var statusText: String {
        switch phase {
        case .notInstalled:
            return "Not installed"
        case .awaitingConsent(let bytes):
            return "Ready to download \(sizeText(bytes))"
        case .downloading(let done, let total):
            return "Downloading \(sizeText(done)) of \(sizeText(total))"
        case .paused(let done, let total):
            return "Paused at \(sizeText(done)) of \(sizeText(total))"
        case .verifying:
            return "Checking files"
        case .installed(let release, _):
            return "Installed (\(release))"
        case .failed(let failure, _, _):
            return Self.message(for: failure)
        }
    }

    static func message(for failure: SceneryFailure) -> String {
        switch failure {
        case .insufficientStorage(let short):
            return "Not enough space. Free \(ByteCountFormatter.string(fromByteCount: short, countStyle: .file)) and try again."
        case .quotaExceeded(let over):
            return "Over your scenery limit by \(ByteCountFormatter.string(fromByteCount: over, countStyle: .file)). Raise the limit in Settings."
        case .waitingForWiFi:
            return "Waiting for Wi-Fi. Connect to Wi-Fi, or allow cellular in Settings."
        case .network:
            return "Connection lost. Resume when you are back online."
        case .integrity:
            return "A download failed its check and was removed. Try again."
        case .backend(let text):
            return "Could not download scenery: \(text)"
        }
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
#endif
