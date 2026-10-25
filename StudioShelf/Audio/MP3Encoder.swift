import Foundation
import AVFoundation
import lame

public enum MP3Error: LocalizedError, Equatable {
    case cannotOpenSource
    case emptySource
    case encoderSetup
    case encodeFailed(Int32)
    case writeFailed
    case cancelled
    case outputInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenSource: return "The downloaded audio couldn't be opened. It may be damaged or in a format this iPad can't decode."
        case .emptySource: return "The downloaded audio is empty."
        case .encoderSetup: return "The MP3 converter couldn't start with this audio's settings."
        case .encodeFailed: return "Converting to MP3 failed partway through."
        case .writeFailed: return "The MP3 couldn't be saved. Your iPad may be out of storage."
        case .cancelled: return "Cancelled."
        case .outputInvalid(let why): return "The finished MP3 didn't pass checks (\(why))."
        }
    }
}

public struct MP3Options {
    public var bitrateKbps: Int32 = 192
    public var title: String? = nil
    public var artist: String? = nil
    public init(bitrateKbps: Int32 = 192, title: String? = nil, artist: String? = nil) {
        self.bitrateKbps = bitrateKbps; self.title = title; self.artist = artist
    }
}

/// Converts any audio file the system can decode (AAC/M4A, WAV, AIFF, CAF, ALAC…) into a real
/// MPEG-1/2 Layer III file using LAME, reading and encoding in small chunks so long recordings
/// never sit in memory all at once. Runs entirely on the device.
public enum MP3Encoder {
    public static let chunkFrames: AVAudioFrameCount = 8192

    public static func encode(source: URL, destination: URL, options: MP3Options,
                              progress: (Double) -> Void = { _ in },
                              isCancelled: () -> Bool = { false }) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source) } catch { throw MP3Error.cannotOpenSource }
        let inFormat = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, inFormat.channelCount > 0 else { throw MP3Error.emptySource }

        let channels: AVAudioChannelCount = inFormat.channelCount >= 2 ? 2 : 1
        // LAME accepts up to 48 kHz input; higher rates are resampled first.
        let outRate: Double = inFormat.sampleRate > 48_000 ? 48_000 : inFormat.sampleRate
        guard outRate >= 8_000,
              let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: channels, interleaved: false)
        else { throw MP3Error.encoderSetup }

        guard let gf = lame_init() else { throw MP3Error.encoderSetup }
        defer { lame_close(gf) }
        lame_set_in_samplerate(gf, Int32(outRate))
        lame_set_out_samplerate(gf, Int32(outRate))
        lame_set_num_channels(gf, Int32(channels))
        lame_set_mode(gf, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(gf, vbr_off)
        lame_set_brate(gf, options.bitrateKbps)
        lame_set_quality(gf, 2)
        lame_set_write_id3tag_automatic(gf, 0)   // we write a UTF-16 ID3v2 tag ourselves
        lame_set_bWriteVbrTag(gf, 0)
        guard lame_init_params(gf) >= 0 else { throw MP3Error.encoderSetup }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil),
              let out = try? FileHandle(forWritingTo: destination) else { throw MP3Error.writeFailed }
        var finished = false
        defer {
            try? out.close()
            if !finished { try? fm.removeItem(at: destination) }
        }
        func write(_ d: Data) throws {
            do { try out.write(contentsOf: d) } catch { throw MP3Error.writeFailed }
        }
        try write(ID3.v2Tag(title: options.title, artist: options.artist))

        let reader = PCMReader(file: file, outFormat: pcmFormat)
        var mp3buf = [UInt8](repeating: 0, count: Int(Double(chunkFrames) * 1.25 * (outRate / min(outRate, inFormat.sampleRate)) + 7200) * 2)
        var produced: Int64 = 0
        while true {
            if isCancelled() { throw MP3Error.cancelled }
            guard let buf = try reader.next() else { break }
            let n = Int32(buf.frameLength)
            if n == 0 { continue }
            guard let ch = buf.floatChannelData else { throw MP3Error.cannotOpenSource }
            let left = ch[0]
            let right = channels == 2 ? ch[1] : ch[0]
            let needed = Int(Double(n) * 1.25) + 7200
            if mp3buf.count < needed { mp3buf = [UInt8](repeating: 0, count: needed) }
            let written = mp3buf.withUnsafeMutableBufferPointer { p in
                lame_encode_buffer_ieee_float(gf, left, right, n, p.baseAddress, Int32(p.count))
            }
            if written < 0 { throw MP3Error.encodeFailed(written) }
            if written > 0 { try write(Data(mp3buf[0..<Int(written)])) }
            produced += Int64(n)
            progress(min(1, Double(produced) / (Double(totalFrames) * outRate / inFormat.sampleRate)))
        }
        if produced == 0 { throw MP3Error.emptySource }
        let tail = mp3buf.withUnsafeMutableBufferPointer { p in lame_encode_flush(gf, p.baseAddress, Int32(p.count)) }
        if tail < 0 { throw MP3Error.encodeFailed(tail) }
        if tail > 0 { try write(Data(mp3buf[0..<Int(tail)])) }
        do { try out.synchronize() } catch { throw MP3Error.writeFailed }
        finished = true
        progress(1)
    }
}

