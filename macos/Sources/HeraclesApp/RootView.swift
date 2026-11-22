import HeraclesCore
import SwiftUI

/// One window: the sidebar, and the note chosen in it. Every window shares
/// the same model, so what one changes the others show.
public struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var searchText = ""

    /// `selecting` is the note the window opens on, if any.
    public init(selecting noteID: String? = nil) {
        _selection = State(initialValue: noteID)
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $selection, searchText: searchText)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes")
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
                .toolbar {
                    ToolbarItem {
                        Menu("New", systemImage: "plus") {
                            Button("Page") { create(.page) }
                            Button("Section") { create(.section) }
                            Button("To-Do List") { create(.todoList) }
                            Divider()
                            Button("Notebook") { create(.notebook) }
                        }
                    }
                }
        } detail: {
            if let note = selection.flatMap({ model.library.note($0) }) {
                NoteDetailView(note: note)
            } else {
                ContentUnavailableView(
                    "No Note Selected", systemImage: "doc.text",
                    description: Text("Choose a note in the sidebar, or create one with the + button."))
            }
        }
        .navigationTitle(selection.flatMap { model.library.note($0)?.displayTitle } ?? "Heracles")
        .onOpenURL { url in
            if let link = AppLink(url) { model.pendingLink = link }
        }
        .onChange(of: model.pendingLink, initial: true) {
            // A link opens in whichever window sees it first.
            if let link = model.pendingLink, model.library.note(link.noteID) != nil {
                selection = link.noteID
                model.pendingLink = nil
            }
        }
        .onChange(of: model.library) {
            // The selected note may have been deleted, here or in another window.
            if let selected = selection, model.library.note(selected) == nil {
                selection = nil
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { _ in model.lastError = nil })) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    /// New notes go inside the selected note if it can hold them, otherwise
    /// beside it, otherwise in the first notebook.
    private func create(_ kind: NoteKind) {
        let selected = selection.flatMap { model.library.note($0) }
        let parent: String? =
            switch selected?.kind {
            case .section, .page, .notebook: selected?.id
            case .todoList: selected?.parentId
            case nil: nil
            }
        if let note = model.createNote(kind, in: parent) {
            selection = note.id
        }
    }
}
