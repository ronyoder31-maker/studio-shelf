import SwiftUI
import UniformTypeIdentifiers

// MARK: Shared row / tile

struct FileRow: View {
    let item: FileItem
    var body: some View {
        HStack(spacing: 12) {
            FileIcon(item: item, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(2)
                HStack(spacing: 6) {
                    if item.notDownloaded { Label("In iCloud, not on this iPad", systemImage: "icloud.and.arrow.down").labelStyle(.titleAndIcon) }
                    else if !item.isDirectory { Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) }
                    if !item.meta.tags.isEmpty { Text(item.meta.tags.joined(separator: ", ")).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.meta.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favorite") }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct FileIcon: View {
    let item: FileItem
    var size: CGFloat
    var color: Color {
        switch item.kind {
        case .folder: return .accentColor
        case .pdf: return .red
        case .audio: return .pink
        case .video: return .purple
        case .word: return .blue
        case .image: return .orange
        default: return .gray
        }
    }
    var body: some View {
        Image(systemName: item.kind.symbol)
            .font(.system(size: size * 0.55))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}

struct FileTile: View {
    let item: FileItem
    var body: some View {
        VStack(spacing: 8) {
            FileIcon(item: item, size: 72)
            Text(item.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: Item actions (rename, move, tags, favorite, share, trash)

struct ItemActions: ViewModifier {
    @EnvironmentObject var library: LibraryStore
    let item: FileItem
    @State private var renaming = false
    @State private var newName = ""
    @State private var tagging = false
    @State private var tagsText = ""
    @State private var moving = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { library.perform { try $0.setFavorite(item.path, !item.meta.favorite) } } label: {
                    Label(item.meta.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.meta.favorite ? "star.slash" : "star")
                }
                Button { newName = item.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button { tagsText = item.meta.tags.joined(separator: ", "); tagging = true } label: { Label("Tags", systemImage: "tag") }
                Button { moving = true } label: { Label("Move", systemImage: "folder") }
                if let url = library.url(for: item), !item.isDirectory {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                Divider()
                Button(role: .destructive) { library.perform { _ = try $0.trash(item.path) } } label: { Label("Move to Library Trash", systemImage: "trash") }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { library.perform { _ = try $0.trash(item.path) } } label: { Label("Trash", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button { library.perform { try $0.setFavorite(item.path, !item.meta.favorite) } } label: { Label("Favorite", systemImage: "star") }.tint(.yellow)
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { library.perform { _ = try $0.rename(item.path, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Tags", isPresented: $tagging) {
                TextField("travel, grade 3, winter", text: $tagsText)
                Button("Save") { library.perform { try $0.setTags(item.path, tagsText: tagsText) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Separate tags with commas.") }
            .sheet(isPresented: $moving) { MoveSheet(item: item) }
    }
}

extension View { func itemActions(_ item: FileItem) -> some View { modifier(ItemActions(item: item)) } }

struct MoveSheet: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: FileItem
    var body: some View {
        NavigationStack {
            List {
                Button { move(to: "") } label: { Label("Library (top level)", systemImage: "house") }
                ForEach(library.folders.filter { $0.path != item.path && !$0.path.hasPrefix(item.path + "/") }) { f in
                    Button { move(to: f.path) } label: { Label(f.path, systemImage: "folder") }
                }
            }
            .navigationTitle("Move \u{201C}\(item.name)\u{201D}")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    func move(to dir: String) { library.perform { _ = try $0.move(item.path, toFolder: dir) }; dismiss() }
}

// MARK: Folder browsing

struct FolderView: View {
    @EnvironmentObject var library: LibraryStore
    let path: String
    let title: String
    @AppStorage("useGrid") private var useGrid = false
    @State private var query = ""
    @State private var importing = false
    @State private var newFolder = false
    @State private var newText = false
    @State private var newName = ""

    var items: [FileItem] { _ = library.version; return query.isEmpty ? library.list(path) : library.search(query) }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "This folder is empty" : "No matches",
                                       systemImage: query.isEmpty ? "folder" : "magnifyingglass",
                                       description: Text(query.isEmpty ? "Import files or download them in the Browser." : "Search looks at names, folders and tags."))
            } else if useGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(items) { i in NavigationLink(value: i) { FileTile(item: i) }.buttonStyle(.plain).itemActions(i) }
                    }.padding()
                }
            } else {
                List(items) { i in NavigationLink(value: i) { FileRow(item: i) }.itemActions(i) }
                    .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Search names, folders and tags")
        .refreshable { library.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { useGrid.toggle() } label: { Label(useGrid ? "List" : "Grid", systemImage: useGrid ? "list.bullet" : "square.grid.2x2") }
                Menu {
                    Button { importing = true } label: { Label("Import Files…", systemImage: "square.and.arrow.down.on.square") }
                    Button { newName = ""; newFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { newName = ""; newText = true } label: { Label("New Text Document", systemImage: "doc.badge.plus") }
                } label: { Label("Add", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                library.perform { fs in for u in urls { _ = try fs.importCopy(of: u, into: path) } }
            }
        }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $newName)
            Button("Create") { library.perform { _ = try $0.createFolder(named: newName, in: path) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Text Document", isPresented: $newText) {
            TextField("Name", text: $newName)
            Button("Create") { library.perform { _ = try $0.createTextFile(named: newName, in: path) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A filtered view across the whole library (Media, Documents, Favorites).
struct SmartListView: View {
    @EnvironmentObject var library: LibraryStore
    let title: String
    let emptyText: String
    let filter: (FileItem) -> Bool
    @State private var query = ""

    var items: [FileItem] {
        let base = library.allItems.filter { !$0.isDirectory && filter($0) }
        let q = query.lowercased()
        let list = q.isEmpty ? base : base.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) || $0.meta.tags.contains { $0.lowercased().contains(q) } }
        return list.sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(title, systemImage: "tray", description: Text(query.isEmpty ? emptyText : "No matches."))
            } else {
                List(items) { i in
                    NavigationLink(value: i) {
                        VStack(alignment: .leading) {
                            FileRow(item: i)
                            Text((i.path as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }.itemActions(i)
                }.listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Search \(title.lowercased())")
        .refreshable { library.refresh() }
    }
}

// MARK: Trash

struct TrashView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var confirmEmpty = false
    var records: [TrashRecord] { _ = library.version; return (library.fs?.manifest.trash ?? []).sorted { $0.trashedAt > $1.trashedAt } }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView("Library Trash is empty", systemImage: "trash", description: Text("Items you remove stay here until you delete them for good."))
            } else {
                List(records) { r in
                    HStack {
                        Image(systemName: r.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(r.name)
                            Text("From \(r.originalPath.isEmpty ? "Library" : (r.originalPath as NSString).deletingLastPathComponent.isEmpty ? "Library" : (r.originalPath as NSString).deletingLastPathComponent) · \(r.trashedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { library.perform { _ = try $0.restore(r.id) } }.buttonStyle(.bordered)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { library.perform { try $0.deleteFromTrash(r.id) } } }
                }
            }
        }
        .navigationTitle("Library Trash")
        .toolbar {
            Button("Empty Trash", role: .destructive) { confirmEmpty = true }.disabled(records.isEmpty)
        }
        .confirmationDialog("Delete everything in Library Trash for good?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete for Good", role: .destructive) { library.perform { try $0.emptyTrash() } }
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var picking = false
    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Library folder", value: library.locationDescription)
                Button("Choose Another Folder…") { picking = true }
                if !library.usingDefaultFolder { Button("Use On My iPad › \(AppInfo.name)") { library.useDefaultFolder() } }
                if library.needsReconnect {
                    Text("The folder you chose before can't be reached right now. Choose it again to reconnect.").foregroundStyle(.orange)
                }
            } header: { Text("Where your files live") } footer: {
                Text("\(AppInfo.name) only works inside this folder. The default is on this iPad, so movies and MP3s there play offline. You can also see it in the Files app.")
            }
            SwiftUI.Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                NavigationLink("Open-source notices") { LicensesView() }
            }
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { library.chooseFolder(u) }
        }
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text(Licenses.text).font(.footnote.monospaced()).padding().frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle("Open-source notices")
    }
}
