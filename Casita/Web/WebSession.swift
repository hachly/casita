import WebKit

/// A space's web logins, kept as one file in the space and handed back to a
/// fresh non-persistent store when the space's Web opens, so nothing WebKit
/// writes to disk belongs to a space.
///
/// Three parts, because `WKWebsiteDataStore.fetchData(of:)` only supports
/// local storage (every other type throws WKErrorDomain 1, on iOS 26.2 and
/// 27.0.1 alike); see docs/web-prototype.md.
///   - cookies: `WKHTTPCookieStore.allCookies()` / `setCookies(_:)`
///   - local storage: `fetchData(of:)` / `restoreData(_:)` (iOS 26.0)
///   - IndexedDB, per site: copied through the page (`IndexedDBBridge`),
///     where Telegram Web keeps its login
/// Session storage is not kept; it is meant to end with the visit.
enum WebSession {
    private struct File: Codable {
        /// `NSKeyedArchiver` of each cookie's `properties`.
        var cookies: Data
        /// WebKit's own serialized blob.
        var localStorage: Data?
        /// `IndexedDBBridge` dumps by origin. Missing in files saved before.
        var databases: [String: Data]?
    }

    @MainActor
    static func export(_ store: WKWebsiteDataStore, databases: [String: Data] = [:]) async throws -> Data {
        let cookies = await store.httpCookieStore.allCookies()
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: cookies.compactMap(\.properties), requiringSecureCoding: true
        )
        let local = try? await store.fetchData(of: [WKWebsiteDataTypeLocalStorage])
        return try JSONEncoder().encode(File(cookies: archived, localStorage: local, databases: databases.isEmpty ? nil : databases))
    }

    /// Puts cookies and local storage back into `store`, and returns the
    /// IndexedDB dumps, which go back one site at a time as it opens.
    @MainActor @discardableResult
    static func restore(_ data: Data, into store: WKWebsiteDataStore) async throws -> [String: Data] {
        let file = try JSONDecoder().decode(File.self, from: data)
        let raw = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, NSDictionary.self, NSString.self, NSDate.self, NSNumber.self, NSURL.self],
            from: file.cookies
        ) as? [[HTTPCookiePropertyKey: Any]] ?? []
        await store.httpCookieStore.setCookies(raw.compactMap { HTTPCookie(properties: $0) })
        if let local = file.localStorage, !local.isEmpty {
            try await store.restoreData(local)
        }
        return file.databases ?? [:]
    }

    /// Safari's tail of the user agent for this iOS, e.g. "Version/27.0".
    static var safariApplicationName: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(os.majorVersion).\(os.minorVersion) Mobile/15E148 Safari/604.1"
    }

    /// Safari's whole user agent, for requests made outside a web view (site
    /// icons). Since iOS 26 Safari reports its OS as 18_6.
    static var safariUserAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariApplicationName)"
    }

    /// Sites that serve their web app only to computers: Casita asks for
    /// them the way Safari's "Request Desktop Website" does.
    static func wantsDesktop(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["snapchat.com", "whatsapp.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Safari on a Mac, for those sites: desktop mode alone still says
    /// "Mobile", which they read as a phone.
    static var desktopUserAgent: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(os.majorVersion).\(os.minorVersion) Safari/605.1.15"
    }

    /// Turns off the long-press menu on links and images, whose "Save to
    /// Photos", "Add to Reading List" and Share would carry a space's
    /// pictures and links out of Casita.
    private static let noCallout =
        "var s=document.createElement('style');s.textContent='*{-webkit-touch-callout:none!important}';document.documentElement.appendChild(s);"

    /// A browser that keeps nothing on disk: non-persistent store, no link
    /// previews or long-press menus that could carry things out, Safari's
    /// user agent so sites serve their normal login pages.
    @MainActor
    static func makeWebView(store: WKWebsiteDataStore) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.applicationNameForUserAgent = safariApplicationName
        config.userContentController.addUserScript(
            WKUserScript(source: noCallout, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = true
        return web
    }
}
