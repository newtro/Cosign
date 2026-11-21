import AppKit
import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle 2 with a live-activity safety gate so automatic background updates never
/// interrupt an active council debate or voice synthesis run.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    @Published private(set) var isAvailable: Bool = false
    @Published private(set) var canCheckNow: Bool = false
    @Published private(set) var automaticallyChecks: Bool = false
    @Published private(set) var automaticallyDownloads: Bool = false
    @Published private(set) var statusText: String = "Automatic updates are active in signed Release builds."

    private var controller: SPUStandardUpdaterController?
    private weak var appModel: AppModel?
    private var cancellables = Set<AnyCancellable>()

    func start(appModel: AppModel) {
        self.appModel = appModel
        #if DEBUG
        statusText = "Dev build (Cosign Dev) — Sparkle release feed disabled in Debug."
        return
        #else
        guard controller == nil,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty,
              let pubKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !pubKey.isEmpty else {
            statusText = "Sparkle update keys not configured in Info.plist."
            return
        }
        let ctrl = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = ctrl
        let updater = ctrl.updater

        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] _ in self?.refreshState() }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] _ in self?.refreshState() }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] _ in self?.refreshState() }
            .store(in: &cancellables)

        ctrl.startUpdater()
        isAvailable = true
        refreshState()
        #endif
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        refreshState()
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        refreshState()
    }

    private var isBusyWithDebateOrAudio: Bool {
        guard let appModel else { return false }
        let debateBusy = appModel.currentSession?.stage.isBusy == true
        let audioBusy = appModel.voiceEngine.isPlaying
        return debateBusy || audioBusy
    }

    private func refreshState() {
        guard let updater = controller?.updater else { return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        canCheckNow = updater.canCheckForUpdates && !isBusyWithDebateOrAudio
        statusText = isBusyWithDebateOrAudio
            ? "Updates pause while a council session is speaking or debating."
            : "Signed updates install automatically via GitHub Releases."
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        MainActor.assumeIsolated {
            !isBusyWithDebateOrAudio
        }
    }
}
