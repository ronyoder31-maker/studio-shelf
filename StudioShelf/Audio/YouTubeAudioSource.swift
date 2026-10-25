import Foundation
import YouTubeKit

/// Finds a directly downloadable audio-only AAC (M4A) stream for one video, on this device only.
/// The remote fallback offered by YouTubeKit is never enabled: `methods` is always `[.local]`.
public enum YouTubeAudioSource {
    public struct Found {
        public let streamURL: URL
        public let title: String
        public let author: String?
        public let bitrate: Int?
    }

    public enum Failure: LocalizedError {
        case extraction(String)
        case noCompatibleStream
        public var errorDescription: String? {
            switch self {
            case .extraction: return "YouTube didn't provide this video's audio to the app. The video may be private, age-restricted, or YouTube may have changed how it delivers audio."
            case .noCompatibleStream: return "This video doesn't offer an audio format the iPad can convert."
            }
        }
    }

    public static func find(videoID: String) async throws -> Found {
        let video = YouTube(videoID: videoID, methods: [.local])
        let streams: [YouTubeKit.Stream]
        do { streams = try await video.streams } catch {
            if error is CancellationError { throw error }
            throw Failure.extraction(String(describing: error))
        }
        let audio = streams.filter { s in
            guard s.includesAudioTrack, !s.includesVideoTrack else { return false }
            if case .mp4a = s.audioCodec { return true }
            return s.fileExtension == .m4a
        }
        guard let best = audio.max(by: { ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0) }) else {
            throw Failure.noCompatibleStream
        }
        var title = videoID
        if let meta = try? await video.metadata, !meta.title.isEmpty { title = meta.title }
        return Found(streamURL: best.url, title: title, author: nil, bitrate: best.averageBitrate ?? best.bitrate)
    }
}
