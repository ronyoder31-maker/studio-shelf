import Foundation
import UIKit
import AVFoundation

/// Original sample files for trying the app (launch with `-demo`). Only added once, never over real files.
@MainActor
enum DemoLibrary {
    static func seed(into store: LibraryStore) {
        guard let fs = store.fs else { return }
        let marker = fs.store.folder.appendingPathComponent("demo-seeded")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        do {
            let docs = try fs.ensureFolder("Documents")
            try "Packing list\n\n• iPad charger\n• Headphones\n• Movies downloaded to On My iPad\n".write(to: SafePaths.uniqueURL(in: docs, name: "Travel Notes.txt"), atomically: true, encoding: .utf8)
            let pr = try fs.ensureFolder("Printables/Snow Globe Craft (sample)")
            try makePDF(title: "Snow Globe Multiplication", lines: ["3 × 4 = ____", "6 × 7 = ____", "8 × 5 = ____", "9 × 3 = ____"], to: SafePaths.uniqueURL(in: pr, name: "Worksheet.pdf"))
            try makePDF(title: "Answer Key", lines: ["3 × 4 = 12", "6 × 7 = 42", "8 × 5 = 40", "9 × 3 = 27"], to: SafePaths.uniqueURL(in: pr, name: "Answer Key.pdf"))
            try "Title: Snow Globe Multiplication (sample)\nGrade: 3\nStatus: Draft\n".write(to: SafePaths.uniqueURL(in: pr, name: "Listing.txt"), atomically: true, encoding: .utf8)
            let media = try fs.ensureFolder("Media")
            try makeTone(to: SafePaths.uniqueURL(in: media, name: "Demo Tone (stereo).m4a"), seconds: 8)
            try FileManager.default.createDirectory(at: fs.store.folder, withIntermediateDirectories: true)
            try Data().write(to: marker)
            store.refresh()
        } catch {
            store.errorMessage = "Couldn't add the demo files."
        }
    }

    nonisolated static func makePDF(title: String, lines: [String], to url: URL) throws {
        let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try r.writePDF(to: url) { ctx in
            ctx.beginPage()
            (title as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30)])
            for (i, l) in lines.enumerated() {
                (l as NSString).draw(at: CGPoint(x: 80, y: 150 + i * 70), withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
            }
            ("Made with StudioShelf demo data" as NSString).draw(at: CGPoint(x: 60, y: 740), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray])
        }
    }

    /// A gentle two-note stereo tone encoded as AAC, generated on the device.
    nonisolated static func makeTone(to url: URL, seconds: Double, sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = AVAudioFrameCount(seconds * sampleRate)
        let chunk: AVAudioFrameCount = 4096
        var written: AVAudioFrameCount = 0
        let fmt = file.processingFormat
        while written < total {
            let n = min(chunk, total - written)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
            buf.frameLength = n
            for c in 0..<Int(fmt.channelCount) {
                let p = buf.floatChannelData![c]
                let f = c == 0 ? 440.0 : 660.0
                for i in 0..<Int(n) {
                    let t = Double(Int(written) + i) / sampleRate
                    p[i] = Float(0.3 * sin(2 * .pi * f * t))
                }
            }
            try file.write(from: buf)
            written += n
        }
    }
}
