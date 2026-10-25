import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @EnvironmentObject var browser: BrowserModel
    @EnvironmentObject var audio: AudioDownloadManager
    @State private var editing = ""
    @FocusState private var addressFocused: Bool
    @State private var showAudio = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            if browser.isLoading { ProgressView(value: browser.progress).progressViewStyle(.linear).tint(.accentColor) }
            WebViewContainer(webView: browser.webView)
            if let n = browser.notice {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(n).font(.callout).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { browser.notice = nil }
                }
                .padding(10).background(.regularMaterial)
            }
        }
        .navigationTitle(browser.title.isEmpty ? "Browser" : browser.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { browser.saveCurrentFile() } label: { Label("Save This File", systemImage: "square.and.arrow.down") }
                    .disabled(!browser.currentIsSavableFile)
                    .help("Save the PDF, picture, audio or video shown on this page")
                Button { showAudio = true } label: { Label("Save Audio as MP3", systemImage: "music.note") }
                    .help("Save a YouTube video's audio as an MP3")
            }
        }
        .sheet(isPresented: $showAudio) {
            SaveAudioSheet(initialLink: browser.currentYouTubeLink?.normalizedURL.absoluteString ?? "")
        }
        .onChange(of: browser.address) { _, new in if !addressFocused { editing = new } }
        .onAppear { editing = browser.address }
    }

    var bar: some View {
        HStack(spacing: 14) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!browser.canGoBack).accessibilityLabel("Back")
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!browser.canGoForward).accessibilityLabel("Forward")
            TextField("Search or enter website", text: $editing)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($addressFocused)
                .submitLabel(.go)
                .onSubmit { browser.go(editing); addressFocused = false }
            Button {
                browser.isLoading ? browser.webView.stopLoading() : browser.webView.reload()
            } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }
                .accessibilityLabel(browser.isLoading ? "Stop" : "Reload")
            if browser.currentYouTubeLink != nil {
                Button { showAudio = true } label: { Label("MP3", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Save audio as MP3")
            }
        }
        .font(.title3)
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

/// Paste or confirm a YouTube link, pick a bitrate, and start the on-device conversion.
struct SaveAudioSheet: View {
    @EnvironmentObject var audio: AudioDownloadManager
    @Environment(\.dismiss) private var dismiss
    @State var link: String
    @AppStorage("mp3Bitrate") private var bitrate: Int = 192
    @State private var error: String?

    init(initialLink: String) { _link = State(initialValue: initialLink) }

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    TextField("YouTube video link", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Paste Link") { if let s = UIPasteboard.general.string { link = s } }
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                SwiftUI.Section {
                    Picker("MP3 quality", selection: $bitrate) {
                        ForEach(AudioDownloadManager.bitrates, id: \.self) { Text("\($0) kbps").tag(Int($0)) }
                    }
                } footer: {
                    Text("Higher numbers make bigger files. They can't add quality the video didn't have; 192 kbps is plenty for most listening.")
                }
                SwiftUI.Section {
                    Text("Your iPad downloads the audio straight from YouTube and converts it to MP3 itself. Keep \(AppInfo.name) open until it finishes. The MP3 is saved in Downloads › Audio and plays without internet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Save Audio as MP3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let e = audio.start(linkText: link, bitrate: Int32(bitrate)) { error = e } else { dismiss() }
                    }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