/// Pulls float PCM chunks from an audio file, converting sample rate or channel layout only when needed.
final class PCMReader {
    let file: AVAudioFile
    let outFormat: AVAudioFormat
    let converter: AVAudioConverter?
    let inBuffer: AVAudioPCMBuffer
    var sourceDone = false
    var readError: Error?

    init(file: AVAudioFile, outFormat: AVAudioFormat) {
        self.file = file
        self.outFormat = outFormat
        let inF = file.processingFormat
        let same = inF.sampleRate == outFormat.sampleRate && inF.channelCount == outFormat.channelCount
            && inF.commonFormat == .pcmFormatFloat32 && !inF.isInterleaved
        converter = same ? nil : AVAudioConverter(from: inF, to: outFormat)
        if inF.channelCount > 2 { converter?.downmix = true }
        inBuffer = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: MP3Encoder.chunkFrames)!
    }

    func next() throws -> AVAudioPCMBuffer? {
        guard let converter else {
            if sourceDone { return nil }
            do { try file.read(into: inBuffer, frameCount: MP3Encoder.chunkFrames) } catch { throw MP3Error.cannotOpenSource }
            if inBuffer.frameLength == 0 { sourceDone = true; return nil }
            return inBuffer
        }
        let ratio = outFormat.sampleRate / file.processingFormat.sampleRate
        let cap = AVAudioFrameCount(Double(MP3Encoder.chunkFrames) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { throw MP3Error.encoderSetup }
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { [self] _, statusPtr in
            if sourceDone { statusPtr.pointee = .endOfStream; return nil }
            do { try file.read(into: inBuffer, frameCount: MP3Encoder.chunkFrames) } catch {
                readError = error; sourceDone = true; statusPtr.pointee = .endOfStream; return nil
            }
            if inBuffer.frameLength == 0 { sourceDone = true; statusPtr.pointee = .endOfStream; return nil }
            statusPtr.pointee = .haveData
            return inBuffer
        }
        if readError != nil || status == .error { throw MP3Error.cannotOpenSource }
        if out.frameLength == 0 && (status == .endOfStream || sourceDone) { return nil }
        return out
    }
}

