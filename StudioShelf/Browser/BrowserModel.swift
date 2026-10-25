import Foundation
import WebKit
import SwiftUI

/// One ordinary web download (a PDF, a movie file, a ZIP…) in progress or finished.
@MainActor
final class WebDownload: ObservableObject, Identifiable {
    enum State: Equatable { case running(Double), finished(path: String), failed(String), cancelled }
    let id = UUID()
    @Published var name: String
    @Published var state: State = .running(0)
    weak var download: WKDownload?
    var tempURL: URL?
    var observation: NSKeyValueObservation?
    init(name: String) { self.name = name }
    var isActive: Bool { if case .running = state { return true }; return false }
}

/// Owns the single WKWebView so the page stays alive while you switch sections.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    static let downloadsFolder = "Downloads"
    static let home = URL(string: "https://www.google.com")!

    let webView: WKWebView
    @Published var address = ""
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var downloads: [WebDownload] = []
    @Published var notice: String?
    /// MIME type of the page currently shown, used to offer "Save this file" for PDFs and media.
    @Published var currentMIME: String?

    weak var library: LibraryStore?
    private var observers: [NSKeyValueObservation] = []
    private var byDownload: [ObjectIdentifier: WebDownload] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.defaultWebpagePreferences.preferredContentMode = .recommended
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observers = [
            webView.observe(\.url) { [weak self] w, _ in Task { @MainActor in self?.address = w.url?.absoluteString ?? "" } },
            webView.observe(\.title) { [weak self] w, _ in Task { @MainActor in self?.title = w.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in Task { @MainActor in self?.canGoForward = w.canGoForward } },
            webView.observe(\.isLoading) { [weak self] w, _ in Task { @MainActor in self?.isLoading = w.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] w, _ in Task { @MainActor in self?.progress = w.estimatedProgress } },
        ]
        webView.load(URLRequest(url: Self.home))
    }

    // MARK: Navigation

    func go(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        webView.load(URLRequest(url: Self.destination(for: t)))
    }

    static func destination(for t: String) -> URL {
        if let u = URL(string: t), let s = u.scheme?.lowercased(), (s == "http" || s == "https"), u.host != nil { return u }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t), u.host != nil { return u }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url!
    }

    /// The current page as a single YouTube video, if it is one.
    var currentYouTubeLink: YouTubeLink? {
        if case .success(let l) = YouTubeLink.parse(address) { return l }
        return nil
    }

    var currentIsSavableFile: Bool {
        guard let m = currentMIME?.lowercased() else { return false }
        return m == "application/pdf" || m.hasPrefix("audio/") || m.hasPrefix("video/") || m.hasPrefix("image/")
    }

    /// Saves the PDF or media file currently displayed (never a web page disguised as something else).
    func saveCurrentFile() {
        guard currentIsSavableFile, let url = webView.url else { notice = "This page isn't a file that can be saved."; return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] d in
            Task { @MainActor in self?.attach(d) }
        }
    }

    // MARK: Downloads

    func attach(_ download: WKDownload) {
        download.delegate = self
        let item = WebDownload(name: download.originalRequest?.url?.lastPathComponent ?? "Download")
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted) { [weak item] p, _ in
            Task { @MainActor in if let item, item.isActive { item.state = .running(p.fractionCompleted) } }
        }
        byDownload[ObjectIdentifier(download)] = item
        downloads.insert(item, at: 0)
    }

    func cancel(_ item: WebDownload) {
        item.download?.cancel { _ in }
        item.state = .cancelled
        if let t = item.tempURL { try? FileManager.default.removeItem(at: t.deletingLastPathComponent()) }
    }

    func clearFinished() { downloads.removeAll { !$0.isActive } }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame { currentMIME = navigationResponse.response.mimeType }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(), disp.hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { attach(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { attach(download) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }

    private func report(_ error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || e.domain == "WebKitErrorDomain" && e.code == 102 { return } // frame load interrupted by download
        notice = e.code == NSURLErrorNotConnectedToInternet ? "You're offline. Downloaded files in your library still work." : e.localizedDescription
    }
}

extension BrowserModel: WKUIDelegate {
    /// Links that ask for a new window open in the same browser view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

extension BrowserModel: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let fs = library?.fs, let item = byDownload[ObjectIdentifier(download)] else { return nil }
        let name = SafePaths.sanitizeName(suggestedFilename, fallback: "Download")
        item.name = name
        guard let dir = try? fs.makeWorkFolder() else { item.state = .failed("Couldn't prepare a place to save the file."); return nil }
        let u = dir.appendingPathComponent(name)
        item.tempURL = u
        return u
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)), let temp = item.tempURL, let fs = library?.fs else { return }
        do {
            let rel = try fs.publish(temp, into: Self.downloadsFolder, preferredName: item.name)
            try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
            item.state = .finished(path: rel)
            item.name = (rel as NSString).lastPathComponent
            library?.refresh()
        } catch {
            item.state = .failed("The file downloaded but couldn't be added to your library.")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if case .cancelled = item.state { return }
        if let t = item.tempURL { try? FileManager.default.removeItem(at: t.deletingLastPathComponent()) }
        let e = error as NSError
        item.state = e.code == NSURLErrorCancelled ? .cancelled : .failed(e.code == NSURLErrorNotConnectedToInternet ? "You're offline." : "The download failed: \(e.localizedDescription)")
    }
}
