import SwiftUI
import WebKit

/// The note editor: the web editor in a web view, kept showing `noteID`.
struct EditorWebView: NSViewRepresentable {
    let noteID: String
    let editable: Bool
    /// The latest save of this note. Passed in so that SwiftUI calls
    /// `updateNSView` when another window saves it.
    let change: DocumentChange?
    let model: AppModel

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(noteID: noteID, editable: editable, change: change)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: EditorCoordinator) {
        // The window is closing, or another kind of note took the editor's
        // place. Collect what the editor has not sent yet. The task keeps the
        // coordinator, and with it the web view, alive until that is done.
        Task { await coordinator.flush() }
    }
}
