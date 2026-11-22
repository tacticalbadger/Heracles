import HeraclesCore
import SwiftUI

/// One note: its title, then its content. A todo list shows its board, and
/// every other kind shows the editor.
struct NoteDetailView: View {
    @Environment(AppModel.self) private var model
    let note: Note
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let icon = note.icon, !icon.isEmpty {
                    Text(icon).font(.largeTitle)
                }
                TextField("Untitled", text: $title)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
                    .focused($titleFocused)
                    .disabled(note.trashed)
                    .onSubmit(commitTitle)
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 4)

            if note.kind == .todoList {
                BoardView(todoList: note)
            } else {
                EditorWebView(
                    noteID: note.id, editable: !note.trashed,
                    change: model.documentChange(for: note.id), model: model)
            }
        }
        .onAppear { title = note.title }
        .onChange(of: note.id) { title = note.title }
        .onChange(of: note.title) { if !titleFocused { title = note.title } }
        .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
        .toolbar {
            ToolbarItemGroup {
                if note.trashed {
                    Button("Put Back", systemImage: "arrow.uturn.backward") { model.restore(note.id) }
                } else {
                    Button(
                        note.favorited ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: note.favorited ? "star.fill" : "star"
                    ) { model.setFavorited(note.id, !note.favorited) }
                    Button("Move to Trash", systemImage: "trash") { model.trash(note.id) }
                }
            }
        }
    }

    private func commitTitle() {
        if title != note.title {
            model.rename(note.id, to: title)
        }
    }
}
