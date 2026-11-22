import Foundation
import HeraclesCore

/// What to do when the editor's web view is asked to go somewhere.
public enum NavigationDecision: Equatable, Sendable {
    /// Part of the editor's own page.
    case allow
    /// A link to the outside world. The system opens it.
    case openExternally
    /// A link to a note. The app opens it.
    case openInApp
    case deny
}

/// The web view may only ever display the editor. Everything else either
/// leaves the app or is refused, so no other page can reach the bridge to
/// the user's notes.
public enum NavigationPolicy {
    public static let appScheme = "heracles-app"
    public static let editorHost = "editor"
    public static let editorURL = URL(string: "\(appScheme)://\(editorHost)/index.html")!

    public static func decide(_ url: URL?) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .deny }
        switch scheme {
        case appScheme:
            return url.host == editorHost ? .allow : .deny
        case "http", "https", "mailto":
            return .openExternally
        case AppLink.scheme:
            return AppLink(url) == nil ? .deny : .openInApp
        default:
            return .deny
        }
    }
}

/// A `heracles://note/<id>` link, optionally to one block of the note.
public struct AppLink: Equatable, Sendable {
    public static let scheme = "heracles"

    public var noteID: String
    public var blockID: String?

    public init(noteID: String, blockID: String?) {
        self.noteID = noteID
        self.blockID = blockID
    }

    public init?(_ url: URL) {
        let parts = url.pathComponents
        guard url.scheme?.lowercased() == Self.scheme, url.host == "note",
            parts.count == 2, parts[0] == "/", !parts[1].isEmpty
        else { return nil }
        noteID = parts[1]
        let block = url.fragment.flatMap { $0.hasPrefix("block=") ? String($0.dropFirst(6)) : nil }
        blockID = block.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "note"
        components.path = "/\(noteID)"
        components.fragment = blockID.map { "block=\($0)" }
        return components.url!
    }
}

/// A message the web editor posts to the app. See `renderer/editor-host/main.tsx`.
public enum EditorMessage: Equatable, Sendable {
    /// The editor has started and can be given a document.
    case ready
    /// The user changed the note. `content` is document JSON.
    case changed(noteID: String, content: String)
    /// The user ⌘-clicked a link.
    case openLink(href: String)
    /// The user pasted or dropped an image. The reply is its URL in the store.
    case storeImage(mime: String, base64: String)
    /// The user pasted rich text. The reply is document JSON.
    case convertHTML(html: String)
    /// The user chose "Copy link to block".
    case copyBlockLink(blockID: String)
    /// The editor took the keyboard focus.
    case focused

    public init?(body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
        let text = { (key: String) in body[key] as? String }
        switch type {
        case "ready":
            self = .ready
        case "changed":
            guard let noteID = text("noteId"), let content = text("content") else { return nil }
            self = .changed(noteID: noteID, content: content)
        case "openLink":
            guard let href = text("href") else { return nil }
            self = .openLink(href: href)
        case "storeImage":
            guard let mime = text("mime"), let base64 = text("base64") else { return nil }
            self = .storeImage(mime: mime, base64: base64)
        case "convertHtml":
            guard let html = text("html") else { return nil }
            self = .convertHTML(html: html)
        case "copyBlockLink":
            guard let blockID = text("blockId") else { return nil }
            self = .copyBlockLink(blockID: blockID)
        case "focused":
            self = .focused
        default:
            return nil
        }
    }
}
