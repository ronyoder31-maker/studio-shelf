import SwiftUI
import AVFoundation

/// Change the app's visible name here (and CFBundleDisplayName in project.yml).
enum AppInfo {
    static let name = "StudioShelf"
}

@main
struct StudioShelfApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var browser: BrowserModel
    @StateObject private var audio: AudioDownloadManager

    init() {
        let lib = LibraryStore()
        LibraryStoreRegistry.shared = lib
        let b = BrowserModel(); b.library = lib
        let a = AudioDownloadManager(); a.library = lib
        _library = StateObject(wrappedValue: lib)
        _browser = StateObject(wrappedValue: b)
        _audio = StateObject(wrappedValue: a)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(browser)
                .environmentObject(audio)
                .onOpenURL { url in
                    // Files shared or AirDropped into the app are copied into Downloads right away.
                    if url.isFileURL { library.perform { _ = try $0.importCopy(of: url, into: "Downloads") } }
                }
        }
    }
}
