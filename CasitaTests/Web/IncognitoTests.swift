import Foundation
import Testing
import WebKit
@testable import Casita

/// Incognito keeps nothing: once its browser is discarded, its store holds
/// no website data, no file in Casita's container carries what the page
/// stored, and the next Incognito starts empty.
@MainActor @Suite(.serialized) struct IncognitoTests {
    private static let origin = URL(string: "https://incognito.casita.test/")!
    private static let page = """
    <html><body><script>
    function idb(put) { return new Promise((ok, no) => {
      const r = indexedDB.open('casita', 1);
      r.onupgradeneeded = e => e.target.result.createObjectStore('kv');
      r.onerror = () => no(r.error);
      r.onsuccess = () => {
        const tx = r.result.transaction('kv', 'readwrite'), kv = tx.objectStore('kv');
        if (put) { kv.put(put, 'k'); tx.oncomplete = () => ok('stored'); }
        else { const g = kv.get('k'); g.onsuccess = () => ok(g.result ?? null); }
      };
    }); }
    </script>incognito</body></html>
    """

    /// An Incognito browser on the page above, loaded and ready for scripts.
    private static func incognito() async throws -> Browser {
        let browser = Browser(web: nil)
        let waiter = NavigationWaiter()
        browser.view.navigationDelegate = waiter
        browser.view.loadHTMLString(page, baseURL: origin)
        try await waiter.finished()
        return browser
    }

    /// What the page can still read: local storage, cookies, IndexedDB.
    private static func leftovers(in browser: Browser) async throws -> [String] {
        let web = browser.view
        let local = try await web.evaluateJavaScript("localStorage.getItem('m')") as? String
        let cookie = try await web.evaluateJavaScript("document.cookie") as? String
        let idb = try await web.callAsyncJavaScript("return await idb(null)", contentWorld: .page) as? String
        return [local, cookie, idb].compactMap { $0 }.filter { !$0.isEmpty }
    }

    @Test func leavingIncognitoLeavesNoWebsiteData() async throws {
        let started = Date()
        let marker = "casita-incognito-\(UUID().uuidString)"
        let browser = try await Self.incognito()
        let store = browser.view.configuration.websiteDataStore
        #expect(!store.isPersistent)
        _ = try await browser.view.evaluateJavaScript(
            "localStorage.setItem('m', '\(marker)'); sessionStorage.setItem('m', '\(marker)'); document.cookie = 'm=\(marker); path=/; secure; max-age=86400'; 'ok'")
        _ = try await browser.view.callAsyncJavaScript("return await idb(m)", arguments: ["m": marker], contentWorld: .page)
        await store.httpCookieStore.setCookie(HTTPCookie(properties: [
            .name: "session", .value: marker, .domain: "incognito.casita.test", .path: "/", .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 86_400),
        ])!)
        try #require(await store.httpCookieStore.allCookies().contains { $0.value == marker })
        try #require(try await Self.leftovers(in: browser).count == 3, "the page stored something to discard")

        await browser.discard()

        #expect(await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).isEmpty)
        #expect(await store.httpCookieStore.allCookies().isEmpty)
        let reloaded = NavigationWaiter()
        browser.view.navigationDelegate = reloaded
        browser.view.loadHTMLString(Self.page, baseURL: Self.origin)
        try await reloaded.finished()
        #expect(try await Self.leftovers(in: browser).isEmpty)

        // The next Incognito starts empty, session storage included.
        let next = try await Self.incognito()
        #expect(try await Self.leftovers(in: next).isEmpty)
        #expect(try await next.view.evaluateJavaScript("sessionStorage.getItem('m')") as? String == nil)

        // Nothing on disk: no file changed in Casita's container holds the
        // marker, and WebKit made no website data folder.
        try await Task.sleep(for: .seconds(1))
        let touched = Self.filesChanged(since: started)
        #expect(touched.filter { $0.path.contains("WebsiteData") || $0.path.contains("WebKit") }.isEmpty, "\(touched)")
        let utf8 = Data(marker.utf8), utf16 = marker.data(using: .utf16LittleEndian)!
        let holding = touched.filter { url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            return data.range(of: utf8) != nil || data.range(of: utf16) != nil
        }
        #expect(holding.isEmpty, "\(holding)")
    }

    /// Typing a search in Incognito goes to DuckDuckGo, like the rest of Web.
    @Test func typedSearchesGoToDuckDuckGo() {
        #expect(WebAddress.url(from: "nothing is saved")?.host() == "duckduckgo.com")
        #expect(WebAddress.url(from: "tinder.com")?.host() == "tinder.com")
    }

    /// Regular files under the app's container written since `date`.
    private static func filesChanged(since date: Date) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let all = FileManager.default.enumerator(at: home, includingPropertiesForKeys: keys)?.allObjects as? [URL] ?? []
        return all.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return false }
            return (values.contentModificationDate ?? .distantPast) >= date
        }
    }
}
