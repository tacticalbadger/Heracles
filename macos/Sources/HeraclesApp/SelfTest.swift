import AppKit
import Foundation
import HeraclesCore

/// An end-to-end check of the parts no unit test reaches: the bundled web
/// editor running in a web view, loading a document from the core and saving
/// an edit back to it. Run with `Heracles --self-test`.
@MainActor
public enum SelfTest {
    public static func run() async -> Bool {
        var failures = 0
        func check(_ label: String, _ passed: Bool) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heracles-self-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = try Store(dataDir: directory.path)
            let model = try AppModel(store: store)
            let image = try store.storeImage(bytes: Data([0x89, 0x50, 0x4E, 0x47]), mime: "image/png")
            let original = """
                {"type":"doc","content":[
                  {"type":"heading","attrs":{"blockId":"h1","level":1},"content":[{"type":"text","text":"Trip plan"}]},
                  {"type":"paragraph","attrs":{"blockId":"p1"},"content":[
                    {"type":"text","text":"Pack the "},{"type":"text","text":"lantern","marks":[{"type":"bold"}]}]},
                  {"type":"taskList","content":[{"type":"taskItem","attrs":{"blockId":"t1","checked":true},
                    "content":[{"type":"paragraph","attrs":{"blockId":"p2"},"content":[{"type":"text","text":"Book ferry"}]}]}]},
                  {"type":"codeMirrorBlock","attrs":{"blockId":"c1","language":"rust","code":"fn main() {}"}},
                  {"type":"calloutBlock","attrs":{"blockId":"k1","emoji":"🔥"},
                    "content":[{"type":"paragraph","attrs":{"blockId":"p3"},"content":[{"type":"text","text":"Hot"}]}]},
                  {"type":"image","attrs":{"blockId":"i1","src":"\(image.url)","alt":"Map","title":null}}
                ]}
                """
            let page = try store.createNote(new: NewNote(title: "Self-test", content: original))

            let editor = EditorCoordinator(model: model)
            // A web view runs its page at full speed only inside a window.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor.webView
            // Placed where no screen shows it.
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            editor.show(noteID: page.id, editable: true, change: nil)

            let loaded = await waitUntil { editor.hasLoadedDocument }
            check("the bundled editor starts and asks for its document", loaded)

            // What the editor holds must be the document the core stored: same
            // blocks, same ids, nothing dropped by the editor's schema.
            let shown = try await editor.evaluate("return window.heraclesEditor.content()") as? String ?? ""
            check("the editor shows the stored document unchanged", sameJSON(shown, try store.getDocument(noteId: page.id)?.content ?? ""))

            let imageLoaded = await waitUntil {
                (try? await editor.evaluate(
                    "const i = document.querySelector('img.editor-image'); return !!i && i.complete && i.naturalWidth >= 0 && i.src === src",
                    arguments: ["src": image.url])) as? Bool == true
            }
            check("an image block points at the image store", imageLoaded)

            // Opening a note is not an edit: nothing may have been saved yet.
            let opened = try store.getDocument(noteId: page.id)?.revision ?? -1
            check("opening a note saves nothing", opened == 1 && model.documentChange(for: page.id) == nil)

            _ = try await editor.evaluate("window.heraclesEditor.insertText(' typed-by-self-test')")
            await editor.flush()
            let saved = await waitUntil { (try? store.getDocument(noteId: page.id))??.revision == opened + 1 }
            check("an edit in the editor is saved to the core", saved)

            let content = try store.getDocument(noteId: page.id)?.content ?? ""
            check("the saved document holds the typed text", content.contains("typed-by-self-test"))
            check("the saved document kept its block ids", content.contains("\"blockId\":\"c1\"") && content.contains("\"blockId\":\"h1\""))
            check("the edit is searchable", try store.searchNotes(query: "typed", limit: 5).map(\.note.id) == [page.id])
            check(
                "the editor's own save is attributed to it",
                model.documentChange(for: page.id) == DocumentChange(revision: opened + 1, origin: editor.editorID))

            // A save from elsewhere must replace what the editor shows.
            let replacement = #"{"type":"doc","content":[{"type":"paragraph","attrs":{"blockId":"r1"},"content":[{"type":"text","text":"Replaced elsewhere"}]}]}"#
            _ = try store.saveDocument(noteId: page.id, content: replacement, origin: "another-window")
            editor.show(noteID: page.id, editable: true, change: model.documentChange(for: page.id))
            let replaced = await waitUntil {
                ((try? await editor.evaluate("return window.heraclesEditor.content()")) as? String)?
                    .contains("Replaced elsewhere") == true
            }
            check("a save made elsewhere replaces what the editor shows", replaced)
            check("nothing went wrong along the way", model.lastError == nil)
        } catch {
            check("self-test ran to completion (\(error))", false)
        }

        print(failures == 0 ? "\nSELF-TEST PASSED" : "\nSELF-TEST FAILED (\(failures))")
        return failures == 0
    }

    private static func waitUntil(timeout: Duration = .seconds(15), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    private static func sameJSON(_ a: String, _ b: String) -> Bool {
        guard let first = try? JSONSerialization.jsonObject(with: Data(a.utf8)),
            let second = try? JSONSerialization.jsonObject(with: Data(b.utf8))
        else { return false }
        return (first as? NSDictionary)?.isEqual(second) == true
    }
}
