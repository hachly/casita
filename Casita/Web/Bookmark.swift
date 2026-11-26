import Foundation

/// A site on a space's Web screen.
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: URL
    /// Bundled logo for presets, in Casita/Web/Icons.xcassets.
    var asset: String?
    /// The site's own icon for added sites, as fetched.
    var icon: Data?

    static let presets = [
        Bookmark(name: "Instagram", url: URL(string: "https://www.instagram.com/")!, asset: "instagram"),
        Bookmark(name: "Telegram", url: URL(string: "https://web.telegram.org/")!, asset: "telegram"),
        Bookmark(name: "X", url: URL(string: "https://x.com/")!, asset: "x"),
        Bookmark(name: "Reddit", url: URL(string: "https://www.reddit.com/")!, asset: "reddit"),
        Bookmark(name: "TikTok", url: URL(string: "https://www.tiktok.com/")!, asset: "tiktok"),
        Bookmark(name: "Facebook", url: URL(string: "https://www.facebook.com/")!, asset: "facebook"),
        Bookmark(name: "Threads", url: URL(string: "https://www.threads.com/")!, asset: "threads"),
        Bookmark(name: "YouTube", url: URL(string: "https://m.youtube.com/")!, asset: "youtube"),
        Bookmark(name: "Pinterest", url: URL(string: "https://www.pinterest.com/")!, asset: "pinterest"),
        Bookmark(name: "LinkedIn", url: URL(string: "https://www.linkedin.com/")!, asset: "linkedin"),
        Bookmark(name: "Discord", url: URL(string: "https://discord.com/app")!, asset: "discord"),
        Bookmark(name: "Tinder", url: URL(string: "https://tinder.com/")!, asset: "tinder"),
    ]
}
