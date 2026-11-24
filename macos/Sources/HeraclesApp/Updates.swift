import AppKit
import Observation
import Sparkle
import SwiftUI

/// Whether this run looks for updates, and where.
enum UpdatePolicy: Equatable {
    case off
    /// `feed` is nil for the address in the Info.plist.
    case on(feed: String?)

    /// - Parameters:
    ///   - arguments: the command line.
    ///   - environment: the process's environment.
    ///   - info: the bundle's Info.plist.
    static func decide(arguments: [String], environment: [String: String], info: [String: Any]) -> UpdatePolicy {
        // The self-test and the snapshot use a throwaway library and exit.
        if arguments.contains("--self-test") || arguments.contains("--snapshot") { return .off }
        // A bundle made without the feed address and the key has nothing to
        // check against: `swift run` starts a bare executable, for one.
        guard info["SUFeedURL"] is String, info["SUPublicEDKey"] is String else { return .off }
        // A run against a library named in the environment is a trial or a
        // test. It must not find the published app and offer to replace
        // itself with it. The update rehearsal names a feed of its own
        // instead; the everyday app takes no feed from the command line.
        if let trial = environment["HERACLES_DATA_DIR"], !trial.isEmpty {
            guard let flag = arguments.firstIndex(of: "--updater-feed"), flag + 1 < arguments.count else { return .off }
            return .on(feed: arguments[flag + 1])
        }
        return .on(feed: nil)
    }
}

/// Over-the-air updates, through Sparkle.
///
/// Once a day, and when asked from the menu, the app reads a feed
/// (`SUFeedURL` in the Info.plist: a file attached to the newest GitHub
/// release). What it finds there is offered with its release notes and
/// installed when the user agrees. Installing quits the app the way Quit
/// does, so every editor saves first.
///
/// Nothing is taken on the feed's word. The feed and the archive both have
/// to carry a signature made with the update key whose public half is in
/// the Info.plist (`SUPublicEDKey`, `SURequireSignedFeed`,
/// `SUVerifyUpdateBeforeExtraction`), so whoever controls the place the
/// files are served from can withhold an update but not supply one.
/// Sparkle keeps two provisions for a developer who lost that key;
/// BUILDING.md says where they are written up.
///
/// The release notes in the feed are Markdown, which Sparkle draws in a
/// text view. HTML notes would bring up a web view, and the app has none.
@MainActor
@Observable
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    /// Whether this run looks for updates at all.
    private(set) var isActive = false
    /// False while a check is under way, and in a run that does not look.
    private(set) var canCheckForUpdates = false
    private var automatic = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// A feed named on the command line, for the update rehearsal.
    @ObservationIgnored private var rehearsalFeed: String?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Starts the updater, unless this run has no business looking for
    /// updates. See `UpdatePolicy`.
    func start() {
        guard controller == nil else { return }
        let policy = UpdatePolicy.decide(
            arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment,
            info: Bundle.main.infoDictionary ?? [:])
        guard case .on(let feed) = policy else { return }
        rehearsalFeed = feed
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        isActive = true
        // Sparkle changes both of these itself, so the menu follows them.
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.automatic = value }
            },
        ]
    }

    /// The daily check. On unless the user switches it off.
    var checksAutomatically: Bool {
        get { automatic }
        set {
            guard let controller else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            automatic = newValue
        }
    }

    /// Heracles ▸ Check for Updates…: looks now and says what it found.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Looks now the way the daily check does: nothing is shown unless
    /// there is an update (`--demo-update`).
    func checkInBackground() {
        controller?.updater.checkForUpdatesInBackground()
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        rehearsalFeed
    }

    // The rest only writes down what happened, one `updates:` line each.
    // The rehearsal reads them, and so can anyone looking at Console.

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.log("found \(item.displayVersionString) (\(item.versionString))")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Self.log("downloaded \(item.displayVersionString)")
    }

    // (Sparkle's "did extract" callback is not logged: it arrives as soon
    // as the archive is handed to the installer, before the signature has
    // been checked or anything unpacked.)

    /// The archive's signature held, it was unpacked and what came out was
    /// checked: all that is left is to swap the bundles once the app is
    /// gone.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Self.log("\(item.displayVersionString) is verified and will be installed when the app quits")
        return false
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.log("installing \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.log("stopped: could not download \(item.displayVersionString): \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) {
            Self.log("nothing newer in the feed")
        } else {
            Self.log("stopped: \(error.localizedDescription) (\(error.domain) \(error.code))")
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        Self.log("done")
    }

    /// One line in the system log and on standard error.
    static func log(_ line: String) {
        NSLog("%@", "updates: \(line)")
    }
}

/// Heracles ▸ Check for Updates… and Check for Updates Automatically.
/// Views, so that the items follow the updater's state.
struct UpdateMenuItems: View {
    var body: some View {
        let updates = Updates.shared
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
        Toggle(
            "Check for Updates Automatically",
            isOn: Binding(get: { updates.checksAutomatically }, set: { updates.checksAutomatically = $0 })
        )
        .disabled(!updates.isActive)
    }
}
