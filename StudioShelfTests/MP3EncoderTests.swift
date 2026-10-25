import XCTest
import AVFoundation
@testable import StudioShelf

final class MP3EncoderTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func makeSource(name: String, aac: Bool, rate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if aac {
            try DemoLibrary.makeTone(to: url, seconds: seconds, sampleRate: rate, channels: channels)
        } else {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let n = AVAudioFrameCount(seconds * rate)
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!; b.frameLength = n
            for c in 0..<Int(channels) { for i in 0..<Int(n) { b.floatChannelData![c][i] = Float(0.25 * sin(2 * .pi * 330 * Double(i) / rate)) } }
            try f.write(from: b)
        }
        return url
    }

    func checkMP3(_ out: URL, rate: Int, channels: Int, seconds: Double, bitrate: Int, title: String) throws -> MP3Inspection {
        let info = try MP3Inspector.inspect(out)
        XCTAssertEqual(info.layer, 3)
        XCTAssertEqual(info.sampleRate, rate)
        XCTAssertEqual(info.channels, channels)
        XCTAssertEqual(info.bitrateKbps, bitrate)
        XCTAssertEqual(info.title, title)
        // Decode with the system's own MP3 decoder.
        let f = try AVAudioFile(forReading: out)
        let dur = Double(f.length) / f.fileFormat.sampleRate
        XCTAssertEqual(dur, seconds, accuracy: 0.2)
        XCTAssertEqual(Int(f.fileFormat.channelCount), channels)
        let desc = f.fileFormat.streamDescription.pointee
        XCTAssertEqual(desc.mFormatID, kAudioFormatMPEGLayer3)
        print("MP3CHECK \(out.lastPathComponent): MPEG-\(info.mpegVersion) Layer \(info.layer), \(info.sampleRate) Hz, \(info.channels) ch, \(info.bitrateKbps) kbps, \(String(format: "%.2f", dur)) s, frames \(info.frameCount), title \(info.title ?? "-")")
        return info
    }

    func testStereoAACto320() throws {
        let src = try makeSource(name: "stereo.m4a", aac: true, rate: 44_100, channels: 2, seconds: 5)
        let out = dir.appendingPathComponent("stereo.mp3")
        let title = "Grüße aus Kaiserslautern 🎵 — テスト"
        var last = 0.0
        try MP3Encoder.encode(source: src, destination: out, options: MP3Options(bitrateKbps: 320, title: title), progress: { last = $0 })
        XCTAssertEqual(last, 1, accuracy: 0.0001)
        _ = try checkMP3(out, rate: 44_100, channels: 2, seconds: 5, bitrate: 320, title: title)
    }

    func testMonoAAC48kTo192() throws {
        let src = try makeSource(name: "mono.m4a", aac: true, rate: 48_000, channels: 1, seconds: 4)
        let out = dir.appendingPathComponent("mono.mp3")
        try MP3Encoder.encode(source: src, destination: out, options: MP3Options(bitrateKbps: 192, title: "Mono"))
        _ = try checkMP3(out, rate: 48_000, channels: 1, seconds: 4, bitrate: 192, title: "Mono")
    }

    func testStereoPCM22kTo128() throws {
        // 22.05 kHz uses MPEG-2 Layer III, where 128 kbps is a valid rate.
        let src = try makeSource(name: "pcm.wav", aac: false, rate: 22_050, channels: 2, seconds: 3)
        let out = dir.appendingPathComponent("pcm.mp3")
        try MP3Encoder.encode(source: src, destination: out, options: MP3Options(bitrateKbps: 128, title: "PCM"))
        let info = try checkMP3(out, rate: 22_050, channels: 2, seconds: 3, bitrate: 128, title: "PCM")
        XCTAssertEqual(info.mpegVersion, "2")
    }

    func testHighSampleRateIsResampled() throws {
        let src = try makeSource(name: "hi.wav", aac: false, rate: 96_000, channels: 2, seconds: 2)
        let out = dir.appendingPathComponent("hi.mp3")
        try MP3Encoder.encode(source: src, destination: out, options: MP3Options(bitrateKbps: 256, title: "Hi"))
        _ = try checkMP3(out, rate: 48_000, channels: 2, seconds: 2, bitrate: 256, title: "Hi")
    }

    func testEmptyAndCorruptSourcesFailCleanly() throws {
        let empty = dir.appendingPathComponent("empty.m4a"); try Data().write(to: empty)
        let junk = dir.appendingPathComponent("junk.m4a"); try Data((0..<5000).map { UInt8($0 % 251) }).write(to: junk)
        for src in [empty, junk] {
            let out = dir.appendingPathComponent(src.lastPathComponent + ".mp3")
            XCTAssertThrowsError(try MP3Encoder.encode(source: src, destination: out, options: MP3Options()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no partial output left behind")
        }
    }

    func testCancellationRemovesPartialOutput() throws {
        let src = try makeSource(name: "long.m4a", aac: true, rate: 44_100, channels: 2, seconds: 20)
        let out = dir.appendingPathComponent("long.mp3")
        var calls = 0
        XCTAssertThrowsError(try MP3Encoder.encode(source: src, destination: out, options: MP3Options(), isCancelled: { calls += 1; return calls > 5 })) {
            XCTAssertEqual($0 as? MP3Error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testRenamedFileIsNotAcceptedAsMP3() throws {
        let src = try makeSource(name: "fake.m4a", aac: true, rate: 44_100, channels: 2, seconds: 1)
        let fake = dir.appendingPathComponent("fake.mp3")
        try FileManager.default.copyItem(at: src, to: fake)
        XCTAssertThrowsError(try MP3Inspector.inspect(fake))
    }
}

/// Live network test against YouTube using on-device extraction only. Network access and YouTube's
/// behavior vary, so CI runs this separately and reports the outcome rather than gating the build on it.
final class LiveExtractionTests: XCTestCase {
    func testOnDeviceExtractionAndConversion() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_YOUTUBE"] == "1" || ProcessInfo.processInfo.arguments.contains("-liveYouTube") else {
            throw XCTSkip("Live YouTube test runs only when requested.")
        }
        let id = "jNQXAC9IVRw" // "Me at the zoo", the first YouTube video (19 s), widely used as a public test sample
        // Diagnostic: does YouTube treat this network as a bot? (Datacenter addresses often get a sign-in wall.)
        if let (d, r) = try? await URLSession.shared.data(from: URL(string: "https://www.youtube.com/watch?v=\(id)")!) {
            let html = String(decoding: d, as: UTF8.self)
            print("LIVE watch page status=\((r as? HTTPURLResponse)?.statusCode ?? 0) botWall=\(html.contains("not a bot")) loginRequired=\(html.contains("LOGIN_REQUIRED")) playable=\(html.contains("\"status\":\"OK\""))")
            if let range = html.range(of: "\"playabilityStatus\":{") {
                print("LIVE playability: " + html[range.lowerBound...].prefix(300))
            }
        }
        let found: YouTubeAudioSource.Found
        do { found = try await YouTubeAudioSource.find(videoID: id) } catch { print("LIVE extraction error: \(error)"); throw error }
        print("LIVE found title=\(found.title) bitrate=\(found.bitrate ?? 0)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("source.m4a")
        try await RangedDownloader.download(found.streamURL, to: src) { _ in }
        let size = (try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int) ?? 0
        print("LIVE downloaded bytes=\(size)")
        let out = dir.appendingPathComponent("out.mp3")
        try MP3Encoder.encode(source: src, destination: out, options: MP3Options(bitrateKbps: 192, title: found.title))
        let info = try MP3Inspector.inspect(out)
        let f = try AVAudioFile(forReading: out)
        print("LIVE mp3 \(info.sampleRate) Hz \(info.channels) ch \(info.bitrateKbps) kbps duration \(Double(f.length) / f.fileFormat.sampleRate) s")
        XCTAssertGreaterThan(f.length, 0)
    }
}
