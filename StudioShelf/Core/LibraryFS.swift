import Foundation
import UniformTypeIdentifiers

public enum FileKind: String, Codable {
    case folder, pdf, audio, video, image, text, word, other

    public static func of(url: URL, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "docx", "doc": return .word
        case "txt", "md", "markdown", "csv", "json", "rtf": return ext == "rtf" ? .other : .text
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac": return .audio
        case "mp4", "m4v", "mov": return .video
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff": return .image
        default:
            if let t = UTType(filenameExtension: ext) {
                if t.conforms(to: .movie) { return .video }
                if t.conforms(to: .audio) { return .audio }
                if t.conforms(to: .image) { return .image }
                if t.conforms(to: .plainText) { return .text }
            }
            return .other
        }
    }

    public var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .pdf: return "doc.richtext"
        case .audio: return "music.note"
        case .video: return "film"
        case .image: return "photo"
        case .text: return "doc.plaintext"
        case .word: return "doc.text"
        case .other: return "doc"
        }
    }
}

public struct FileItem: Identifiable, Hashable {
    public var id: String { path }
    public let path: String          // relative to library root
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date
    public let kind: FileKind
    public var notDownloaded: Bool = false   // cloud placeholder, not offline-ready
    public var meta: ItemMeta = ItemMeta()
}

/// All file and metadata operations for one library folder.
/// Not thread-safe: use from one actor (the app uses it from the main actor;
/// heavy scanning goes through `scanAll`, which is pure).
public final class LibraryFS {
    public let paths: SafePaths
    public let store: MetadataStore
    public private(set) var manifest: Manifest
    /// Set when the manifest can't be used; file browsing still works, metadata edits are refused.
    public private(set) var metadataError: LibraryError?
    private let fm = FileManager.default

