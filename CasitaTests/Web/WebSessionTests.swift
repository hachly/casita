import Foundation
import Testing
import WebKit
@testable import Casita

/// Prototype for docs/web-prototype.md: does WebKit's iOS 26 export/restore
/// carry a login from one non-persistent store to another?
///
/// Runs inside the Casita host app on the simulator. Output lines starting
/// with `PROTO:` feed the report.
@MainActor @Suite(.serialized) struct WebSessionTests {
    private static let origin = URL(string: "https://login.casita.test/")!
    private static let page = """
    <html><body><script>
    function idbPut(v) { return new Promise((ok, no) => {
      const r = indexedDB.open('casita', 1);
      r.onupgradeneeded = e => e.target.result.createObjectStore('kv');
      r.onerror = () => no(r.error);
      r.onsuccess = () => { const db = r.result;
        const tx = db.transaction('kv', 'readwrite'); tx.objectStore('kv').put(v, 'k');
        tx.oncomplete = () => ok('stored'); tx.onerror = () => no(tx.error); };
    }); }
    function idbGet() { return new Promise((ok, no) => {
      const r = indexedDB.open('casita', 1);
      r.onupgradeneeded = e => e.target.result.createObjectStore('kv');
      r.onerror = () => no(r.error);
      r.onsuccess = () => { const g = r.result.transaction('kv').objectStore('kv').get('k');
        g.onsuccess = () => ok(g.result ?? null); g.onerror = () => no(g.error); };
    }); }
    </script>ready</body></html>
    """

    /// A web view on the page above, loaded and ready for scripts.
    private static func loadedPage(in store: WKWebsiteDataStore) async throws -> WKWebView {
        let web = WebSession.makeWebView(store: store)
        let waiter = NavigationWaiter()
        web.navigationDelegate = waiter
        web.loadHTMLString(page, baseURL: origin)
        try await waiter.finished()
        return web
    }

