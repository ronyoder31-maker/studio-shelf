import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case browser, downloads, media, documents, printables, favorites, allFiles, trash, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .browser: return "Browser"
        case .downloads: return "Downloads"
        case .media: return "Media"
        case .documents: return "Documents"
        case .printables: return "Printables"
        case .favorites: return "Favorites"
        case .allFiles: return "All Files"
        case .trash: return "Library Trash"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .browser: return "safari"
        case .downloads: return "arrow.down.circle"
        case .media: return "play.rectangle.on.rectangle"
        case .documents: return "doc.text"
        case .printables: return "printer"
        case .favorites: return "star"
        case .allFiles: return "folder"
        case .trash: return "trash"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var audio: AudioDownloadManager
    @EnvironmentObject var browser: BrowserModel
    @State private var selection: SidebarItem? = RootView.initialSection
    @State private var columns: NavigationSplitViewVisibility = .automatic

    static var initialSection: SidebarItem {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-section"), i + 1 < args.count, let s = SidebarItem(rawValue: args[i + 1]) { return s }
        return .browser
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                SwiftUI.Section("Library") {
                    ForEach([SidebarItem.browser, .downloads, .media, .documents, .printables, .favorites, .allFiles]) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                            .badge(s == .downloads ? activeCount : 0)
                    }
                }
                SwiftUI.Section {
                    Label(SidebarItem.trash.title, systemImage: SidebarItem.trash.symbol).tag(SidebarItem.trash)
                    Label(SidebarItem.settings.title, systemImage: SidebarItem.settings.symbol).tag(SidebarItem.settings)
                }
            }
            .navigationTitle(AppInfo.name)
        } detail: {
            NavigationStack {
                detail(for: selection ?? .browser)
                    .navigationDestination(for: FileItem.self) { item in
                        if item.isDirectory { FolderView(path: item.path, title: item.name) } else { FileDetailView(item: item) }
                    }
            }
            .id(selection)
        }
        .alert("Something needs attention", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(library.errorMessage ?? "") }
    }

    var activeCount: Int {
        audio.jobs.filter { $0.phase.isActive }.count + browser.downloads.filter { $0.isActive }.count
    }

    @ViewBuilder func detail(for s: SidebarItem) -> some View {
        switch s {
        case .browser: BrowserView()
        case .downloads: DownloadsView()
        case .media: SmartListView(title: "Media", emptyText: "Audio and video in your library appear here.") { [.audio, .video].contains($0.kind) }
        case .documents: SmartListView(title: "Documents", emptyText: "PDFs, Word and text files appear here.") { [.pdf, .word, .text].contains($0.kind) }
        case .printables: FolderView(path: "Printables", title: "Printables")
        case .favorites: SmartListView(title: "Favorites", emptyText: "Mark files as favorites to find them here.") { $0.meta.favorite }
        case .allFiles: FolderView(path: "", title: "All Files")
        case .trash: TrashView()
        case .settings: SettingsView()
        }
    }
}