    public var root: URL { paths.root }
    public var trashFolder: URL { store.folder.appendingPathComponent("Trash", isDirectory: true) }
    public var workFolder: URL { store.folder.appendingPathComponent("Work", isDirectory: true) }

    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SafePaths(root: root)
        store = MetadataStore(libraryRoot: paths.root)
        do { manifest = try store.load(); metadataError = nil }
        catch let e as LibraryError { manifest = Manifest(); metadataError = e }
    }

    // MARK: Listing

    public func list(_ dir: String) throws -> [FileItem] {
        let url = try paths.resolve(dir)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return urls.compactMap { item(for: $0, keys: keys) }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }

    func item(for url: URL, keys: [URLResourceKey], meta: [String: ItemMeta]? = nil) -> FileItem? {
        guard let rel = try? paths.relativePath(of: url), !rel.hasPrefix(MetadataStore.folderName) else { return nil }
        let v = try? url.resourceValues(forKeys: Set(keys))
        let isDir = v?.isDirectory ?? false
        var name = url.lastPathComponent
        var placeholder = false
        // iCloud placeholders look like ".Name.ext.icloud"
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            name = String(name.dropFirst().dropLast(7)); placeholder = true
        }
        if let s = v?.ubiquitousItemDownloadingStatus, s != .current { placeholder = true }
        var fi = FileItem(path: rel, name: name, isDirectory: isDir, size: Int64(v?.fileSize ?? 0),
                          modified: v?.contentModificationDate ?? .distantPast,
                          kind: FileKind.of(url: URL(fileURLWithPath: name), isDirectory: isDir))
        fi.notDownloaded = placeholder
        fi.meta = (meta ?? manifest.items)[rel] ?? ItemMeta()
        return fi
    }

    /// Every file and folder in the library (bounded), for search and smart sections.
    public func scanAll(limit: Int = 50_000, meta: [String: ItemMeta]? = nil) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [FileItem] = []
        for case let u as URL in e {
            if out.count >= limit { break }
            if let i = item(for: u, keys: keys, meta: meta) { out.append(i) }
        }
        return out
    }

    public func url(_ rel: String) throws -> URL { try paths.resolve(rel) }

    // MARK: Creating

    @discardableResult
    public func createFolder(named raw: String, in dir: String) throws -> String {
        let name = SafePaths.sanitizeName(raw, fallback: "New Folder")
        let parent = try paths.resolve(dir)
        let target = parent.appendingPathComponent(name)
        try paths.ensureInside(target)
        if SafePaths.lexists(target) { throw LibraryError.alreadyExists(name) }
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        return try paths.relativePath(of: target)
    }

    @discardableResult
    public func createTextFile(named raw: String, in dir: String, contents: String = "") throws -> String {
        var name = SafePaths.sanitizeName(raw, fallback: "Untitled")
        if (name as NSString).pathExtension.isEmpty { name += ".txt" }
        let parent = try paths.resolve(dir)
        let target = SafePaths.uniqueURL(in: parent, name: name)
        try paths.ensureInside(target)
        try Data(contents.utf8).write(to: target, options: .withoutOverwriting)
        return try paths.relativePath(of: target)
    }

    /// Ensures a folder path such as "Downloads/Audio" exists and returns its URL.
    @discardableResult
    public func ensureFolder(_ rel: String) throws -> URL {
        let u = try paths.resolve(rel)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        try paths.ensureInside(u)
        return u
    }

    /// Copies an outside file (from Files, a share, AirDrop) into the library.
    /// The copy is made immediately, so nothing depends on a temporary URL afterwards.
    @discardableResult
    public func importCopy(of source: URL, into dir: String) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let parent = try ensureFolder(dir)
        let name = SafePaths.sanitizeName(source.lastPathComponent)
        let target = SafePaths.uniqueURL(in: parent, name: name)
        try paths.ensureInside(target)
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordError) { readURL in
            do { try self.fm.copyItem(at: readURL, to: target) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw e }
        return try paths.relativePath(of: target)
    }

    /// Moves a finished file (download, conversion) into a visible folder without overwriting.
    @discardableResult
    public func publish(_ file: URL, into dir: String, preferredName: String) throws -> String {
        let parent = try ensureFolder(dir)
        let target = SafePaths.uniqueURL(in: parent, name: SafePaths.sanitizeName(preferredName))
        try paths.ensureInside(target)
        try fm.moveItem(at: file, to: target)
        return try paths.relativePath(of: target)
    }

    // MARK: Rename / move (metadata follows the item)

    @discardableResult
    public func rename(_ rel: String, to raw: String) throws -> String {
        let src = try paths.resolve(rel)
        guard SafePaths.lexists(src), !rel.isEmpty else { throw LibraryError.notFound(src.lastPathComponent) }
        let name = SafePaths.sanitizeName(raw)
        guard name != src.lastPathComponent else { return rel }
        let dst = src.deletingLastPathComponent().appendingPathComponent(name)
        try paths.ensureInside(dst)
        // Allow case-only renames on case-insensitive volumes.
        let caseOnly = name.lowercased() == src.lastPathComponent.lowercased()
        if SafePaths.lexists(dst) && !caseOnly { throw LibraryError.alreadyExists(name) }
        return try relocate(src: src, dst: dst, oldRel: rel)
    }

    @discardableResult
    public func move(_ rel: String, toFolder dir: String) throws -> String {
        let src = try paths.resolve(rel)
        guard SafePaths.lexists(src), !rel.isEmpty else { throw LibraryError.notFound(src.lastPathComponent) }
        let parent = try paths.resolve(dir)
        let destRel = try paths.relativePath(of: parent)
        if destRel == rel || destRel.hasPrefix(rel + "/") { throw LibraryError.invalidName }
        let dst = parent.appendingPathComponent(src.lastPathComponent)
        try paths.ensureInside(dst)
        if dst.standardizedFileURL == src.standardizedFileURL { return rel }
        if SafePaths.lexists(dst) { throw LibraryError.alreadyExists(src.lastPathComponent) }
        return try relocate(src: src, dst: dst, oldRel: rel)
    }

    private func relocate(src: URL, dst: URL, oldRel: String) throws -> String {
        let before = manifest
        try fm.moveItem(at: src, to: dst)
        let newRel = try paths.relativePath(of: dst)
        rekey(from: oldRel, to: newRel)
        do { try saveManifestIfUsable() } catch {
            // Roll back so files and metadata stay consistent.
            try? fm.moveItem(at: dst, to: src)
            manifest = before
            throw error
        }
        return newRel
    }

    private func rekey(from old: String, to new: String) {
        var updated: [String: ItemMeta] = [:]
        for (k, v) in manifest.items {
            if k == old { updated[new] = v }
            else if k.hasPrefix(old + "/") { updated[new + k.dropFirst(old.count)] = v }
            else { updated[k] = v }
        }
        manifest.items = updated
    }

    // MARK: Trash

    @discardableResult
    public func trash(_ rel: String) throws -> TrashRecord {
        let src = try paths.resolve(rel)
        guard SafePaths.lexists(src), !rel.isEmpty else { throw LibraryError.notFound(src.lastPathComponent) }
        try requireUsableMetadata()
        let id = UUID()
        let holder = trashFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: holder, withIntermediateDirectories: true)
        let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let dst = holder.appendingPathComponent(src.lastPathComponent)
        var captured: [String: ItemMeta] = [:]
        for (k, v) in manifest.items {
            if k == rel { captured[""] = v } else if k.hasPrefix(rel + "/") { captured[String(k.dropFirst(rel.count + 1))] = v }
        }
        let record = TrashRecord(id: id, originalPath: rel, name: src.lastPathComponent, isDirectory: isDir, trashedAt: Date(), meta: captured)
        let before = manifest
        try fm.moveItem(at: src, to: dst)
        manifest.items = manifest.items.filter { $0.key != rel && !$0.key.hasPrefix(rel + "/") }
        manifest.trash.append(record)
        do { try store.save(manifest) } catch {
            try? fm.moveItem(at: dst, to: src); try? fm.removeItem(at: holder); manifest = before; throw error
        }
        return record
    }

    /// Restores to the original place. If something now occupies that name,
    /// the restored item gets a new name ("Report 2.pdf"); nothing is replaced.
    @discardableResult
    public func restore(_ id: UUID) throws -> String {
        try requireUsableMetadata()
        guard let idx = manifest.trash.firstIndex(where: { $0.id == id }) else { throw LibraryError.notFound("item") }
        let rec = manifest.trash[idx]
        let held = trashFolder.appendingPathComponent(rec.id.uuidString).appendingPathComponent(rec.name)
        guard SafePaths.lexists(held) else { throw LibraryError.notFound(rec.name) }
        let original = try paths.resolve(rec.originalPath)
        let parent = original.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try paths.ensureInside(parent)
        let dst = SafePaths.uniqueURL(in: parent, name: rec.name)
        try paths.ensureInside(dst)
        let before = manifest
        try fm.moveItem(at: held, to: dst)
        let newRel = try paths.relativePath(of: dst)
        for (k, v) in rec.meta { manifest.items[k.isEmpty ? newRel : newRel + "/" + k] = v }
        manifest.trash.remove(at: idx)
        do { try store.save(manifest) } catch { try? fm.moveItem(at: dst, to: held); manifest = before; throw error }
        try? fm.removeItem(at: trashFolder.appendingPathComponent(rec.id.uuidString))
        return newRel
    }

    public func deleteFromTrash(_ id: UUID) throws {
        try requireUsableMetadata()
        guard let idx = manifest.trash.firstIndex(where: { $0.id == id }) else { return }
        let holder = trashFolder.appendingPathComponent(manifest.trash[idx].id.uuidString)
        try paths.ensureInside(holder)
        if SafePaths.lexists(holder) { try fm.removeItem(at: holder) }
        manifest.trash.remove(at: idx)
        try store.save(manifest)
    }

    public func emptyTrash() throws { for r in manifest.trash { try deleteFromTrash(r.id) } }

    // MARK: Metadata edits

    public func setTags(_ rel: String, tagsText: String) throws {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>(); let unique = tags.filter { seen.insert($0.lowercased()).inserted }
        try updateMeta(rel) { $0.tags = unique }
    }

    public func setFavorite(_ rel: String, _ fav: Bool) throws { try updateMeta(rel) { $0.favorite = fav } }

    public func setPlayback(_ rel: String, position: Double?) throws { try updateMeta(rel) { $0.playbackPosition = position } }

    public func meta(_ rel: String) -> ItemMeta { manifest.items[rel] ?? ItemMeta() }

    private func updateMeta(_ rel: String, _ change: (inout ItemMeta) -> Void) throws {
        try requireUsableMetadata()
        _ = try paths.resolve(rel)
        let before = manifest
        var m = manifest.items[rel] ?? ItemMeta()
        change(&m)
        manifest.items[rel] = m.isEmpty ? nil : m
        do { try store.save(manifest) } catch { manifest = before; throw error }
    }

    private func requireUsableMetadata() throws { if let e = metadataError { throw e } }

    private func saveManifestIfUsable() throws {
        // When metadata is damaged we still allow file moves but never overwrite the damaged file.
        if metadataError == nil { try store.save(manifest) }
    }

    /// Removes leftovers from interrupted downloads or conversions.
    public func clearWork() { try? fm.removeItem(at: workFolder) }

    public func makeWorkFolder() throws -> URL {
        let u = workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
