import AppKit
import Observation
import Sparkle

/// Updates from GitHub Releases, through Sparkle: it downloads the new version, checks its EdDSA
/// signature against `SUPublicEDKey`, and replaces the app. The feed and every archive are assets
/// of the releases themselves — see `SUFeedURL` in Info.plist and release.sh.
///
/// Wrapped rather than used bare because two of Sparkle's facts are needed as observable state:
/// whether a check can start now (not while one is running) and when the last one finished. Both
/// are KVO properties on `SPUUpdater`, which SwiftUI cannot observe directly.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// False while a check is in flight, so Check for Updates disables itself.
    private(set) var canCheck = false
    /// When the last check finished, or nil if none has. Shown in Settings because it is the only
    /// way to tell "up to date" from "quietly not checking".
    private(set) var lastCheck: Date?

    /// nil in a build with no feed (every `build.sh` build), where the rest of this class is inert.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// Answers Sparkle's "which channels?" before each check. Held here because Sparkle keeps only
    /// a weak reference to its delegate.
    @ObservationIgnored private let channels = UpdateChannels()
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    /// Sparkle's own preferences, written straight through: it reads its keys when it schedules a
    /// check, so a copy kept anywhere else would be a second answer the timer ignores.
    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Opt in to the beta channel. Off by default: betas come first and are less proven.
    var receivesBetas: Bool {
        get {
            access(keyPath: \.receivesBetas)
            return UpdateChannels.receivesBetas
        }
        set {
            withMutation(keyPath: \.receivesBetas) {
                UpdateChannels.receivesBetas = newValue
            }
            // A beta waiting in the feed should not have to wait for tomorrow's check.
            if newValue { controller?.updater.resetUpdateCycleAfterShortDelay() }
        }
    }

    var automaticallyDownloads: Bool {
        get {
            access(keyPath: \.automaticallyDownloads)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyDownloads) {
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    private init() {
        guard Self.isConfigured else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: channels, userDriverDelegate: nil)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        observers = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
            },
        ]
    }

    /// The explicit check, from the app menu or Settings. Unlike the scheduled one, it reports
    /// "you're up to date" — a background check that finds nothing stays silent.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// Whether this build can update itself: a release carries both a feed and a public key.
    /// `build.sh` strips the feed from local builds, so a development copy never replaces itself.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }
}

/// Which of the feed's channels this copy accepts. Stable releases carry no channel and reach
/// everyone; betas carry "beta" and are offered only when the user has opted in.
///
/// The preference lives in `UserDefaults` rather than on the main-actor `Updater` because Sparkle
/// asks from its own thread, and `UserDefaults` is safe to read from any.
final class UpdateChannels: NSObject, SPUUpdaterDelegate {
    private static let betaKey = "ReceiveBetaUpdates"

    static var receivesBetas: Bool {
        get { UserDefaults.standard.bool(forKey: betaKey) }
        set { UserDefaults.standard.set(newValue, forKey: betaKey) }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.receivesBetas ? ["beta"] : []
    }
}