/// Minimal ID3v2.3 writer/reader for title and artist, using UTF-16 so any language works.
public enum ID3 {
    public static func v2Tag(title: String?, artist: String?) -> Data {
        var frames = Data()
        func frame(_ id: String, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            var body = Data([0x01])                    // UTF-16 with BOM
            body.append(contentsOf: [0xFF, 0xFE])
            body.append(text.data(using: .utf16LittleEndian)!)
            body.append(contentsOf: [0, 0])
            frames.append(id.data(using: .ascii)!)
            let s = UInt32(body.count)
            frames.append(contentsOf: [UInt8(s >> 24 & 0xFF), UInt8(s >> 16 & 0xFF), UInt8(s >> 8 & 0xFF), UInt8(s & 0xFF)])
            frames.append(contentsOf: [0, 0])
            frames.append(body)
        }
        frame("TIT2", title); frame("TPE1", artist); frame("TSSE", "StudioShelf (LAME)")
        let size = frames.count
        var tag = Data("ID3".utf8); tag.append(contentsOf: [3, 0, 0])
        tag.append(contentsOf: [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)])
        tag.append(frames)
        return tag
    }

    /// Returns (tag length including header, title) if the data starts with an ID3v2 tag.
    public static func read(_ d: Data) -> (length: Int, title: String?)? {
        guard d.count >= 10, d.prefix(3) == Data("ID3".utf8) else { return nil }
        let b = [UInt8](d.prefix(10))
        let size = Int(b[6]) << 21 | Int(b[7]) << 14 | Int(b[8]) << 7 | Int(b[9])
        let total = 10 + size
        var i = 10; var title: String?
        let bytes = [UInt8](d.prefix(min(d.count, total)))
        while i + 10 <= bytes.count {
            let id = String(bytes: bytes[i..<i+4], encoding: .ascii) ?? ""
            let fs = Int(bytes[i+4]) << 24 | Int(bytes[i+5]) << 16 | Int(bytes[i+6]) << 8 | Int(bytes[i+7])
            if fs <= 0 || i + 10 + fs > bytes.count { break }
            if id == "TIT2" {
                let body = Array(bytes[(i+10)..<(i+10+fs)])
                if body.first == 1 {
                    var txt = Data(body.dropFirst())
                    while txt.count >= 2 && txt.suffix(2) == Data([0, 0]) { txt.removeLast(2) }
                    title = String(data: txt, encoding: .utf16)
                } else { title = String(bytes: body.dropFirst(), encoding: .isoLatin1) }
            }
            i += 10 + fs
        }
        return (total, title)
    }
}

/// Inspects actual MPEG audio frame headers, so ".mp3" files are checked by content, not name.
public struct MP3Inspection: Equatable {
    public var mpegVersion: String
    public var layer: Int
    public var bitrateKbps: Int
    public var sampleRate: Int
    public var channels: Int
    public var frameCount: Int
    public var title: String?
}

public enum MP3Inspector {
    static let rates: [String: [Int]] = ["1": [44100, 48000, 32000], "2": [22050, 24000, 16000], "2.5": [11025, 12000, 8000]]
    static let br1: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    static let br2: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    public static func inspect(_ url: URL) throws -> MP3Inspection {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        let bytes = [UInt8](d)
        let id3 = ID3.read(d)
        var i = id3?.length ?? 0
        var first: MP3Inspection?
        var frames = 0
        while i + 4 <= bytes.count {
            guard bytes[i] == 0xFF, bytes[i+1] & 0xE0 == 0xE0 else {
                if frames == 0 { i += 1; if i > (id3?.length ?? 0) + 4096 { break }; continue } else { break }
            }
            let verBits = (bytes[i+1] >> 3) & 3, layerBits = (bytes[i+1] >> 1) & 3
            let brIdx = Int(bytes[i+2] >> 4), srIdx = Int((bytes[i+2] >> 2) & 3), pad = Int((bytes[i+2] >> 1) & 1)
            let mode = Int(bytes[i+3] >> 6)
            guard verBits != 1, layerBits == 1, brIdx > 0, brIdx < 15, srIdx < 3 else {
                if frames == 0 { i += 1; continue } else { break }
            }
            let ver = verBits == 3 ? "1" : (verBits == 2 ? "2" : "2.5")
            let sr = rates[ver]![srIdx]
            let br = (ver == "1" ? br1 : br2)[brIdx]
            let len = ver == "1" ? 144_000 * br / sr + pad : 72_000 * br / sr + pad
            if first == nil { first = MP3Inspection(mpegVersion: ver, layer: 3, bitrateKbps: br, sampleRate: sr, channels: mode == 3 ? 1 : 2, frameCount: 0, title: id3?.title) }
            frames += 1
            if len <= 4 { break }
            i += len
        }
        guard var r = first, frames >= 2 else { throw MP3Error.outputInvalid("no MPEG Layer III audio frames") }
        r.frameCount = frames
        return r
    }
}
