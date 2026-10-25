import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var audio: AudioDownloadManager
    @EnvironmentObject var browser: BrowserModel
    @State private var showAudio = false

    var files: [FileItem] {
        _ = library.version
        return library.allItems.filter { !$0.isDirectory && ($0.path.hasPrefix("Downloads/")) }
            .sorted { $0.modified > $1.modified }
    }

    var body: some View {
        List {
            if !audio.jobs.isEmpty {
                SwiftUI.Section("MP3 from YouTube") {
                    ForEach(audio.jobs) { AudioJobRow(job: $0) }
                }
            }
            if !browser.downloads.isEmpty {
                SwiftUI.Section("From the Browser") {
                    ForEach(browser.downloads) { WebDownloadRow(item: $0) }
                }
            }
            SwiftUI.Section("Saved on this iPad") {
                if files.isEmpty {
                    Text("Downloads you save appear here and stay available offline.").foregroundStyle(.secondary)
                }
                ForEach(files) { i in NavigationLink(value: i) { FileRow(item: i) }.itemActions(i) }
            }
        }
        .navigationTitle("Downloads")
        .refreshable { library.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showAudio = true } label: { Label("Save Audio as MP3", systemImage: "music.note") }
                Button("Clear Finished") { audio.clearFinished(); browser.clearFinished() }
                    .disabled(audio.jobs.allSatisfy { $0.phase.isActive } && browser.downloads.allSatisfy { $0.isActive })
            }
        }
        .sheet(isPresented: $showAudio) { SaveAudioSheet(initialLink: "") }
    }
}

struct AudioJobRow: View {
    @EnvironmentObject var audio: AudioDownloadManager
    @EnvironmentObject var library: LibraryStore
    @ObservedObject var job: AudioJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "music.note").foregroundStyle(.pink)
                Text(job.title).lineLimit(2)
                Spacer()
                if job.phase.isActive {
                    Button("Cancel", role: .cancel) { audio.cancel(job) }.buttonStyle(.bordered)
                }
            }
            switch job.phase {
            case .finding: HStack { ProgressView(); Text("Finding the audio…").foregroundStyle(.secondary) }
            case .downloading(let p): ProgressView(value: p) { Text("Downloading audio · \(Int(p * 100))%").font(.caption) }
            case .converting(let p): ProgressView(value: p) { Text("Converting to MP3 (\(job.bitrate) kbps) · \(Int(p * 100))% · keep the app open").font(.caption) }
            case .finished(let path): Label("Saved to \((path as NSString).deletingLastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            case .cancelled: Text("Cancelled").foregroundStyle(.secondary).font(.callout)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WebDownloadRow: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var item: WebDownload
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.down.doc").foregroundStyle(.blue)
                Text(item.name).lineLimit(2)
                Spacer()
                if item.isActive { Button("Cancel", role: .cancel) { browser.cancel(item) }.buttonStyle(.bordered) }
            }
            switch item.state {
            case .running(let p): ProgressView(value: p) { Text("\(Int(p * 100))%").font(.caption) }
            case .finished(let path): Label("Saved to \((path as NSString).deletingLastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            case .cancelled: Text("Cancelled").foregroundStyle(.secondary).font(.callout)
            }
        }.padding(.vertical, 4)
    }
}
