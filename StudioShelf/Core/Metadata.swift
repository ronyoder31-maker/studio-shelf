import Foundation

public struct ItemMeta: Codable, Hashable {
    public var tags: [String] = []
    public var favorite: Bool = false
    public var playbackPosition: Double? = nil
    public init(tags: [String] = [], favorite: Bool = false, playbackPosition: Double? = nil) {
        self.tags = tags; self.favorite = favorite; self.playbackPosition = playbackPosition
    }
    public var isEmpty: Bool { tags.isEmpty && !favorite && playbackPosition == nil }
}

public struct TrashRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var originalPath: String
    public var name: String
    public var isDirectory: Bool
    public var trashedAt: Date
    /// Metadata for the item and, for folders, everything inside it (keys relative to the item).
    public var meta: [String: ItemMeta]
}

public struct Manifest: Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int = Manifest.currentVersion
    public var items: [String: ItemMeta] = [:]
    public var trash: [TrashRecord] = []
    public init() {}
}

/// Stores tags, favorites, playback positions and trash records in
/// `<library>/.studioshelf/manifest.json`. Files themselves stay ordinary files.
public final class MetadataStore {
    public static let folderName = ".studioshelf"
    public let folder: URL
    public var fileURL: URL { folder.appendingPathComponent("manifest.json") }

    public init(libraryRoot: URL) {
        folder = libraryRoot.appendingPathComponent(MetadataStore.folderName, isDirectory: true)
    }

    /// Loads the manifest. A missing file is a fresh library; a damaged or newer
    /// file is an error and is never replaced with an empty default.
    public func load() throws -> Manifest {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Manifest() }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw LibraryError.metadataCorrupt }
        struct VersionProbe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { throw LibraryError.metadataCorrupt }
        if probe.version > Manifest.currentVersion { throw LibraryError.metadataTooNew(probe.version) }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let m = try? dec.decode(Manifest.self, from: data) else { throw LibraryError.metadataCorrupt }
        return m
    }

    public func save(_ manifest: Manifest) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(manifest)
        try data.write(to: fileURL, options: .atomic)
    }
}
