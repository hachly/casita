import Foundation
import Network
import Synchronization
import Testing
import UIKit
import WebKit
@testable import Casita

/// A real local HTTP redirect exercises WebKit's navigation callbacks,
/// without relying on a public site's availability or login screens.
private final class BrowserHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    private let paths = Mutex<[String]>([])
    var requestedPaths: [String] { paths.withLock { $0 } }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: DispatchQueue(label: "casita.test.http.connection"))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
                guard let self, let data, let port = self.listener.port?.rawValue else { connection.cancel(); return }
                let request = String(decoding: data, as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                self.paths.withLock { $0.append(path) }
                let response: String
                if request.hasPrefix("GET /redirect ") {
                    response = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(port)/denied\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    let body = "<html><body>Ready<script>document.cookie='visited=1; path=/';</script></body></html>"
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: DispatchQueue(label: "casita.test.http"))
    }

    func stop() { listener.cancel() }

    func readyURL() async throws -> URL {
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 {
                return URL(string: "http://127.0.0.1:\(port.rawValue)/")!
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
}

@MainActor @Suite(.serialized) struct BrowserAccessTests {
    private func fixture() async throws -> (Browser, ReservedStorage, SpaceRef, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let seed = try ReservedStorage.create(at: url, bytes: Int64(ReservedStorage.chunksOffset + 80 * ReservedStorage.chunkSealed), stretcher: PBKDF2Stretcher(iterations: 1000))
        await seed.setCodeWrapIterations(1000)
        _ = try await seed.createTopSpace(code: "test")
        let storage = try ReservedStorage.open(at: url, stretcher: PBKDF2Stretcher(iterations: 1000), access: .free)
        await storage.setMinimumUnlockDuration(.milliseconds(1))
        let space = try #require(try await storage.unlock(code: "test"))
        let browser = Browser(web: WebSpace(storage: storage, space: space))
        browser.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
        window?.addSubview(browser.view)
        return (browser, storage, space, url)
    }

    private func wait(browser: Browser, _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition(), "WebKit state: url=\(browser.view.url?.absoluteString ?? "nil"), loading=\(browser.isLoading), failure=\(browser.failure ?? "none"), upgrade=\(browser.upgradeRequested)")
    }

    @Test func httpRedirectCannotOpenASecondSavedApp() async throws {
        let server = try BrowserHTTPFixture()
        defer { server.stop() }
        let base = try await server.readyURL()
        let (browser, storage, space, file) = try await fixture()
        defer { browser.invalidate(); browser.view.removeFromSuperview(); try? FileManager.default.removeItem(at: file) }
        await browser.load(URLRequest(url: base.appendingPathComponent("redirect")))
        try await wait(browser: browser) { browser.upgradeRequested && !browser.isLoading }
        #expect(try await storage.freeWebApp(in: space) == "127.0.0.1")
        #expect(browser.url == nil, "A blocked initial redirect must not become a remembered page")
        #expect(!server.requestedPaths.contains("/denied"))
        let cookies = await browser.view.configuration.websiteDataStore.httpCookieStore.allCookies()
        #expect(!cookies.contains { $0.domain == "localhost" })
    }

    @Test func scriptNavigationAndPopupsCannotBypassAllowance() async throws {
        let server = try BrowserHTTPFixture()
        defer { server.stop() }
        let base = try await server.readyURL()
        let (browser, _, _, file) = try await fixture()
        defer { browser.invalidate(); browser.view.removeFromSuperview(); try? FileManager.default.removeItem(at: file) }
        await browser.load(URLRequest(url: base))
        try await wait(browser: browser) { browser.url?.host() == "127.0.0.1" && !browser.isLoading }
        #expect(try await browser.view.evaluateJavaScript("document.body.textContent.includes('Ready')") as? Bool == true)
        let other = "http://localhost:\(base.port!)/denied"
        _ = try await browser.view.evaluateJavaScript("location.href = '\(other)'; void 0")
        try await wait(browser: browser) { browser.upgradeRequested }
        browser.upgradeRequested = false
        #expect(browser.url?.host() == "127.0.0.1")
        _ = try await browser.view.evaluateJavaScript("var a=document.createElement('a'); a.href='\(other)'; a.target='_blank'; document.body.appendChild(a); a.click(); void 0")
        try await wait(browser: browser) { browser.upgradeRequested }
        #expect(browser.url?.host() == "127.0.0.1")
        #expect(!server.requestedPaths.contains("/denied"))
        browser.upgradeRequested = false
        await browser.load(URLRequest(url: base.appendingPathComponent("redirect")))
        try await wait(browser: browser) { browser.upgradeRequested && !browser.isLoading }
        #expect(browser.url == base, "A denied redirect retains the previously committed page")
        #expect(!server.requestedPaths.contains("/denied"))
    }

    @Test func invalidatedBrowserNeverClaimsOrLoadsAnApp() async throws {
        let (browser, storage, space, file) = try await fixture()
        defer { browser.view.removeFromSuperview(); try? FileManager.default.removeItem(at: file) }
        browser.invalidate()
        await browser.load(URLRequest(url: URL(string: "https://instagram.com")!))
        #expect(browser.view.url == nil)
        #expect(try await storage.freeWebApp(in: space) == nil)
    }
}
