import AppKit
import HeraclesCore
import SwiftUI

/// Where the library lives. The original app used the same folder, so its
/// database is found beside the new one on first launch.
public enum DataDirectory {
    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment["HERACLES_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Heracles", isDirectory: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `HeraclesApp` once the library is open.
    static var model: AppModel?
    private var reminders: ReminderScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from a bare executable, as `swift run` does, the process is not
        // a regular app until it says so.
        NSApp.setActivationPolicy(.regular)
        // The update rehearsal starts copies of the app one after another
        // and leaves them behind whatever is being worked in.
        let rehearsal = CommandLine.arguments.contains("--demo-update")
        // The window check (macos/window-check.sh) is a copy too. main.swift
        // has already refused it anywhere else.
        let windowCheck = CommandLine.arguments.contains(WindowCheck.argument)
        if !rehearsal, !windowCheck { NSApp.activate(ignoringOtherApps: true) }

        // Reminders are scheduled with the system, so they arrive whether or
        // not the app is running, and rescheduled whenever tasks change.
        // A run on a library of its own leaves the system's reminders alone.
        if ReminderPolicy.schedules(environment: ProcessInfo.processInfo.environment),
            let model = Self.model, let scheduler = ReminderScheduler(model: model)
        {
            reminders = scheduler
            model.afterChange = { [weak scheduler] in scheduler?.syncSoon() }
            scheduler.syncSoon()
        }

        // Over-the-air updates. Not every run looks: see `UpdatePolicy`.
        Updates.shared.start()
        if windowCheck, let model = Self.model {
            Task { @MainActor in
                let passed = await WindowCheck.run(model)
                exit(passed ? 0 : 1)
            }
        }
        // For the update rehearsal (macos/update-rehearsal.sh): look two
        // seconds after launch and not at the next scheduled time, and say
        // whether this run looks at all. Four seconds on, when a look at a
        // feed on this Mac is long over, say how the menu's two items for
        // updates stand.
        if rehearsal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Updates.log("looking for an update (active: \(Updates.shared.isActive))")
                Updates.shared.checkInBackground()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Updates.log("menu: \(UpdateMenuItems.stateInMenu())")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        // A title, or a field of a task, is handed over when the keyboard
        // leaves it. Quitting takes the keyboard away first, so what is
        // still being typed there is kept too.
        for window in sender.windows { window.makeFirstResponder(nil) }
        // Quitting waits for every editor to hand over what it is holding.
        Task {
            // A moment for the fields to notice that the keyboard has gone.
            try? await Task.sleep(for: .milliseconds(50))
            await model.flushEditors()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

public struct HeraclesApp: App {
    /// The windows on the library. Named so that the menu can open another.
    static let mainWindowID = "main"
    /// The windows that each show one task.
    static let taskWindowID = "task"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var importReport: ImportReport?

    public init() {
        do {
            let directory = DataDirectory.url
            let model = try AppModel(store: Store(dataDir: directory.path))
            let report = model.importLegacyLibraryIfNeeded(from: AppModel.legacyDatabase(in: directory))
            AppDelegate.model = model
            _model = State(initialValue: model)
            _importReport = State(initialValue: report)
        } catch {
            _startupError = State(initialValue: AppModel.words(for: error))
        }
    }

    public var body: some Scene {
        WindowGroup("Heracles", id: Self.mainWindowID) {
            if let model {
                RootView(model: model)
                    .sheet(item: $importReport) { report in
                        ImportSummaryView(report: report)
                    }
            } else {
                ContentUnavailableView(
                    "The library could not be opened", systemImage: "exclamationmark.triangle",
                    description: Text(startupError ?? ""))
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands { HeraclesCommands() }

        // A task opens in a window of its own, one for each task. It is not
        // modal: the board stays in reach, and several can be open.
        WindowGroup("Task", id: Self.taskWindowID, for: TaskWindowID.self) { $task in
            if let model, let task {
                TaskDetailView(todoListID: task.todoListID, rootTaskID: task.taskID)
                    .environment(model)
            }
        }
        .defaultSize(width: 560, height: 640)
    }
}

extension ImportReport: Identifiable {
    public var id: String { backupPath }
}

/// Shown once, after the original app's library has been brought across.
struct ImportSummaryView: View {
    let report: ImportReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your library has been imported").font(.title2.bold())
            Text(
                "\(report.notes) notes, \(report.tasks) tasks and \(report.images) images were brought across from the previous version of Heracles."
            )
            Text("The previous library was not changed. A copy of it was saved at:")
            Text(report.backupPath).font(.caption.monospaced()).textSelection(.enabled)
            if !report.repairs.isEmpty {
                Text("Some items needed adjusting to fit:").padding(.top, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.repairs, id: \.self) { line in
                            Text("• \(line)").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
