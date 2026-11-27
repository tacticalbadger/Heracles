import AppKit
import HeraclesApp

if CommandLine.arguments.contains("--self-test") {
    // Drives the editor in a window against a throwaway library, then exits
    // 0 if every check passed. See SelfTest.swift.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        let passed = await SelfTest.run()
        exit(passed ? 0 : 1)
    }
    app.run()
} else if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
    // Draws the app's own windows, filled with sample notes, into PNG files
    // in the given folder. See Snapshot.swift.
    let folder = CommandLine.arguments[flag + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        exit(await Snapshot.write(to: folder) ? 0 : 1)
    }
    app.run()
} else if CommandLine.arguments.contains(WindowCheck.argument),
    let refusal = WindowCheck.refusal(
        environment: ProcessInfo.processInfo.environment, bundleIdentifier: Bundle.main.bundleIdentifier)
{
    // Checks the running app's menus and windows. Refused before the app
    // starts, so nothing of the user's is opened. See WindowCheck.swift.
    FileHandle.standardError.write(Data("\(refusal)\n".utf8))
    exit(2)
} else {
    HeraclesApp.main()
}
