import SwiftUI
import UIKit
import WebKit

/// One site, full screen, on the space's in-memory store, with a single
/// slim bar at the bottom.
///
/// Without a `web`, the screen is Incognito: a store of its own that is
/// never written to the space and is wiped when the screen goes, whether
/// closed or torn down by a lock.
struct BrowserScreen: View {
    let web: WebSpace?
    /// Nil opens Incognito's start page with the address ready to type.
    let start: URL?
    /// Made on appear, not in init: SwiftUI may build this view many times,
    /// and each Browser owns a web view.
    @State private var browser: Browser?
    @Environment(Entitlements.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model

    init(web: WebSpace?, start: URL?) {
        self.web = web
        self.start = start
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let browser {
                BrowserChrome(web: web, browser: browser, start: start)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard browser == nil else { return }
            let browser = Browser(web: web)
            self.browser = browser
            if let start {
                Task {
                    // The site's saved IndexedDB goes back before its page runs.
                    await browser.load(URLRequest(url: start))
                }
            }
        }
        .onDisappear {
            if browser?.upgradeRequested != true || model.phase == .locked { browser?.invalidate() }
            // The page's data was copied out on close or as Casita left the
            // screen; a page already off screen would only stall a copy.
            if let web {
                Task { await web.save() }
            } else if let browser {
                Task { await browser.discard() }
            }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .locked { browser?.invalidate() }
        }
        .paywall(isPresented: Binding(get: { browser?.upgradeRequested ?? false }, set: { browser?.upgradeRequested = $0 }), reason: .web)
        .onChange(of: browser?.upgradeRequested) { previous, showing in
            guard previous == true, showing == false, let browser else { return }
            if entitlements.isSubscribed { Task { await browser.retryDenied() } }
            else if browser.url == nil { dismiss() }
        }
        // The page that is open, for reopening it after a short lock.
        // Incognito pages are never remembered.
        .onChange(of: browser?.url) { _, url in
            if web != nil, let url { model.place.webURL = url }
        }
        // Leaving Casita: copy the page's data out before the space locks.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, let web, let browser else { return }
            model.whileSaving {
                await browser.capture()
                await web.save()
            }
        }
        // And every 30 s, so a crash or a dead battery loses little.
        .task {
            guard web != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let web, let browser else { return }
                await browser.capture()
                await web.save()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.screen")
    }
}

private struct BrowserChrome: View {
    let web: WebSpace?
    let browser: Browser
    let start: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                BrowserView(browser: browser)
                if web == nil, browser.url == nil {
                    incognitoStart
                }
                if let failure = browser.failure {
                    failed(failure)
                        .transition(.opacity)
                }
            }
            .animation(Theme.snappy, value: browser.failure)
            bar
        }
        // The bar stays put under a page's keyboard, and rises only while
        // the address is being typed.
        .ignoresSafeArea(.keyboard, edges: editing ? [] : .bottom)
        .onChange(of: addressFocused) { _, focused in
            if !focused, editing { withAnimation(Theme.snappy) { editing = false } }
        }
        .onAppear { if start == nil { beginEditing() } }
    }

    /// What Incognito shows before the first page.
    private var incognitoStart: some View {
        VStack(spacing: 14) {
            GlyphView(glyph: .incognito, lineWidth: 1.4)
                .frame(width: 56, height: 56)
                .foregroundStyle(Theme.primary)
            Text("Incognito")
                .font(.casitaTitle2)
                .foregroundStyle(Theme.primary)
            Text("Nothing is saved. Logins, history and site data are gone when you close it or Casita locks.")
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.incognito.start")
    }

    /// Incognito says so above its bar, all the time.
    private var incognitoLabel: some View {
        HStack(spacing: 6) {
            GlyphView(glyph: .incognito, lineWidth: 2)
                .frame(width: 15, height: 15)
            Text("Incognito · Nothing is saved")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.secondary)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser.incognito")
    }

    private var bar: some View {
        VStack(spacing: 0) {
            progressLine
            if web == nil { incognitoLabel }
            HStack(spacing: 6) {
                if editing {
                    addressField
                    Button("Cancel") { stopEditing() }
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.leading, 4)
                } else {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(CircleButtonStyle(size: 40, fill: Theme.surface))
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("browser.close")
                    Button { browser.view.goBack() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(CircleButtonStyle(size: 40, fill: .clear))
                        .disabled(!browser.canGoBack)
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("browser.back")
                    Button { browser.view.goForward() } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(CircleButtonStyle(size: 40, fill: .clear))
                        .disabled(!browser.canGoForward)
                        .accessibilityLabel("Forward")
                        .accessibilityIdentifier("browser.forward")
                    hostPill
                    Button { browser.view.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(CircleButtonStyle(size: 40, fill: .clear))
                        .accessibilityLabel("Reload")
                        .accessibilityIdentifier("browser.reload")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// A thin white line that fills as the page loads.
    private var progressLine: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Theme.primary)
                .frame(width: geo.size.width * browser.progress)
                .opacity(browser.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: browser.progress)
                .animation(.easeOut(duration: 0.35).delay(0.15), value: browser.isLoading)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    private var hostPill: some View {
        Button(action: beginEditing) {
            HStack(spacing: 6) {
                if browser.isSecure {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                Text(browser.host ?? start?.host() ?? "Search or type a site")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle((browser.host ?? start?.host()) == nil ? Theme.tertiary : Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Capsule().fill(Theme.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .accessibilityLabel("Address")
        .accessibilityValue(browser.host ?? "")
        .accessibilityIdentifier("browser.address")
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            TextField("Search or type a site", text: $address)
                .focused($addressFocused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(goTyped)
                .onAppear { addressFocused = true }
                .accessibilityIdentifier("browser.field")
            if !address.isEmpty {
                Button { address = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                }
                .accessibilityLabel("Clear")
                .accessibilityIdentifier("browser.clear")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(Theme.surface))
        .transition(.opacity)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            GlyphView(glyph: .web, lineWidth: 1.5)
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.tertiary)
            Text("Can't open this page")
                .font(.casitaTitle2)
                .foregroundStyle(Theme.primary)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { browser.retry() }
                .buttonStyle(RaisedButtonStyle())
                .frame(maxWidth: 220)
                .padding(.top, 4)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    /// Copies the page's data out while it is still on screen (at most 3 s;
    /// the 30-second copies cover a slower page), then closes. The save
    /// finishes behind, and a lock meanwhile waits for it.
    private func close() {
        model.place.webURL = nil
        Task {
            if let web {
                await browser.capture(seconds: 3)
                model.whileSaving { await web.save() }
            }
            dismiss()
        }
    }

    private func beginEditing() {
        address = browser.url?.absoluteString ?? start?.absoluteString ?? ""
        withAnimation(Theme.snappy) { editing = true }
    }

    private func stopEditing() {
        addressFocused = false
        withAnimation(Theme.snappy) { editing = false }
    }

    private func goTyped() {
        guard let url = WebAddress.url(from: address) else {
            Haptics.play(.warning)
            return
        }
        Haptics.play(.tap)
        Task {
            await browser.load(URLRequest(url: url))
        }
        stopEditing()
    }
}

/// Owns the web view, keeps every navigation inside Casita, and mirrors the
/// web view's state for the bar.
@MainActor @Observable
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    /// Nil for Incognito, which nothing saves.
    private let web: WebSpace?
    private let lease = NavigationLease()
    private var hasAppNavigation = false
    private var deniedRequest: URLRequest?
    var upgradeRequested = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var failedURL: URL?

    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var url: URL?
    /// Why the page couldn't open, shown over the page.
    private(set) var failure: String?

    /// The site's name for the bar, without "www.".
    var host: String? {
        url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    var isSecure: Bool { url?.scheme?.lowercased() == "https" }

    init(web: WebSpace?) {
        self.web = web
        view = WebSession.makeWebView(store: web?.store ?? .nonPersistent())
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        // Black, not white, until the first page arrives.
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        observations = [
            view.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
        ]
    }

    /// Copies the web view's state, touching only what changed.
    private func sync() {
        if progress != view.estimatedProgress { progress = view.estimatedProgress }
        if isLoading != view.isLoading { isLoading = view.isLoading }
        if canGoBack != view.canGoBack { canGoBack = view.canGoBack }
        if canGoForward != view.canGoForward { canGoForward = view.canGoForward }
        // WebKit exposes a redirect target before its policy is decided.
        // Remember only committed pages; same-origin history changes can
        // update the address once navigation is no longer in flight.
        if let current = url, let next = view.url, current != next, !view.isLoading,
           IndexedDBBridge.origin(of: current) == IndexedDBBridge.origin(of: next) {
            url = next
        }
    }

    /// Incognito's end: stops the page and wipes everything its store holds
    /// in memory. The store never had a file on disk, and dropping the
    /// browser drops the store itself.
    func discard() async {
        invalidate()
        view.stopLoading()
        await view.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func invalidate() {
        lease.cancel()
        view.stopLoading()
        upgradeRequested = false
        deniedRequest = nil
    }

    /// A provisional redirect changes WebKit's URL before its old document
    /// goes away. Never file that document's databases under the new origin.
    func capture(seconds: Double = 15) async {
        guard lease.isActive, let web, let url, view.url == url, !view.isLoading else { return }
        await web.capture(view, seconds: seconds)
    }

    /// Every top-level load, including typed addresses, is admitted before
    /// cookies/session data can be used for another app.
    func load(_ request: URLRequest) async {
        guard lease.isActive, let url = request.url else { return }
        guard await authorize(request, signInFlow: false) else { return }
        await web?.prepare(for: url)
        guard lease.isActive else { return }
        view.load(request)
    }

    func retryDenied() async {
        guard lease.isActive, let request = deniedRequest else { return }
        deniedRequest = nil
        await load(request)
    }

    private func authorize(_ request: URLRequest, signInFlow: Bool) async -> Bool {
        guard lease.isActive, let url = request.url else { return false }
        guard let web else { return true }
        do {
            let allowed = try await web.storage.authorizeWebApp(url, in: web.space, lease: lease, signInFlow: signInFlow)
            guard lease.isActive else { return false }
            if !allowed {
                deniedRequest = request
                upgradeRequested = true
            }
            return allowed
        } catch {
            if lease.isActive, !(error is CancellationError) { failure = "Close this page and unlock the space again." }
            return false
        }
    }

    func retry() {
        failure = nil
        if let failedURL {
            Task { await load(URLRequest(url: failedURL)) }
        } else {
            view.reload()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard lease.isActive else { return }
        url = webView.url
        failure = nil
        failedURL = nil
        if !webView.isOpaque { webView.isOpaque = true }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard lease.isActive, let web else { return }
        Task {
            await capture()
            await web.save()
        }
    }

    /// Only a page that never arrived gets the message; a half-loaded page
    /// stays usable.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let error = error as NSError
        // A cancelled load, or a link to another app that was refused below.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        failedURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        failure = error.localizedDescription
        Haptics.play(.warning)
    }

    /// The page's process died (a heavy page, or a WebKit crash). Left
    /// alone, WebKit reloads and may die again, leaving a black page; say
    /// so instead, with Try again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failedURL = webView.url ?? url
        failure = "This page stopped working."
        Haptics.play(.warning)
    }

    /// Never hand a link to another app: an `instagram://` or `tg://` jump
    /// would leave the space. A tapped https link to another site can open
    /// that site's app too (a universal link), on the owner's own account;
    /// a load started here never does, so such taps are loaded afresh.
    /// Sites that only serve computers get the desktop version.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let request = navigationAction.request
        guard lease.isActive else { return (.cancel, preferences) }
        guard let url = request.url, ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
            return (.cancel, preferences)
        }
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == true {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                guard await authorize(request, signInFlow: hasAppNavigation) else { return (.cancel, preferences) }
                guard lease.isActive else { return (.cancel, preferences) }
                hasAppNavigation = true
                await web?.prepare(for: url)
                guard lease.isActive else { return (.cancel, preferences) }
            } else if web != nil {
                // A saved app cannot turn a data/blob page into a second
                // arbitrary browser. Incognito remains unrestricted.
                return (.cancel, preferences)
            }
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true,
           (request.httpMethod ?? "GET") == "GET", url.host() != webView.url?.host() {
            webView.load(request)
            return (.cancel, preferences)
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            let desktop = WebSession.wantsDesktop(url)
            preferences.preferredContentMode = desktop ? .desktop : .mobile
            webView.customUserAgent = desktop ? WebSession.desktopUserAgent : nil
        }
        return (.allow, preferences)
    }

    /// Pop-ups (OAuth windows, target="_blank") open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

struct BrowserView: UIViewRepresentable {
    let browser: Browser
    func makeUIView(context: Context) -> WKWebView { browser.view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
