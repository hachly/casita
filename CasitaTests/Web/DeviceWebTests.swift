import CoreHaptics
import Foundation
import Testing
import WebKit
@testable import Casita

/// Real iPhones only: the preset sites load in Casita's own web view setup
/// (non-persistent store, Safari user agent) without WebKit's page process
/// dying, as Reddit's did in the iOS 26.2 simulator. Needs the network.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil))
struct DeviceWebTests {
    @Test(arguments: Bookmark.presets.map(\.url))
    func presetSiteLoadsAndStaysUp(_ url: URL) async throws {
        let view = WebSession.makeWebView(store: .nonPersistent())
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        let watcher = LoadWatcher()
        view.navigationDelegate = watcher
        view.load(URLRequest(url: url))
        // Long enough to finish and run the page's scripts, where Reddit crashed.
        try await Task.sleep(for: .seconds(15))
        print("CASITA-DEVICE web \(url.host() ?? "") finished=\(watcher.finished) crashed=\(watcher.crashed) failed=\(watcher.failure ?? "-")")
        #expect(!watcher.crashed, "WebKit's page process died on \(url)")
        #expect(watcher.finished || watcher.failure == nil, "\(url) failed: \(watcher.failure ?? "")")
    }

    /// Playing needs the app in front, which a test host isn't when the
    /// phone locks; the hardware is what this checks.
    @Test func phoneHasHaptics() {
        #expect(CHHapticEngine.capabilitiesForHardware().supportsHaptics)
    }
}

@MainActor
private final class LoadWatcher: NSObject, WKNavigationDelegate {
    var finished = false
    var crashed = false
    var failure: String?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { crashed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failure = error.localizedDescription
    }
}
