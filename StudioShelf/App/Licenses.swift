enum Licenses {
    static let text = """
    StudioShelf uses these open-source components. Versions are pinned in project.yml.

    YouTubeKit by Alexander Eichhorn
    https://github.com/alexeichhorn/YouTubeKit
    Commit 89854c93207ad0d2b3d78d6f1aea24595ca66552
    MIT License. Used only with on-device extraction; the optional remote server is never enabled.

    LAME 3.100 MP3 encoder (via swift-lame by Phisto)
    https://lame.sourceforge.io  ·  https://github.com/Phisto/swift-lame
    Commit 727f4ad56195e062560e71468eeb6bd244b9167d
    GNU Lesser General Public License v3.0. The unmodified LAME source is available at the links above.
    You may replace the LAME library by rebuilding this app from its source with a different version.

    Apple frameworks: SwiftUI, AVFoundation, AVKit, PDFKit, WebKit, QuickLook.
    """
}
