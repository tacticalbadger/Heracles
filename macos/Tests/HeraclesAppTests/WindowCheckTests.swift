import Testing

@testable import HeraclesApp

/// When the app agrees to check its own windows. The check adds notes and
/// opens and closes windows, so it must never run as the everyday app.
@MainActor
struct WindowCheckTests {
    private let copy = "com.heracles.notes.native.windowcheck"

    @Test func aCopyWithALibraryOfItsOwnMayBeChecked() {
        #expect(WindowCheck.refusal(environment: ["HERACLES_DATA_DIR": "/tmp/check"], bundleIdentifier: copy) == nil)
    }

    @Test func theUsersLibraryIsNeverChecked() {
        #expect(WindowCheck.refusal(environment: [:], bundleIdentifier: copy) != nil)
        #expect(WindowCheck.refusal(environment: ["HERACLES_DATA_DIR": ""], bundleIdentifier: copy) != nil)
    }

    @Test func theEverydayAppIsNeverCheckedEvenOnAnotherLibrary() {
        let trial = ["HERACLES_DATA_DIR": "/tmp/check"]
        #expect(WindowCheck.refusal(environment: trial, bundleIdentifier: "com.heracles.notes.native") != nil)
        #expect(WindowCheck.refusal(environment: trial, bundleIdentifier: "com.heracles.notes.native.") != nil)
        #expect(WindowCheck.refusal(environment: trial, bundleIdentifier: "com.heracles.notes.nativeish") != nil)
        #expect(WindowCheck.refusal(environment: trial, bundleIdentifier: nil) != nil, "nor a bare executable")
    }
}
