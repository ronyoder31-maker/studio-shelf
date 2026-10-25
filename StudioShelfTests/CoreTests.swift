import XCTest
@testable import StudioShelf

final class SafePathTests: XCTestCase {
    var root: URL!
    var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ss-" + UUID().uuidString)
        root = base.appendingPathComponent("Library"); outside = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func testRejectsTraversalAndAbsolute() {
        let p = SafePaths(root: root)
        XCTAssertThrowsError(try p.resolve("../Outside/x"))
        XCTAssertThrowsError(try p.resolve("a/../../x"))
        XCTAssertThrowsError(try p.resolve("/etc/passwd"))
        XCTAssertNoThrow(try p.resolve("Downloads/new/not-yet.txt"))
        XCTAssertNoThrow(try p.resolve(""))
    }

    func testRejectsSymlinkEscapeIncludingMissingChild() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let p = SafePaths(root: root)
        XCTAssertThrowsError(try p.resolve("link"))
        XCTAssertThrowsError(try p.resolve("link/new-file.txt"))
        XCTAssertThrowsError(try p.resolve("link/deeper/missing/file.txt"))
        // A dangling link whose target is outside must not be writable through.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("nope"))
        XCTAssertThrowsError(try p.resolve("dangling"))
    }

    func testSanitizeAndUnique() throws {
        XCTAssertEqual(SafePaths.sanitizeName("a/b:c"), "a-b-c")
        XCTAssertEqual(SafePaths.sanitizeName("   "), "Untitled")
        XCTAssertEqual(SafePaths.sanitizeName("..hidden"), "hidden")
        XCTAssertEqual(SafePaths.sanitizeName("Grüße 🎵"), "Grüße 🎵")
        try Data().write(to: root.appendingPathComponent("song.mp3"))
        XCTAssertEqual(SafePaths.uniqueURL(in: root, name: "song.mp3").lastPathComponent, "song 2.mp3")
    }
}

final class LibraryTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func write(_ rel: String, _ text: String = "x") throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    func testRenameNeverOverwrites() throws {
        let fs = try LibraryFS(root: root)
        try write("a.txt", "A"); try write("b.txt", "B")
        XCTAssertThrowsError(try fs.rename("a.txt", to: "b.txt"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt")), "B")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt")), "A")
    }

    func testMetadataFollowsRenameAndMove() throws {
        let fs = try LibraryFS(root: root)
        try write("Folder/inner/song.mp3")
        try fs.setTags("Folder/inner/song.mp3", tagsText: "travel, Travel, car")
        try fs.setFavorite("Folder", true)
        XCTAssertEqual(fs.meta("Folder/inner/song.mp3").tags, ["travel", "car"])
        let renamed = try fs.rename("Folder", to: "Trip")
        XCTAssertEqual(renamed, "Trip")
        XCTAssertTrue(fs.meta("Trip").favorite)
        XCTAssertEqual(fs.meta("Trip/inner/song.mp3").tags, ["travel", "car"])
        _ = try fs.createFolder(named: "Archive", in: "")
        let moved = try fs.move("Trip/inner/song.mp3", toFolder: "Archive")
        XCTAssertEqual(moved, "Archive/song.mp3")
        XCTAssertEqual(fs.meta("Archive/song.mp3").tags, ["travel", "car"])
        // Persisted across reopen
        let again = try LibraryFS(root: root)
        XCTAssertEqual(again.meta("Archive/song.mp3").tags, ["travel", "car"])
        XCTAssertThrowsError(try fs.move("Archive", toFolder: "Archive"))
    }

    func testTrashRestoreDoesNotReplace() throws {
        let fs = try LibraryFS(root: root)
        try write("Docs/report.pdf", "old")
        try fs.setTags("Docs/report.pdf", tagsText: "keep")
        let rec = try fs.trash("Docs/report.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Docs/report.pdf").path))
        try write("Docs/report.pdf", "new")
        let restored = try fs.restore(rec.id)
        XCTAssertEqual(restored, "Docs/report 2.pdf")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Docs/report.pdf")), "new")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Docs/report 2.pdf")), "old")
        XCTAssertEqual(fs.meta("Docs/report 2.pdf").tags, ["keep"])
        XCTAssertTrue(fs.manifest.trash.isEmpty)
    }

    func testRestoreRecreatesMissingFolder() throws {
        let fs = try LibraryFS(root: root)
        try write("Gone/file.txt")
        let rec = try fs.trash("Gone/file.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone"))
        XCTAssertEqual(try fs.restore(rec.id), "Gone/file.txt")
    }

    func testCorruptMetadataIsNotOverwritten() throws {
        let meta = root.appendingPathComponent(".studioshelf")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: meta.appendingPathComponent("manifest.json"))
        try write("a.txt")
        let fs = try LibraryFS(root: root)
        XCTAssertEqual(fs.metadataError, .metadataCorrupt)
        XCTAssertThrowsError(try fs.setFavorite("a.txt", true))
        XCTAssertThrowsError(try fs.trash("a.txt"))
        XCTAssertEqual(try String(contentsOf: meta.appendingPathComponent("manifest.json")), "{ not json")
        XCTAssertEqual(try fs.list("").map(\.name), ["a.txt"])   // browsing still works
    }

    func testNewerMetadataVersionRefused() throws {
        let meta = root.appendingPathComponent(".studioshelf")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "items": {}, "trash": []}"#.utf8).write(to: meta.appendingPathComponent("manifest.json"))
        let fs = try LibraryFS(root: root)
        XCTAssertEqual(fs.metadataError, .metadataTooNew(99))
    }

    func testPublishAndImportAvoidCollisions() throws {
        let fs = try LibraryFS(root: root)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try Data("one".utf8).write(to: tmp)
        XCTAssertEqual(try fs.publish(tmp, into: "Downloads/Audio", preferredName: "Song: Live/Remix.mp3"), "Downloads/Audio/Song- Live-Remix.mp3")
        let tmp2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try Data("two".utf8).write(to: tmp2)
        XCTAssertEqual(try fs.publish(tmp2, into: "Downloads/Audio", preferredName: "Song: Live/Remix.mp3"), "Downloads/Audio/Song- Live-Remix 2.mp3")
        let ext = FileManager.default.temporaryDirectory.appendingPathComponent("Movie.mp4")
        try Data("m".utf8).write(to: ext)
        XCTAssertEqual(try fs.importCopy(of: ext, into: "Media"), "Media/Movie.mp4")
        XCTAssertEqual(try fs.importCopy(of: ext, into: "Media"), "Media/Movie 2.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ext.path), "import must copy, not move")
        try? FileManager.default.removeItem(at: ext)
    }

    func testListingHidesMetadataFolder() throws {
        let fs = try LibraryFS(root: root)
        try write("visible.txt")
        try fs.setFavorite("visible.txt", true)
        XCTAssertEqual(try fs.list("").map(\.name), ["visible.txt"])
        XCTAssertFalse(fs.scanAll().contains { $0.path.hasPrefix(".studioshelf") })
    }
}

