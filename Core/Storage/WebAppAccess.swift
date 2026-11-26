import Foundation
import Synchronization

/// Cancels pending navigation even while the storage actor is busy.
final class NavigationLease: Sendable {
    private let active = Mutex(true)
    var isActive: Bool { active.withLock { $0 } }
    func cancel() { active.withLock { $0 = false } }
}

enum WebAppIdentity {
    static func isSearchUtility(_ url: URL) -> Bool {
        guard ["duckduckgo.com", "www.duckduckgo.com"].contains(url.host()?.lowercased() ?? "") else { return false }
        return ["", "/", "/html", "/html/", "/lite/", "/l/"].contains(url.path)
    }
    // Explicit app aliases, not a last-two-label rule (which would merge
    // unrelated sites on co.uk, github.io, and other shared domains).
    static let domains = [
        ["instagram.com"], ["telegram.org"], ["x.com", "twitter.com"],
        ["reddit.com", "redd.it"], ["tiktok.com"], ["facebook.com", "fb.com"],
        ["threads.com", "threads.net"], ["youtube.com", "youtu.be"],
        ["pinterest.com"], ["linkedin.com"], ["discord.com", "discordapp.com"],
        ["tinder.com"], ["whatsapp.com"], ["snapchat.com"]
    ]

    static func app(for url: URL) -> String? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if let aliases = domains.first(where: { group in group.contains { host == $0 || host.hasSuffix("." + $0) } }) {
            return aliases[0]
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Sign-in endpoints are allowed only inside an already chosen app's
    /// flow. Never grant an entire provider's regular products or homepage.
    static func isSignIn(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        let path = url.path.lowercased()
        switch host {
        case "accounts.google.com":
            return ["/o/oauth2/", "/signin/", "/v3/signin/", "/servicelogin", "/accountchooser", "/gsi/"].contains { path.hasPrefix($0) }
        case "appleid.apple.com": return path.hasPrefix("/auth/")
        case "www.facebook.com", "m.facebook.com", "facebook.com":
            return path.hasPrefix("/login") || path.hasPrefix("/dialog/oauth") || path.hasPrefix("/checkpoint/")
        case "login.microsoftonline.com": return path.contains("/oauth2/") || path.hasSuffix("/login")
        default: return false
        }
    }
}

extension ReservedStorage {
    static let freeWebAppFile = "web/free-app.json"

    func freeWebApp(in ref: SpaceRef) throws -> String? {
        let header = try state(ref).header
        guard header.files.contains(where: { $0.name == Self.freeWebAppFile }) else { return nil }
        return try JSONDecoder().decode(String.self, from: readFile(named: Self.freeWebAppFile, in: ref))
    }

    /// Selection and admission are one actor operation. Bookmarks don't
    /// consume the allowance; opening the first saved app does.
    func authorizeWebApp(_ url: URL, in ref: SpaceRef, lease: NavigationLease, signInFlow: Bool = false) throws -> Bool {
        guard lease.isActive else { throw CancellationError() }
        _ = try state(ref)
        guard let app = WebAppIdentity.app(for: url) else { return false }
        if access.hasPlan { return true }
        // Searching is part of the browser, not a saved-login app. The
        // first result the person opens claims the allowance instead.
        if WebAppIdentity.isSearchUtility(url) { return true }
        if let selected = try freeWebApp(in: ref) {
            return selected == app || (signInFlow && WebAppIdentity.isSignIn(url))
        }
        // A provider callback cannot accidentally become the free app.
        guard !WebAppIdentity.isSignIn(url) else { return false }
        try writeFile(named: Self.freeWebAppFile, data: JSONEncoder().encode(app), in: ref)
        return true
    }
}
