import SwiftUI
import AVKit
import PDFKit
import QuickLook

struct FileDetailView: View {
    @EnvironmentObject var library: LibraryStore
    let item: FileItem

    var body: some View {
        Group {
            if item.notDownloaded {
                ContentUnavailableView("Not on this iPad yet", systemImage: "icloud.and.arrow.down",
                                       description: Text("This file is stored in iCloud and isn't offline-ready. Open it in Files to download it, or import a copy."))
            } else if let url = library.url(for: item) {
                switch item.kind {
                case .audio, .video: MediaPlayerView(item: item, url: url)
                case .pdf: PDFDetailView(item: item, url: url)
                case .text: TextEditorView(item: item, url: url)
                case .word: WordPreviewView(url: url)
                default: QuickLookView(url: url).ignoresSafeArea(edges: .bottom)
                }
            } else {
                ContentUnavailableView("File unavailable", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = library.url(for: item) {
                ToolbarItem(placement: .topBarTrailing) { ShareLink(item: url) }
            }
        }
    }
}

// MARK: Media

@MainActor
final class PlayerModel: ObservableObject {
    let player: AVPlayer
    @Published var rate: Float = 1
    @Published var repeats = false
    @Published var error: String?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private let save: (Double?) -> Void

    init(url: URL, resumeAt: Double?, save: @escaping (Double?) -> Void) {
        self.save = save
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        statusObs = item.observe(\.status) { [weak self] it, _ in
            Task { @MainActor in
                if it.status == .failed {
                    self?.error = "This file can't be played. It may be damaged, protected, or use a format this iPad doesn't support."
                } else if it.status == .readyToPlay, let t = resumeAt, t > 1 {
                    let dur = it.duration.seconds
                    if dur.isFinite && t < dur - 3 { await self?.player.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.persist() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.repeats { self.player.seek(to: .zero); self.player.playImmediately(atRate: self.rate) }
                else { self.save(nil) }
            }
        }
    }

    func setRate(_ r: Float) { rate = r; if player.rate != 0 { player.rate = r }; player.defaultRate = r }

    func persist() {
        let t = player.currentTime().seconds
        if t.isFinite && t > 1 { save(t) }
    }

    func teardown() {
        persist(); player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil; endObserver = nil
    }
}

struct MediaPlayerView: View {
    @EnvironmentObject var library: LibraryStore
    let item: FileItem
    let url: URL
    @StateObject private var model: PlayerModel

    init(item: FileItem, url: URL) {
        self.item = item; self.url = url
        let path = item.path
        _model = StateObject(wrappedValue: PlayerModel(url: url, resumeAt: item.meta.playbackPosition, save: { pos in
            Task { @MainActor in LibraryStoreRegistry.shared?.savePlayback(path, pos) }
        }))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let e = model.error {
                ContentUnavailableView("Can't play this file", systemImage: "exclamationmark.triangle", description: Text(e))
            } else {
                ZStack {
                    VideoPlayer(player: model.player) {
                        if item.kind == .audio {
                            VStack(spacing: 12) {
                                Image(systemName: "music.note").font(.system(size: 72)).foregroundStyle(.pink)
                                Text(item.name).font(.title3).multilineTextAlignment(.center).padding(.horizontal)
                            }
                        }
                    }
                }
                HStack(spacing: 20) {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Button { model.setRate(Float(r)) } label: {
                                if Float(r) == model.rate { Label("\(r, specifier: "%g")×", systemImage: "checkmark") } else { Text("\(r, specifier: "%g")×") }
                            }
                        }
                    } label: { Label("Speed \(Double(model.rate), specifier: "%g")×", systemImage: "gauge.with.dots.needle.33percent") }
                    Toggle(isOn: $model.repeats) { Label("Repeat", systemImage: "repeat") }.toggleStyle(.button)
                    Spacer()
                    if let p = item.meta.playbackPosition, p > 1 {
                        Text("Resumes from \(Duration.seconds(p).formatted(.time(pattern: .minuteSecond)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .onAppear { LibraryStoreRegistry.shared = library }
        .onDisappear { model.teardown() }
    }
}

/// Lets player callbacks reach the library without retaining views.
@MainActor enum LibraryStoreRegistry { static weak var shared: LibraryStore? }

// MARK: PDF

struct PDFKitView: UIViewRepresentable {
    let pdfView: PDFView
    func makeUIView(context: Context) -> PDFView { pdfView }
    func updateUIView(_ v: PDFView, context: Context) {}
}

struct PDFDetailView: View {
    @EnvironmentObject var library: LibraryStore
    let item: FileItem
    let url: URL
    @State private var pdfView = PDFView()
    @State private var highlights = 0
    @State private var message: String?

    var body: some View {
        PDFKitView(pdfView: pdfView)
            .onAppear {
                pdfView.autoScales = true
                pdfView.displayMode = .singlePageContinuous
                pdfView.usePageViewController(false)
                if pdfView.document == nil {
                    if let doc = PDFDocument(url: url) {
                        if doc.isLocked { message = "This PDF is password-protected and can't be opened here." }
                        pdfView.document = doc
                    } else { message = "This PDF couldn't be opened. It may be damaged." }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { highlight() } label: { Label("Highlight Selection", systemImage: "highlighter") }
                    Button { saveCopy() } label: { Label("Save Marked Copy", systemImage: "square.and.arrow.down.on.square") }
                        .disabled(highlights == 0)
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message).font(.callout).padding(10).background(.regularMaterial, in: Capsule()).padding()
                        .onTapGesture { self.message = nil }
                }
            }
    }

    func highlight() {
        guard let sel = pdfView.currentSelection, !(sel.string ?? "").isEmpty else { message = "Select some text first, then tap Highlight."; return }
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                a.color = UIColor.systemYellow.withAlphaComponent(0.5)
                page.addAnnotation(a)
            }
        }
        highlights += 1
        pdfView.clearSelection()
        message = "Highlighted. Your original stays unchanged until you save a marked copy."
    }

    /// Writes a separate "(marked)" PDF next to the original. The original file is never modified.
    func saveCopy() {
        guard let doc = pdfView.document, let fs = library.fs else { return }
        let parent = url.deletingLastPathComponent()
        let base = (item.name as NSString).deletingPathExtension
        let target = SafePaths.uniqueURL(in: parent, name: "\(base) (marked).pdf")
        do {
            try fs.paths.ensureInside(target)
            guard doc.write(to: target) else { throw LibraryError.cannotRead(item.name) }
            guard PDFDocument(url: target) != nil else { throw LibraryError.cannotRead(target.lastPathComponent) }
            message = "Saved \u{201C}\(target.lastPathComponent)\u{201D}."
            library.refresh()
        } catch { message = "Couldn't save the marked copy." }
    }
}

// MARK: Text

struct TextEditorView: View {
    @EnvironmentObject var library: LibraryStore
    let item: FileItem
    let url: URL
    static let limitMB = 5
    @State private var text = ""
    @State private var original = ""
    @State private var loadedDate: Date?
    @State private var error: String?
    @State private var conflict = false
    @State private var saved = false

    var body: some View {
        Group {
            if let error { ContentUnavailableView("Can't edit this file", systemImage: "doc.questionmark", description: Text(error)) }
            else {
                TextEditor(text: $text)
                    .font(.body)
                    .padding(.horizontal)
                    .accessibilityLabel("Document text")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(saved && text == original ? "Saved" : "Save") { save(force: false) }.disabled(text == original || error != nil)
            }
        }
        .onAppear(perform: load)
        .alert("Changed somewhere else", isPresented: $conflict) {
            Button("Save as a Copy") { saveCopy() }
            Button("Reload (discard my edits)", role: .destructive) { load() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This file was changed outside \(AppInfo.name) after you opened it. Nothing has been overwritten.") }
    }

    func modDate() -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }

    func load() {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Self.limitMB * 1024 * 1024 { error = LibraryError.tooLarge(limitMB: Self.limitMB).errorDescription; return }
        guard let data = try? Data(contentsOf: url) else { error = "The file couldn't be read."; return }
        guard let s = String(data: data, encoding: .utf8) else { error = "This file isn't UTF-8 text, so it can't be edited safely here."; return }
        text = s; original = s; loadedDate = modDate(); saved = false
    }

    func save(force: Bool) {
        if !force, let loadedDate, let now = modDate(), abs(now.timeIntervalSince(loadedDate)) > 0.5 { conflict = true; return }
        var err: NSError?; var writeErr: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            do { try Data(text.utf8).write(to: u, options: .atomic) } catch { writeErr = error }
        }
        if err != nil || writeErr != nil { library.errorMessage = "Couldn't save. Your text is still here."; return }
        original = text; loadedDate = modDate(); saved = true
    }

    func saveCopy() {
        guard let fs = library.fs else { return }
        let base = (item.name as NSString).deletingPathExtension, ext = (item.name as NSString).pathExtension
        let target = SafePaths.uniqueURL(in: url.deletingLastPathComponent(), name: "\(base) (my edits).\(ext.isEmpty ? "txt" : ext)")
        do { try fs.paths.ensureInside(target); try Data(text.utf8).write(to: target, options: .withoutOverwriting); library.refresh()
            library.errorMessage = "Saved your edits as \u{201C}\(target.lastPathComponent)\u{201D}."
        } catch { library.errorMessage = "Couldn't save the copy." }
    }
}

// MARK: Word (preview in this stage)

struct WordPreviewView: View {
    let url: URL
    var body: some View {
        VStack(spacing: 0) {
            Label("Preview only for now. Word editing is planned for a later stage; your original is never changed here.", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity).background(.bar)
            QuickLookView(url: url)
        }
    }
}

// MARK: Quick Look fallback

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController(); c.dataSource = context.coordinator; return c
    }
    func updateUIViewController(_ c: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
