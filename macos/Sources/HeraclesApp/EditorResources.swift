import Foundation
import HeraclesCore
import WebKit

/// Serves the web view the only two things it may load: the editor's own
/// files from the app bundle, and images from the core's image store.
///
/// Giving the editor a scheme of its own, in place of `file:` URLs, gives its
/// page a real origin. The page's content security policy can then say
/// "only my own files", and no other local file is reachable from it.
@MainActor
final class EditorResources: NSObject, WKURLSchemeHandler {
    private let store: Store
    private let editorFolder: URL?

    init(store: Store) {
        self.store = store
        editorFolder = Bundle.module.url(forResource: "editor", withExtension: nil)
    }

    /// The web view configuration schemes this handler answers for.
    var schemes: [String] { [NavigationPolicy.appScheme, imageUrlScheme()] }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (data, type) = resource(at: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": type,
            "Content-Length": String(data.count),
            // An image's URL is the hash of its bytes, so it never changes.
            "Cache-Control": url.scheme == imageUrlScheme() ? "max-age=31536000, immutable" : "no-cache",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    func resource(at url: URL) -> (Data, String)? {
        if url.scheme == imageUrlScheme() {
            guard let image = try? store.getImage(hashOrUrl: url.absoluteString),
                let path = try? store.imagePath(hashOrUrl: image.hash),
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else { return nil }
            return (data, image.mime)
        }
        guard NavigationPolicy.decide(url) == .allow, let editorFolder else { return nil }
        let file = editorFolder.appendingPathComponent(url.path).standardizedFileURL
        // `..` in a request must not reach outside the editor's folder.
        guard file.path.hasPrefix(editorFolder.standardizedFileURL.path + "/"),
            let data = try? Data(contentsOf: file)
        else { return nil }
        return (data, Self.contentType(forExtension: file.pathExtension))
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        default: "application/octet-stream"
        }
    }
}
