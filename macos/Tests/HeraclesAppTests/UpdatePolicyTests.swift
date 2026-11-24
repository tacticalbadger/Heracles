import Foundation
import Testing

@testable import HeraclesApp

/// Whether a run looks for updates, and where. A run that should not and
/// does would offer the published app to a trial copy or a test.
struct UpdatePolicyTests {
    /// What a bundle made by build-app.sh carries.
    private let ready: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"]
    private let trial = ["HERACLES_DATA_DIR": "/tmp/x"]

    private func decide(
        _ arguments: [String], _ environment: [String: String] = [:], info: [String: Any]? = nil
    ) -> UpdatePolicy {
        UpdatePolicy.decide(arguments: arguments, environment: environment, info: info ?? ready)
    }

    @Test func anEverydayRunLooksAtTheBuiltInFeed() {
        #expect(decide(["Heracles"]) == .on(feed: nil))
    }

    @Test func aBundleWithoutFeedOrKeyDoesNotLook() {
        #expect(decide(["Heracles"], info: [:]) == .off)
        #expect(decide(["Heracles"], info: ["SUPublicEDKey": "key"]) == .off)
        #expect(decide(["Heracles"], info: ["SUFeedURL": "https://example.com/appcast.xml"]) == .off)
    }

    @Test func aTrialLibraryDoesNotLook() {
        #expect(decide(["Heracles"], trial) == .off)
    }

    @Test func anEmptyDataDirIsAnEverydayRun() {
        #expect(decide(["Heracles"], ["HERACLES_DATA_DIR": ""]) == .on(feed: nil))
    }

    @Test func aRehearsalNamesItsOwnFeed() {
        #expect(
            decide(["Heracles", "--updater-feed", "http://127.0.0.1:1/a.xml"], trial)
                == .on(feed: "http://127.0.0.1:1/a.xml"))
    }

    @Test func anEverydayRunTakesNoFeedFromTheCommandLine() {
        #expect(decide(["Heracles", "--updater-feed", "http://evil.example/a.xml"]) == .on(feed: nil))
    }

    @Test func aFeedFlagWithoutAValueIsIgnored() {
        #expect(decide(["Heracles", "--updater-feed"], trial) == .off)
    }

    @Test func selfTestAndSnapshotRunsDoNotLook() {
        #expect(decide(["Heracles", "--self-test"]) == .off)
        #expect(decide(["Heracles", "--snapshot", "/tmp/s"]) == .off)
    }

    @Test func aRehearsalStillNeedsAKey() {
        #expect(
            decide(["Heracles", "--updater-feed", "http://127.0.0.1:1/a.xml"], trial, info: ["SUFeedURL": "x"]) == .off)
    }
}
