import Foundation
import SwiftUI

/// Observable state for the current library folder.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var fs: LibraryFS?
    @Published private(set) var allItems: [FileItem] = []
    @Published private(set) var version = 0           // bumps after every change so views reload
    @Published var errorMessage: String?
    @Published private(set) var usingDefaultFolder = true
    @Published private(set) var needsReconnect = false

    private let bookmarkKey = "libraryBookmark"
    private var scopedURL: URL?

    /// The app's own folder, visible in Files as On My iPad › StudioShelf.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var locationDescription: String {
        guard let fs else { return "No library folder" }
        return usingDefaultFolder ? "On My iPad › StudioShelf" : fs.root.lastPathComponent
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() {
                scopedURL = url
                if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
                open(url, isDefault: false)
                return
            }
            needsReconnect = true
        }
        open(Self.defaultRoot, isDefault: true)
        if ProcessInfo.processInfo.arguments.contains("-demo") { DemoLibrary.seed(into: self) }
    }

    private func open(_ root: URL, isDefault: Bool) {
        do {
            let lib = try LibraryFS(root: root)
            lib.clearWork()
            fs = lib
            usingDefaultFolder = isDefault
            for f in ["Downloads", "Media", "Documents", "Printables"] { _ = try? lib.ensureFolder(f) }
            if let e = lib.metadataError { errorMessage = e.errorDescription }
            refresh()
        } catch {
            errorMessage = "Couldn't open that folder: \(error.localizedDescription)"
        }
    }

    func chooseFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { errorMessage = "StudioShelf wasn't given access to that folder."; return }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url
        if let data = try? url.bookmarkData() { UserDefaults.standard.set(data, forKey: bookmarkKey) }
        needsReconnect = false
        open(url, isDefault: false)
    }

    func useDefaultFolder() {
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        needsReconnect = false
        open(Self.defaultRoot, isDefault: true)
    }

    func refresh() {
        guard let fs else { return }
        version += 1
        let v = version
        // Scan off the main thread using a snapshot of the metadata, so nothing shared is mutated concurrently.
        let snapshot = fs.manifest.items
        Task.detached(priority: .utility) { [fs] in
            let items = fs.scanAll(meta: snapshot)
            await MainActor.run { if self.version == v { self.allItems = items } }
        }
    }

    // MARK: Actions with user-facing errors

    func perform(_ action: (LibraryFS) throws -> Void) {
        guard let fs else { return }
        do { try action(fs) } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        refresh()
    }

    /// Saves a playback position quietly (no rescan), used every few seconds while playing.
    func savePlayback(_ path: String, _ position: Double?) { try? fs?.setPlayback(path, position: position) }

    func list(_ dir: String) -> [FileItem] {
        guard let fs else { return [] }
        do { return try fs.list(dir) } catch { return [] }
    }

    func url(for item: FileItem) -> URL? { try? fs?.url(item.path) }

    func search(_ text: String) -> [FileItem] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return allItems.filter {
            $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) || $0.meta.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var folders: [FileItem] { allItems.filter { $0.isDirectory } }
}
