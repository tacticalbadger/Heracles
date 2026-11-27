import AppKit
import Foundation
import HeraclesCore

/// A check of what only the running app has: its menu bar and its windows.
/// No unit test reaches those, and the self-test starts no app. Run by
/// `macos/window-check.sh`, which starts a copy of the build that has a
/// bundle identifier and a library of its own with `--window-check`.
///
/// The copy is the real app, so its windows are on the screen while this
/// runs. It does not take the keyboard, and it ends by itself.
@MainActor
public enum WindowCheck {
    public static let argument = "--window-check"

    /// Why this run must not be a window check, or `nil` if it may be one.
    /// The check adds notes and tasks, opens and closes windows, and ends
    /// without the app's ordinary quit. Run as the everyday app it would do
    /// all that to the user's library and to the windows the app remembers
    /// for them.
    public static func refusal(environment: [String: String], bundleIdentifier: String?) -> String? {
        if (environment["HERACLES_DATA_DIR"] ?? "").isEmpty {
            return "the window check needs a library of its own: set HERACLES_DATA_DIR to a throwaway folder"
        }
        guard let bundleIdentifier, bundleIdentifier.hasPrefix(ownIdentifier + "."), bundleIdentifier.count > ownIdentifier.count + 1
        else {
            return "the window check runs in a copy of the app with an identifier of its own: use macos/window-check.sh"
        }
        return nil
    }

    /// The everyday app's bundle identifier. A copy made for a check has
    /// one below it.
    static let ownIdentifier = "com.heracles.notes.native"

    static func run(_ model: AppModel) async -> Bool {
        var failures = 0
        func check(_ label: String, _ passed: Bool) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }

        // The first window is on its way up when the app has just started.
        let started = await waitUntil { !libraryWindows().isEmpty }
        check("the app opens a window on the library", started)
        check(
            "the check runs on a library of its own",
            DataDirectory.url.path == ProcessInfo.processInfo.environment["HERACLES_DATA_DIR"]
                && model.library.notebooks.count == 1 && model.library.notebooks[0].children.isEmpty)

        // The menu bar.
        let newWindow = menuItem("New Window", in: "File")
        check("File has New Window", newWindow != nil)
        check("Format has Divider", menuItem("Divider", in: "Format") != nil)
        check(
            "Format still has every other kind of block",
            ["Text", "Heading 1", "Bullet List", "Numbered List", "Task List", "Quote", "Callout", "Toggle", "Code Block"]
                .allSatisfy { menuItem($0, in: "Format") != nil })

        let before = libraryWindows().count
        if let (menu, item) = newWindow {
            menu.performActionForItem(at: menu.index(of: item))
        }
        let opened = await waitUntil { libraryWindows().count == before + 1 }
        check("New Window opens another window on the library", opened)

        // Tasks, each in a window of its own.
        do {
            let notebook = model.library.notebooks[0].note
            let list = try model.store.createNote(new: NewNote(kind: .todoList, parentId: notebook.id, title: "Trip"))
            let column = try require(model.store.listColumns(todoListId: list.id).first, "the new list has no column")
            let ferry = try model.store.createTask(new: NewTask(todoListId: list.id, columnId: column.id, title: "Book the ferry"))
            let tent = try model.store.createTask(new: NewTask(todoListId: list.id, columnId: column.id, title: "Air the tent"))
            let pegs = try model.store.createTask(new: NewTask(todoListId: list.id, parentTaskId: tent.id, title: "Count the pegs"))

            // As a click on a card asks for it.
            model.taskToShow = TaskWindowID(todoListID: list.id, taskID: ferry.id)
            let shown = await waitUntil { windows(titled: "Book the ferry").count == 1 }
            check("a card's task opens in a window of its own", shown)
            check(
                "the board stays in reach behind it: nothing is modal",
                NSApp.modalWindow == nil && libraryWindows().allSatisfy { $0.attachedSheet == nil })
            check("whoever asked was answered", model.taskToShow == nil)

            model.taskToShow = TaskWindowID(todoListID: list.id, taskID: ferry.id)
            await pause()
            check("asked for again, the task's window is still the only one for it", windows(titled: "Book the ferry").count == 1)

            model.taskToShow = TaskWindowID(todoListID: list.id, taskID: tent.id)
            let both = await waitUntil { windows(titled: "Air the tent").count == 1 }
            check("a second task has a window of its own beside the first", both && windows(titled: "Book the ferry").count == 1)

            _ = try model.store.updateTask(id: ferry.id, patch: TaskPatch(title: "Book the night ferry"))
            let renamed = await waitUntil { windows(titled: "Book the night ferry").count == 1 }
            check("a task's window is called what the task is called", renamed && windows(titled: "Book the ferry").isEmpty)

            _ = try model.store.deleteTask(id: ferry.id)
            let closed = await waitUntil { windows(titled: "Book the night ferry").isEmpty }
            check("deleting a task closes its window", closed)
            check("and leaves the other task's window open", windows(titled: "Air the tent").count == 1)

            // A subtask made a card: its own window can be asked for, since
            // it is a card like any other now.
            _ = try model.store.moveTask(id: pegs.id, columnId: column.id, parentTaskId: nil, beforeId: nil)
            model.taskToShow = TaskWindowID(todoListID: list.id, taskID: pegs.id)
            let promoted = await waitUntil { windows(titled: "Count the pegs").count == 1 }
            check("a subtask made a card opens as a task of its own", promoted)

            _ = try model.store.trashNote(id: list.id)
            let allClosed = await waitUntil { windows(titled: "Air the tent").isEmpty && windows(titled: "Count the pegs").isEmpty }
            check("sending a list to the trash closes its tasks' windows", allClosed)
            check("the windows on the library are still there", libraryWindows().count == before + 1)
            check("nothing went wrong along the way", model.lastError == nil)
        } catch {
            check("the check ran to completion (\(error))", false)
        }

        print(failures == 0 ? "\nWINDOW CHECK PASSED" : "\nWINDOW CHECK FAILED (\(failures))")
        return failures == 0
    }

    private struct Missing: Error, CustomStringConvertible {
        let description: String
    }

    private static func require<T>(_ value: T?, _ what: String = "a value the check needs is missing") throws -> T {
        guard let value else { throw Missing(description: what) }
        return value
    }

    /// Windows showing with this title. One that is a tab behind another
    /// counts: where the system prefers tabs, a new window arrives as one.
    private static func windows(titled title: String) -> [NSWindow] {
        NSApp.windows.filter { $0.title == title && ($0.isVisible || ($0.tabbedWindows?.count ?? 0) > 1) }
    }

    /// The windows on the library. With no note open one is called by the
    /// app's name, and the check opens no note.
    private static func libraryWindows() -> [NSWindow] { windows(titled: "Heracles") }

    /// A menu's item as the menu bar has it now.
    private static func menuItem(_ title: String, in menuTitle: String) -> (NSMenu, NSMenuItem)? {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == menuTitle })?.submenu else { return nil }
        // The items are filled in when the menu is about to open.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        return menu.items.first { $0.title == title }.map { (menu, $0) }
    }

    private static func pause() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    private static func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
