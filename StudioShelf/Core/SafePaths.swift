import Foundation

/// Errors from library operations, worded for ordinary users.
public enum LibraryError: LocalizedError, Equatable {
    case outsideLibrary
    case invalidName
    case notFound(String)
    case alreadyExists(String)
    case metadataCorrupt
    case metadataTooNew(Int)
    case tooLarge(limitMB: Int)
    case changedOnDisk
    case cannotRead(String)

    public var errorDescription: String? {
        switch self {
        case .outsideLibrary: return "That location is outside your library folder."
        case .invalidName: return "That name can't be used. Try a different one."
        case .notFound(let n): return "\u{201C}\(n)\u{201D} couldn't be found. It may have been moved or deleted."
        case .alreadyExists(let n): return "An item named \u{201C}\(n)\u{201D} is already there."
        case .metadataCorrupt: return "The library's tags and favorites file is damaged. Nothing was changed. You can keep browsing files; tags and favorites are paused until it's repaired."
        case .metadataTooNew(let v): return "This library was saved by a newer version of StudioShelf (format \(v)). Update the app to change tags or favorites."
        case .tooLarge(let mb): return "This file is larger than \(mb) MB, so it can't be opened for editing here."
        case .changedOnDisk: return "This file was changed somewhere else since you opened it."
        case .cannotRead(let n): return "\u{201C}\(n)\u{201D} couldn't be read."
        }
    }
}

/// Resolves library-relative paths and refuses anything that escapes the root,
/// including through symbolic links and through paths whose last parts don't exist yet.
public struct SafePaths {
    public let root: URL
    private let rootPath: String

    public init(root: URL) {
        let r = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = r
        self.rootPath = r.path
    }

    /// Resolve a relative path like "Downloads/Audio/song.mp3". Empty string is the root.
    public func resolve(_ relative: String) throws -> URL {
        if relative.hasPrefix("/") || relative.hasPrefix("~") { throw LibraryError.outsideLibrary }
        var url = root
        for part in relative.split(separator: "/", omittingEmptySubsequences: true) {
            let p = String(part)
            if p == "." { continue }
            if p == ".." || p.contains("\0") { throw LibraryError.outsideLibrary }
            url.appendPathComponent(p)
        }
        try ensureInside(url)
        return url
    }

    /// True when the item exists, without following a final symbolic link.
    public static func lexists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Throws unless `url` (or, if it doesn't exist yet, its deepest existing ancestor
    /// plus the missing tail) stays inside the library root after resolving links.
    public func ensureInside(_ url: URL) throws {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !SafePaths.lexists(existing) {
            if existing.path == "/" || existing.pathComponents.count <= 1 { throw LibraryError.outsideLibrary }
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        if tail.contains("..") { throw LibraryError.outsideLibrary }
        let resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved.path) else { throw LibraryError.outsideLibrary }
        // resolvingSymlinksInPath leaves dangling links alone, so check links explicitly.
        try checkLinks(existing, depth: 0)
    }

    private func checkLinks(_ url: URL, depth: Int) throws {
        if depth > 16 { throw LibraryError.outsideLibrary }
        var current = root
        let rel = (try? relativeLexical(url)) ?? nil
        guard let rel else { return }
        for part in rel.split(separator: "/") {
            current.appendPathComponent(String(part))
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: current.path) else { return }
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                let dest = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                let target = dest.hasPrefix("/") ? URL(fileURLWithPath: dest)
                    : current.deletingLastPathComponent().appendingPathComponent(dest)
                let std = target.standardizedFileURL
                if SafePaths.lexists(std) {
                    guard isInside(std.resolvingSymlinksInPath().standardizedFileURL.path) else { throw LibraryError.outsideLibrary }
                } else {
                    // Dangling: the lexical target must still be inside the library.
                    let parentResolved = std.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                    guard isInside(std.path) || isInside(parentResolved + "/" + std.lastPathComponent) else { throw LibraryError.outsideLibrary }
                }
            }
        }
    }

    /// Path of `url` below the root, compared without resolving links (handles /private/var aliases).
    private func relativeLexical(_ url: URL) throws -> String? {
        let p = url.standardizedFileURL.path
        for r in [rootPath, "/private" + rootPath, rootPath.replacingOccurrences(of: "/private/", with: "/")] {
            if p == r { return "" }
            let prefix = r.hasSuffix("/") ? r : r + "/"
            if p.hasPrefix(prefix) { return String(p.dropFirst(prefix.count)) }
        }
        return nil
    }

    public func isInside(_ path: String) -> Bool {
        if path == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }

    public func relativePath(of url: URL) throws -> String {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard isInside(p) else { throw LibraryError.outsideLibrary }
        if p == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return String(p.dropFirst(prefix.count))
    }

    /// Makes a user-supplied or web-supplied name safe to use as one path component.
    public static func sanitizeName(_ raw: String, fallback: String = "Untitled") -> String {
        var s = raw.precomposedStringWithCanonicalMapping
        let bad = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters).union(.newlines)
        s = String(s.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty || s == "-" { s = fallback }
        // Keep names comfortably below file-system limits (255 bytes).
        while s.utf8.count > 200 { s.removeLast() }
        return s
    }

    /// Returns `dir/name`, or `dir/name 2.ext`, `name 3.ext`… so nothing is ever overwritten.
    public static func uniqueURL(in dir: URL, name: String) -> URL {
        let candidate = dir.appendingPathComponent(name)
        if !lexists(candidate) { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let u = dir.appendingPathComponent(newName)
            if !lexists(u) { return u }
            n += 1
        }
    }
}
