import AppKit
import Foundation
import HeraclesCore
import Testing

@testable import HeraclesApp

/// The app's end of an editor, against a real core in a throwaway folder
/// and with the editor's real views in a window that is never shown.
@MainActor
struct EditorCoordinatorTests {
    let store: Store
    let model: AppModel

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heracles-coordinator-tests-\(UUID().uuidString)")
        store = try Store(dataDir: directory.path)
        model = try AppModel(store: store)
    }

    private func shown(_ content: String) throws -> (EditorCoordinator, NSWindow) {
        let page = try store.createNote(new: NewNote(title: "Page", content: content))
        let coordinator = EditorCoordinator(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = coordinator.editor.scrollView
        coordinator.show(noteID: page.id, editable: true, change: nil)
        window.layoutIfNeeded()
        return (coordinator, window)
    }

    @Test func leavingTheTitleForTheNotePutsTheCaretAtItsStart() async throws {
        let (coordinator, window) = try shown(
            #"{"type":"doc","content":[{"type":"paragraph","attrs":{"blockId":"p1"},"content":[{"type":"text","text":"First"}]}]}"#)
        defer { window.close() }
        // As the view does when it is made, and then when the title is left.
        coordinator.focusStart(request: 0)

        coordinator.focusStart(request: 1)
        try await Task.sleep(for: .milliseconds(60))

        #expect(coordinator.editor.selection == .caret("p1", 0))
        #expect(window.firstResponder === coordinator.editor.page.textView(for: "p1"))
    }

    @Test func aRequestAlreadyAnsweredDoesNotMoveTheCaretAgain() async throws {
        let (coordinator, window) = try shown(
            #"{"type":"doc","content":[{"type":"paragraph","attrs":{"blockId":"p1"},"content":[{"type":"text","text":"First"}]}]}"#)
        defer { window.close() }
        coordinator.focusStart(request: 0)
        coordinator.focusStart(request: 1)
        try await Task.sleep(for: .milliseconds(60))
        coordinator.editor.select(.caret("p1", 3))

        // The view is drawn again with the same request, as it is at every change.
        coordinator.focusStart(request: 1)
        try await Task.sleep(for: .milliseconds(60))

        #expect(coordinator.editor.selection == .caret("p1", 3))
    }

    @Test func anEditorMadeAfterTheTitleWasLeftDoesNotTakeTheKeyboard() async throws {
        let (coordinator, window) = try shown(
            #"{"type":"doc","content":[{"type":"paragraph","attrs":{"blockId":"p1"},"content":[{"type":"text","text":"First"}]}]}"#)
        defer { window.close() }

        // The pane's title was left for the note three times before this
        // editor existed: a board was showing, and now a page is again.
        coordinator.focusStart(request: 3)
        try await Task.sleep(for: .milliseconds(60))

        #expect(coordinator.editor.selection == .none)
    }

    @Test func anEditorNobodyAskedToTakeTheKeyboardDoesNotTakeIt() async throws {
        let (coordinator, window) = try shown(
            #"{"type":"doc","content":[{"type":"paragraph","attrs":{"blockId":"p1"},"content":[{"type":"text","text":"First"}]}]}"#)
        defer { window.close() }

        coordinator.focusStart(request: 0)
        try await Task.sleep(for: .milliseconds(60))

        #expect(coordinator.editor.selection == .none)
    }
}
