import Foundation

/// Recognizes a link to one YouTube video and normalizes it.
/// Playlist and channel links are rejected; a `list=` parameter on a watch link is ignored
/// so only that single video is ever retrieved.
public struct YouTubeLink: Equatable {
    public let videoID: String
    public var normalizedURL: URL { URL(string: "https://www.youtube.com/watch?v=\(videoID)")! }

    public enum Rejection: Error, Equatable {
        case notALink, notYouTube, playlistOrChannel, noVideoID
        public var message: String {
            switch self {
            case .notALink: return "That doesn't look like a web link."
            case .notYouTube: return "That link isn't a YouTube video."
            case .playlistOrChannel: return "That's a playlist or channel. Paste the link to a single video."
            case .noVideoID: return "That YouTube link doesn't point to a specific video."
            }
        }
    }

    static let youtubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
                                           "youtube-nocookie.com", "www.youtube-nocookie.com"]

    public static func isValidID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func parse(_ raw: String) -> Result<YouTubeLink, Rejection> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.contains(" ") { return .failure(.notALink) }
        if let r = text.range(of: "://"), !["http", "https"].contains(text[..<r.lowerBound].lowercased()) { return .failure(.notALink) }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        guard let comps = URLComponents(string: text), let hostRaw = comps.host?.lowercased(),
              comps.scheme == "https" || comps.scheme == "http" else { return .failure(.notALink) }
        let host = hostRaw
        let parts = comps.path.split(separator: "/").map(String.init)
        func q(_ name: String) -> String? { comps.queryItems?.first(where: { $0.name == name })?.value }

        if host == "youtu.be" || host == "www.youtu.be" {
            guard let first = parts.first, isValidID(first) else { return .failure(.noVideoID) }
            return .success(YouTubeLink(videoID: first))
        }
        guard youtubeHosts.contains(host) else { return .failure(.notYouTube) }
        guard let first = parts.first?.lowercased() else { return .failure(.noVideoID) }
        switch first {
        case "watch":
            guard let v = q("v"), isValidID(v) else { return q("list") != nil ? .failure(.playlistOrChannel) : .failure(.noVideoID) }
            return .success(YouTubeLink(videoID: v))
        case "shorts", "embed", "live", "v", "e":
            guard parts.count >= 2, isValidID(parts[1]) else { return .failure(.noVideoID) }
            if parts[1] == "videoseries" { return .failure(.playlistOrChannel) }
            return .success(YouTubeLink(videoID: parts[1]))
        case "playlist", "channel", "c", "user", "results", "feed":
            return .failure(.playlistOrChannel)
        default:
            if first.hasPrefix("@") { return .failure(.playlistOrChannel) }
            return .failure(.noVideoID)
        }
    }
}
