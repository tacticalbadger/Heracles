import AppKit
import Foundation
import HeraclesCore
import WebKit

/// The native end of one web editor. It owns the web view, gives it the
/// note to show, and saves what comes back.
///
/// The document lives in the core. The web view holds a working copy while a
/// note is open, and the copy is replaced whenever someone else saves that
/// note: another window, or another editor in this one.
@MainActor
final class EditorCoordinator: NSObject {
    let webView: WKWebView
    /// Passed with every save, and compared against the change feed, so this
    /// editor never reloads because of its own typing.
    let editorID = UUID().uuidString

    private let model: AppModel
    private let resources: EditorResources
    private var isReady = false
    private var wanted: (noteID: String, editable: Bool)?
    private var shown: (noteID: String, editable: Bool, revision: Int64)?
    private var revealed: String?
    /// Called when the editor takes the keyboard focus.
    var onFocus: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        resources = EditorResources(store: model.store)

        let configuration = WKWebViewConfiguration()
        for scheme in resources.schemes {
            configuration.setURLSchemeHandler(resources, forURLScheme: scheme)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // The content controller keeps its handler alive. A weak go-between
        // stops that from keeping this coordinator alive for ever.
        configuration.userContentController.addScriptMessageHandler(
            WeakMessageHandler(self), contentWorld: .page, name: "heracles")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: NavigationPolicy.editorURL))
        model.register(self)
    }

    /// Show a note, or catch up with a save someone else made to the one
    /// already showing.
    func show(noteID: String, editable: Bool, change: DocumentChange?) {
        wanted = (noteID, editable)
        guard isReady else { return }
        if let shown, shown.noteID == noteID, shown.editable == editable {
            let isNewer = (change?.revision ?? 0) > shown.revision
            guard isNewer, change?.origin != editorID else { return }
        }
        load()
    }

    private func load() {
        guard let wanted, let document = model.document(for: wanted.noteID) else { return }
        shown = (wanted.noteID, wanted.editable, document.revision)
        // Arguments are passed as values, never spliced into the script.
        webView.callAsyncJavaScript(
            "window.heraclesEditor.load({ noteId, content: JSON.parse(content), editable })",
            arguments: ["noteId": document.noteId, "content": document.content, "editable": wanted.editable],
            in: nil, in: .page, completionHandler: nil)
    }

    /// Bring a block into view. Once per block: asking again for the same
    /// one does nothing, so a view update cannot keep scrolling the page.
    func reveal(_ blockID: String?, then done: @escaping () -> Void) {
        guard let blockID, blockID != revealed, isReady, shown != nil else { return }
        revealed = blockID
        Task {
            // The document was handed over a moment ago. Give it time to draw.
            try? await Task.sleep(for: .milliseconds(150))
            _ = try? await webView.callAsyncJavaScript(
                "return window.heraclesEditor.scrollToBlock(blockId)", arguments: ["blockId": blockID],
                contentWorld: .page)
            done()
        }
    }

    /// Have the editor send any change it is holding back, and wait for it.
    func flush() async {
        guard isReady else { return }
        // The editor posts its change before this call returns its result,
        // and messages arrive in the order they were sent.
        _ = try? await webView.callAsyncJavaScript("window.heraclesEditor?.flush()", contentWorld: .page)
    }

    /// Run a script in the editor's page. For the self-test.
    func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    var hasLoadedDocument: Bool { shown != nil }

    fileprivate func receive(_ message: EditorMessage) -> Any? {
        switch message {
        case .ready:
            isReady = true
            load()
        case .changed(let noteID, let content):
            model.saveDocument(noteID, content: content, origin: editorID)
            if shown?.noteID == noteID, let revision = model.documentChange(for: noteID)?.revision {
                shown?.revision = revision
            }
        case .openLink(let href):
            follow(URL(string: href))
        case .storeImage(let mime, let base64):
            guard let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
            return model.attempt { try model.store.storeImage(bytes: bytes, mime: mime) }?.url
        case .convertHTML(let html):
            return htmlToDocument(html: html)
        case .copyBlockLink(let blockID):
            guard let noteID = shown?.noteID else { return nil }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                AppLink(noteID: noteID, blockID: blockID).url.absoluteString, forType: .string)
        case .focused:
            onFocus?()
        }
        return nil
    }

    private func follow(_ url: URL?) {
        guard let url else { return }
        switch NavigationPolicy.decide(url) {
        case .openExternally: NSWorkspace.shared.open(url)
        case .openInApp: model.pendingLink = AppLink(url)
        case .allow, .deny: break
        }
    }
}

extension EditorCoordinator: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard NavigationPolicy.decide(action.request.url) != .allow else { return .allow }
        // A click on a link, as opposed to something the page did by itself,
        // may leave for the browser. Nothing else may leave the editor.
        if action.navigationType == .linkActivated {
            follow(action.request.url)
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `target="_blank"` and `window.open` never get a window here.
        follow(action.request.url)
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page is gone. Start it again and it will ask for its document.
        isReady = false
        shown = nil
        webView.load(URLRequest(url: NavigationPolicy.editorURL))
    }
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var coordinator: EditorCoordinator?

    init(_ coordinator: EditorCoordinator) {
        self.coordinator = coordinator
    }

    @MainActor
    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        // Only the editor's own page may talk to the app.
        guard message.frameInfo.isMainFrame, NavigationPolicy.decide(message.frameInfo.request.url) == .allow,
            let parsed = EditorMessage(body: message.body)
        else { return (nil, nil) }
        return (coordinator?.receive(parsed), nil)
    }
}
