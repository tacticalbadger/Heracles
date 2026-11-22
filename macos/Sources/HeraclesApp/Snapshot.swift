import AppKit
import HeraclesCore
import SwiftUI

/// Draws the app's window into image files, using a throwaway library of
/// sample notes. A way to look at the interface without a screen recording,
/// and without anything else on the screen ending up in the picture.
/// Run with `Heracles --snapshot <folder>`.
///
/// The web editor draws in its own process and is left blank in these
/// pictures. `--self-test` is what checks the editor.
@MainActor
public enum Snapshot {
    public static func write(to folder: String) async -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heracles-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try Store(dataDir: directory.path)
            let model = try AppModel(store: store)
            let (page, list) = try fill(store)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let file = { (name: String) in URL(fileURLWithPath: folder).appendingPathComponent("\(name).png") }
            for (name, selected) in [("page", page), ("board", list)] {
                try await draw(RootView(model: model, selecting: selected), to: file(name))
            }
            // A todo list's first card, as the sheet that opens on it.
            if let card = try store.listTasks(todoListId: list).first(where: { $0.parentTaskId == nil }) {
                try await draw(TaskDetailView(todoListID: list, rootTaskID: card.id).environment(model), to: file("task"))
            }
            // Two panes side by side, and the quick switcher over them.
            let workspace = Workspace(model: model)
            workspace.open(page)
            workspace.open(list, inSplit: .right)
            try await draw(
                PaneNodeView(node: workspace.tree.root, workspace: workspace).environment(model).frame(width: 1100, height: 700),
                to: file("split"))
            try await draw(SwitcherView(workspace: workspace).padding(40), to: file("switcher"))
            return true
        } catch {
            print("Snapshot failed: \(error)")
            return false
        }
    }

    /// A small library with one of everything. Returns a page and a todo list.
    private static func fill(_ store: Store) throws -> (page: String, list: String) {
        let notebook = try store.listNotes()[0]
        _ = try store.renameNote(id: notebook.id, title: "Personal")
        let section = try store.createNote(new: NewNote(kind: .section, parentId: notebook.id, title: "Travel"))
        let page = try store.createNote(new: NewNote(parentId: section.id, title: "Trip plan", icon: "🧭"))
        _ = try store.createNote(new: NewNote(parentId: page.id, title: "Packing list"))
        _ = try store.createNote(new: NewNote(parentId: section.id, title: "Ferry times"))
        _ = try store.setNoteFavorited(id: page.id, favorited: true)
        let archived = try store.createNote(new: NewNote(parentId: notebook.id, title: "Last year"))
        _ = try store.setNoteArchived(id: archived.id, archived: true)
        let trashed = try store.createNote(new: NewNote(parentId: notebook.id, title: "Old draft"))
        _ = try store.trashNote(id: trashed.id)
        _ = try store.createNote(new: NewNote(kind: .notebook, title: "Work"))

        let list = try store.createNote(new: NewNote(kind: .todoList, parentId: section.id, title: "Before we leave"))
        let columns = try store.listColumns(todoListId: list.id)
        let ferry = try store.createTask(new: NewTask(todoListId: list.id, columnId: columns[0].id, title: "Book the ferry"))
        _ = try store.updateTask(
            id: ferry.id,
            patch: TaskPatch(
                description: "Check the winter timetable first.",
                dueDate: .some("2026-12-01T14:00:00.000Z"), priority: 1, labels: ["travel", "tickets"],
                reminders: ["2026-11-30T09:00:00.000Z"], location: .some("Harbour office")))
        _ = try store.createComment(taskId: ferry.id, body: "The 9:40 sailing is the one with space for the car.")
        for (title, done) in [("Outbound", true), ("Return", false)] {
            let sub = try store.createTask(new: NewTask(todoListId: list.id, parentTaskId: ferry.id, title: title))
            _ = try store.updateTask(id: sub.id, patch: TaskPatch(completed: done))
        }
        _ = try store.createTask(new: NewTask(todoListId: list.id, columnId: columns[0].id, title: "Water the plants"))
        _ = try store.createTask(new: NewTask(todoListId: list.id, columnId: columns[1].id, title: "Pack the lantern"))
        let done = try store.createTask(new: NewTask(todoListId: list.id, columnId: columns[2].id, title: "Renew passport"))
        _ = try store.updateTask(id: done.id, patch: TaskPatch(completed: true))
        return (page.id, list.id)
    }

    private static func draw(_ view: some View, to file: URL) async throws {
        defer { print("Wrote \(file.path)") }
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        // Swift owns the window. AppKit must not also release it on close.
        window.isReleasedWhenClosed = false
        // An offscreen drawing has no window behind it, so paint one in.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        // Laid out as a real window, placed where no screen shows it.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        try await Task.sleep(for: .seconds(2))

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: file)
        window.close()
    }
}