final class YouTubeLinkTests: XCTestCase {
    func id(_ s: String) -> String? { if case .success(let l) = YouTubeLink.parse(s) { return l.videoID }; return nil }

    func testAcceptedForms() {
        let v = "dQw4w9WgXcQ"
        for s in ["https://www.youtube.com/watch?v=\(v)", "youtube.com/watch?v=\(v)&t=42s", "https://m.youtube.com/watch?v=\(v)",
                  "https://music.youtube.com/watch?v=\(v)", "https://youtu.be/\(v)", "https://youtu.be/\(v)?si=abc",
                  "https://www.youtube.com/shorts/\(v)", "https://www.youtube.com/embed/\(v)", "https://www.youtube.com/live/\(v)?feature=share",
                  "https://www.youtube-nocookie.com/embed/\(v)", "  https://www.youtube.com/watch?v=\(v)  ",
                  "https://www.youtube.com/watch?v=\(v)&list=PL1234567890abcdef&index=3"] {
            XCTAssertEqual(id(s), v, s)
        }
    }

    func testRejectedForms() {
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/playlist?list=PL123"), .failure(.playlistOrChannel))
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/watch?list=PL123"), .failure(.playlistOrChannel))
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/@someone"), .failure(.playlistOrChannel))
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/channel/UC123"), .failure(.playlistOrChannel))
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/embed/videoseries?list=PL1"), .failure(.playlistOrChannel))
        XCTAssertEqual(YouTubeLink.parse("https://vimeo.com/12345"), .failure(.notYouTube))
        XCTAssertEqual(YouTubeLink.parse("https://evil-youtube.com/watch?v=dQw4w9WgXcQ"), .failure(.notYouTube))
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/watch?v=short"), .failure(.noVideoID))
        XCTAssertEqual(YouTubeLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXc%22"), .failure(.noVideoID))
        XCTAssertEqual(YouTubeLink.parse("not a link"), .failure(.notALink))
        XCTAssertEqual(YouTubeLink.parse("ftp://youtube.com/watch?v=dQw4w9WgXcQ"), .failure(.notALink))
    }

    func testNormalized() {
        if case .success(let l) = YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?list=x") {
            XCTAssertEqual(l.normalizedURL.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        } else { XCTFail() }
    }
}