    private static func cookie(_ name: String, _ value: String, httpOnly: Bool = false) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: "login.casita.test", .path: "/",
            .secure: "TRUE", .expires: Date(timeIntervalSinceNow: 86_400 * 30),
        ]
        if httpOnly { props[.init("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: props)!
    }

    @Test func whichDataTypesExport() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let web = try await Self.loadedPage(in: store)
        _ = try await web.evaluateJavaScript("localStorage.setItem('t', '1'); sessionStorage.setItem('s', '1'); 'ok'")
        _ = try await web.callAsyncJavaScript("return await idbPut('v')", contentWorld: .page)
        await store.httpCookieStore.setCookie(Self.cookie("a", "1"))

        var supported: [String] = []
        var failed: [String: String] = [:]
        for type in WKWebsiteDataStore.allWebsiteDataTypes().sorted() {
            do {
                let blob = try await store.fetchData(of: [type])
                supported.append("\(type) (\(blob.count) bytes)")
            } catch {
                failed[type] = (error as NSError).localizedDescription
            }
        }
        proto("fetchData supported: \(supported)")
        proto("fetchData failed: \(failed)")
        let blob = try await WebSession.export(store)
        proto("WebSession.export (cookies + localStorage) -> \(blob.count) bytes")
        #expect(supported.contains { $0.hasPrefix(WKWebsiteDataTypeLocalStorage) })
    }

    @Test func exportRestoreRoundTrip() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        var web: WKWebView? = try await Self.loadedPage(in: store)
        _ = try await web!.evaluateJavaScript("localStorage.setItem('token', 'abc'); sessionStorage.setItem('tab', 'xyz'); document.cookie = 'js=1; path=/; secure'; 'ok'")
        _ = try await web!.callAsyncJavaScript("return await idbPut('hello')", contentWorld: .page)
        await store.httpCookieStore.setCookie(Self.cookie("session", "secret", httpOnly: true))
        web = nil  // the store, not the web view, owns the data

        let blob = try await WebSession.export(store)
        proto("round-trip blob \(blob.count) bytes, head \(blob.prefix(16).map { String(format: "%02x", $0) }.joined())")

        let fresh = WKWebsiteDataStore.nonPersistent()
        #expect(await fresh.httpCookieStore.allCookies().isEmpty)
        try await WebSession.restore(blob, into: fresh)

        let cookies = await fresh.httpCookieStore.allCookies()
        let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        proto("restored cookies \(cookies.map { "\($0.name)=\($0.value) httpOnly=\($0.isHTTPOnly) secure=\($0.isSecure) expires=\(String(describing: $0.expiresDate))" })")
        #expect(byName["session"]?.value == "secret")
        #expect(byName["session"]?.isHTTPOnly == true)
        #expect(byName["js"]?.value == "1")

        let page = try await Self.loadedPage(in: fresh)
        let local = try await page.evaluateJavaScript("localStorage.getItem('token')") as? String
        let session = try await page.evaluateJavaScript("sessionStorage.getItem('tab')") as? String
        let idb = try await page.callAsyncJavaScript("return await idbGet()", contentWorld: .page) as? String
        let docCookie = try await page.evaluateJavaScript("document.cookie") as? String
        proto("restored localStorage=\(local ?? "nil") sessionStorage=\(session ?? "nil") indexedDB=\(idb ?? "nil") document.cookie=\(docCookie ?? "nil")")
        #expect(local == "abc")
        #expect(session == nil, "sessionStorage is not exportable; a change here means iOS gained it")
        #expect(idb == nil, "IndexedDB is not exportable; a change here means iOS gained it")
        #expect(docCookie?.contains("js=1") == true)
        #expect(docCookie?.contains("session=") == false, "HttpOnly stays hidden from scripts")
    }

    /// The cookie jar alone, through `WKHTTPCookieStore` with nothing else.
    @Test func cookieStoreRoundTrip() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        await store.httpCookieStore.setCookie(Self.cookie("session", "secret", httpOnly: true))
        await store.httpCookieStore.setCookie(Self.cookie("plain", "1"))
        let cookies = await store.httpCookieStore.allCookies()

        let fresh = WKWebsiteDataStore.nonPersistent()
        await fresh.httpCookieStore.setCookies(cookies)
        let restored = await fresh.httpCookieStore.allCookies()
        let byName = Dictionary(uniqueKeysWithValues: restored.map { ($0.name, $0) })
        proto("WKHTTPCookieStore round trip: \(restored.map { "\($0.name) httpOnly=\($0.isHTTPOnly)" })")
        #expect(byName["session"]?.value == "secret")
        #expect(byName["session"]?.isHTTPOnly == true)
        #expect(byName["plain"]?.value == "1")
    }

    /// Needs network: a real preset site sets its cookies, which must come
    /// back in a fresh store.
    @Test func realSiteCookiesRoundTrip() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let web = WebSession.makeWebView(store: store)
        let waiter = NavigationWaiter()
        web.navigationDelegate = waiter
        web.load(URLRequest(url: URL(string: "https://www.reddit.com/")!))
        try await waiter.finished()
        let before = await store.httpCookieStore.allCookies()
        proto("reddit set \(before.count) cookies: \(before.map(\.name).sorted())")
        try #require(!before.isEmpty, "no cookies: is the simulator online?")

        let blob = try await WebSession.export(store)
        let fresh = WKWebsiteDataStore.nonPersistent()
        try await WebSession.restore(blob, into: fresh)
        let after = await fresh.httpCookieStore.allCookies()
        proto("reddit blob \(blob.count) bytes, restored \(after.count) cookies")
        #expect(Set(after.map(\.name)) == Set(before.map(\.name)))
    }

    /// Sites that show phones a "use a computer" page get the desktop version.
    @Test func computerOnlySitesGetTheDesktopVersion() {
        #expect(WebSession.wantsDesktop(URL(string: "https://web.whatsapp.com/")!))
        #expect(WebSession.wantsDesktop(URL(string: "https://www.snapchat.com/web")!))
        #expect(!WebSession.wantsDesktop(URL(string: "https://www.instagram.com/")!))
        #expect(!WebSession.wantsDesktop(URL(string: "https://notsnapchat.com/")!))
        #expect(!WebSession.desktopUserAgent.contains("Mobile"))
    }

    /// A non-persistent store must leave nothing in the app container.
    @Test func nonPersistentStoreWritesNothingToDisk() async throws {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        func listing() -> Set<String> {
            Set((FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .map { $0.path.replacingOccurrences(of: library.path, with: "") })
        }
        let before = listing()
        let store = WKWebsiteDataStore.nonPersistent()
        let web = try await Self.loadedPage(in: store)
        _ = try await web.evaluateJavaScript("localStorage.setItem('leak', 'casita-marker'); document.cookie = 'leak=casita-marker; path=/; secure'; 'ok'")
        _ = try await web.callAsyncJavaScript("return await idbPut('casita-marker')", contentWorld: .page)
        _ = try await WebSession.export(store)
        try await Task.sleep(for: .seconds(1))
        let new = listing().subtracting(before)
        proto("new files under Library after using a non-persistent store: \(new.sorted())")
        let suspicious = new.filter { $0.contains("WebsiteData") || $0.contains("Cookies") || $0.contains("LocalStorage") || $0.contains("IndexedDB") }
        #expect(suspicious.isEmpty)
    }
}

/// Findings for the report: printed, and appended to tmp/proto.log in the
/// app container, which xcodebuild does not always echo.
private func proto(_ line: String) {
    print("PROTO: \(line)")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("proto.log")
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

/// Waits for one navigation to finish.
@MainActor final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func finished() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error); continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
