import HeraclesCore
import SwiftUI

extension FocusedValues {
    /// The workspace of the window in front, for the menu bar to act on.
    @Entry var workspace: Workspace?
}

/// The menu bar. Every item acts on the window in front.
struct HeraclesCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Page") { workspace?.createNote(.page) }
                .keyboardShortcut("n")
            Button("New Section") { workspace?.createNote(.section) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New To-Do List") { workspace?.createNote(.todoList) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Notebook") { workspace?.createNote(.notebook) }
            Divider()
            Button("Quick Open…") { workspace?.isSwitcherShown = true }
                .keyboardShortcut("k")
            Divider()
            Button("Close Tab") { workspace?.closeActiveTab() }
                .keyboardShortcut("w")
        }
        CommandGroup(replacing: .importExport) {
            Button("Import…") { workspace?.chooseFilesToImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export as Markdown…") { workspace?.chooseExportDestination() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace?.activeNote == nil)
        }
        CommandMenu("Note") {
            Group {
                Button(workspace?.activeNote?.favorited == true ? "Remove from Favorites" : "Add to Favorites") {
                    workspace?.toggleFavoriteActive()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Duplicate") { workspace?.duplicateActive() }
                    .keyboardShortcut("d")
                Button("Copy Link") { workspace?.copyLinkToActive() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                // No shortcut: ⌘⌫ is "delete to the start of the line" while typing.
                Button("Move to Trash") { workspace?.trashActive() }
            }
            .disabled(workspace?.activeNote == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Split Right") { workspace?.splitFocused(.right) }
                .keyboardShortcut("\\")
            Button("Split Down") { workspace?.splitFocused(.down) }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Divider()
        }
    }
}
