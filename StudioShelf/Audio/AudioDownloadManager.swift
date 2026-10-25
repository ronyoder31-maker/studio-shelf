import Foundation
import AVFoundation
import UIKit

/// Downloads a stream in byte ranges into a local file, validating each HTTP response.
enum RangedDownloader {
    static let chunk: Int64 = 10 * 1024 * 1024

    enum Failure: LocalizedError {
        case refused(Int), notMedia, empty, network
        var errorDescription: String? {
            switch self {
            case .refused(let code): return code == 403 || code == 410
                ? "YouTube refused or expired the audio link (\(code)). Try again in a moment."
                : "The audio server answered with an error (\(code))."
            case .notMedia: return "The server sent a web page instead of audio."
            case .empty: return "The server sent no audio."
            case .network: return "The connection was interrupted. Check your internet and try again."
            }
        }
    }

    static func download(_ url: URL, to file: URL, session: URLSession = .shared,
                         progress: @escaping (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var start: Int64 = 0
        var total: Int64? = nil
        while true {
            try Task.checkCancellation()
            var req = URLRequest(url: url)
            req.setValue("bytes=\(start)-\(start + chunk - 1)", forHTTPHeaderField: "Range")
            req.timeoutInterval = 30
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) }
            catch { if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }; throw Failure.network }
            guard let http = resp as? HTTPURLResponse else { throw Failure.network }
            if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), type.contains("text/html") { throw Failure.notMedia }
            switch http.statusCode {
            case 206:
                if total == nil, let cr = http.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") {
                    total = Int64(cr[cr.index(after: slash)...])
                }
            case 200:
                // Whole file in one response.
                if data.isEmpty { throw Failure.empty }
                try handle.write(contentsOf: data)
                progress(1); return
            case 416 where start > 0 && total == nil:
                progress(1); return
            default:
                throw Failure.refused(http.statusCode)
            }
            if data.isEmpty { if start == 0 { throw Failure.empty }; break }
            try handle.write(contentsOf: data)
            start += Int64(data.count)
            if let total { progress(min(1, Double(start) / Double(max(total, 1)))) }
            if let total, start >= total { break }
            if total == nil && Int64(data.count) < chunk { break }
        }
        if start == 0 { throw Failure.empty }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class AudioJob: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case finding, downloading(Double), converting(Double), finished(path: String), failed(String), cancelled
        var isActive: Bool { switch self { case .finding, .downloading, .converting: return true; default: return false } }
    }
    let id = UUID()
    let videoID: String
    let bitrate: Int32
    @Published var title: String
    @Published var phase: Phase = .finding
    var task: Task<Void, Never>?
    init(videoID: String, bitrate: Int32) { self.videoID = videoID; self.bitrate = bitrate; self.title = "YouTube video \(videoID)" }
}

/// Orchestrates YouTube → local AAC → MP3 on this iPad. Nothing is sent to a Mac or a conversion service.
@MainActor
final class AudioDownloadManager: ObservableObject {
    static let bitrates: [Int32] = [192, 256, 320]
    static let destinationFolder = "Downloads/Audio"

    @Published var jobs: [AudioJob] = []
    weak var library: LibraryStore?

    /// Returns an error message when the link can't be used.
    @discardableResult
    func start(linkText: String, bitrate: Int32) -> String? {
        switch YouTubeLink.parse(linkText) {
        case .failure(let r): return r.message
        case .success(let link):
            guard let library, let fs = library.fs else { return "Choose a library folder first." }
            if jobs.contains(where: { $0.videoID == link.videoID && $0.phase.isActive }) { return "That video is already being saved." }
            let job = AudioJob(videoID: link.videoID, bitrate: bitrate)
            jobs.insert(job, at: 0)
            job.task = Task { await self.run(job, fs: fs) }
            return nil
        }
    }

    func cancel(_ job: AudioJob) { job.task?.cancel() }
    func remove(_ job: AudioJob) { if !job.phase.isActive { jobs.removeAll { $0.id == job.id } } }
    func clearFinished() { jobs.removeAll { !$0.phase.isActive } }

    private func run(_ job: AudioJob, fs: LibraryFS) async {
        var work: URL?
        let bg = UIApplication.shared.beginBackgroundTask(withName: "Save audio") {}
        defer {
            if let work { try? FileManager.default.removeItem(at: work) }
            UIApplication.shared.endBackgroundTask(bg)
        }
        do {
            let found = try await YouTubeAudioSource.find(videoID: job.videoID)
            job.title = found.title
            let dir = try fs.makeWorkFolder(); work = dir
            let source = dir.appendingPathComponent("source.m4a")
            let output = dir.appendingPathComponent("output.mp3")
            job.phase = .downloading(0)
            try await RangedDownloader.download(found.streamURL, to: source) { p in
                Task { @MainActor in if case .downloading = job.phase { job.phase = .downloading(p) } }
            }
            job.phase = .converting(0)
            let flag = CancelFlag()
            let opts = MP3Options(bitrateKbps: job.bitrate, title: found.title, artist: found.author)
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try MP3Encoder.encode(source: source, destination: output, options: opts, progress: { p in
                        Task { @MainActor in if case .converting = job.phase { job.phase = .converting(p) } }
                    }, isCancelled: { flag.isSet })
                }.value
            } onCancel: { flag.set() }
            try Task.checkCancellation()
            // Validate the actual bytes before anything appears in the library.
            let info = try MP3Inspector.inspect(output)
            let check = try AVAudioFile(forReading: output)
            guard check.length > 0, info.layer == 3 else { throw MP3Error.outputInvalid("no playable audio") }
            let rel = try fs.publish(output, into: Self.destinationFolder, preferredName: found.title + ".mp3")
            job.phase = .finished(path: rel)
            library?.refresh()
        } catch is CancellationError {
            job.phase = .cancelled
        } catch MP3Error.cancelled {
            job.phase = .cancelled
        } catch {
            job.phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong while saving this audio.")
        }
    }
}
