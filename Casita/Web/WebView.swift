import SwiftUI
import UIKit

/// The Web tile's screen: an address bar and this space's sites. Logins are
/// written back to the space after every page load, when the browser closes
/// and when Casita leaves the screen.
struct WebView: View {
    @State private var web: WebSpace
    @State private var open: Bookmark?
    @State private var adding = false
    @State private var incognito = false
    @Environment(Entitlements.self) private var entitlements
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model
    @State private var showPaywall = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var shown = false
    @State private var toast: String?
    @State private var freeApp: String?

    init(storage: ReservedStorage, space: SpaceRef) {
        _web = State(initialValue: WebSpace(storage: storage, space: space))
    }

    /// Four across on a phone, more on a wide screen.
    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 10, alignment: .top)]

    /// Tiles appear once the space's own bookmarks are read, so the presets
    /// never flash in first.
    private var revealed: Bool { web.loaded && (shown || reduceMotion) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenHeader(title: "Web", detail: entitlements.isSubscribed ? "Sites and their logins stay in this space." : (freeApp.map { "Your free app: \($0). Upgrade to keep more apps here." } ?? "Keep one app's logins free. Open your first app to choose it."))
                addressBar
                incognitoRow
                VStack(alignment: .leading, spacing: 16) {
                    SectionLabel("Sites")
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(Array(web.bookmarks.enumerated()), id: \.element.id) { index, bookmark in
                            Button { openSite(bookmark) } label: { BookmarkTile(bookmark: bookmark) }
                                .buttonStyle(PressableButtonStyle(scale: 0.9))
                                .contextMenu {
                                    Button(role: .destructive) { remove(bookmark) } label: {
                                        Label("Remove", systemImage: "minus.circle")
                                    }
                                }
                                .reveal(index, active: revealed, step: 0.04)
                                .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.5).combined(with: .opacity))
                                .accessibilityLabel(bookmark.name)
                                .accessibilityIdentifier("web.bookmark.\(bookmark.name)")
                        }
                        Button(action: addSite) { AddTile() }
                            .buttonStyle(PressableButtonStyle(scale: 0.9))
                            .reveal(web.bookmarks.count, active: revealed, step: 0.04)
                            .accessibilityLabel("Add site")
                            .accessibilityIdentifier("web.add")
                    }
                    .animation(reduceMotion ? nil : Theme.bouncy, value: web.bookmarks.map(\.id))
                }
                if let error = web.saveError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("web.screen")
        .scrollDismissesKeyboard(.immediately)
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
        .foregroundStyle(Theme.primary)
        .preferredColorScheme(.dark)
        .collapsingTitle("Web")
        .barToast($toast)
        .paywall(isPresented: $showPaywall, reason: .web)
        .task { await web.load(); freeApp = try? await web.storage.freeWebApp(in: web.space) }
        .onChange(of: open) { _, value in
            if value == nil { Task { freeApp = try? await web.storage.freeWebApp(in: web.space) } }
        }
        .onAppear { shown = true }
        // Reopening after a short lock: back to the page that was open.
        .onChange(of: model.resumeTo, initial: true) { _, place in
            guard let url = place?.webURL else { return }
            model.resumeTo = nil
            open = Bookmark(name: url.host() ?? url.absoluteString, url: url)
        }
        .onChange(of: scenePhase) { if scenePhase != .active { model.whileSaving { await web.save() } } }
        .onDisappear { Task { await web.save() } }
        .fullScreenCover(item: $open) { bookmark in
            BrowserScreen(web: web, start: bookmark.url)
        }
        .sheet(isPresented: $adding) {
            AddSiteSheet { url in
                await web.add(url)
                Haptics.play(.success)
                toast = "Added to Web"
            }
        }
    }

    /// Opens a browser that keeps nothing, in this space or anywhere else.
    private var incognitoRow: some View {
        Button {
            addressFocused = false
            incognito = true
        } label: {
            CasitaRow(glyph: .incognito, title: "Incognito", detail: "Nothing is saved")
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .accessibilityIdentifier("web.incognito")
        .fullScreenCover(isPresented: $incognito) {
            BrowserScreen(web: nil, start: nil)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            GlyphView(glyph: .web, lineWidth: 1.8)
                .frame(width: 18, height: 18)
                .foregroundStyle(addressFocused ? Theme.primary : Theme.tertiary)
            TextField("Search or type a site", text: $address)
                .focused($addressFocused)
                .keyboardType(.webSearch)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(go)
                .accessibilityIdentifier("web.address")
            if !address.isEmpty {
                Button { address = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                }
                .accessibilityLabel("Clear")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.primary.opacity(addressFocused ? 0.3 : 0), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { addressFocused = true }
        .animation(Theme.snappy, value: addressFocused)
        .animation(Theme.snappy, value: address.isEmpty)
    }

    // MARK: Actions

    /// Opens what was typed: the site when it looks like an address, a
    /// search otherwise. Nothing is saved until the person adds it.
    private func go() {
        guard let url = WebAddress.url(from: address) else {
            Haptics.play(.warning)
            return
        }
        Haptics.play(.tap)
        addressFocused = false
        address = ""
        open = Bookmark(name: url.host() ?? url.absoluteString, url: url)
    }

    private func openSite(_ bookmark: Bookmark) {
        addressFocused = false
        open = bookmark
    }

    private func addSite() {
        adding = true
    }

    private func remove(_ bookmark: Bookmark) {
        Haptics.play(.thud)
        Task { await web.remove(bookmark) }
    }
}

/// Turns what someone typed into a page to open.
enum WebAddress {
    /// A site when the text looks like an address, otherwise a DuckDuckGo
    /// search, which keeps no history of who searched.
    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let site = site(from: text, needsDot: true) { return site }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    /// "example.com" or "https://example.com/a": http or https only, with a
    /// host. `needsDot` tells "reddit.com" from a search for "reddit".
    static func site(from typed: String, needsDot: Bool = false) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        if !hasScheme, text.contains("://") { return nil }
        if needsDot, !hasScheme, !text.contains(".") { return nil }
        guard let url = URL(string: hasScheme ? text : "https://" + text),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}

/// A site: its logo, then its name.
private struct BookmarkTile: View {
    let bookmark: Bookmark

    var body: some View {
        VStack(spacing: 8) {
            logo
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            Text(bookmark.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var logo: some View {
        if let asset = bookmark.asset {
            Image(asset).resizable().scaledToFill().background(Theme.raised)
        } else if let data = bookmark.icon, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().background(Theme.raised)
        } else {
            ZStack {
                Theme.raised
                Text(bookmark.name.prefix(1).uppercased())
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.primary)
            }
        }
    }
}

private struct AddTile: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(width: 62, height: 62)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Theme.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                )
            Text("Add site")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// A short sheet for adding a site to this space's Web.
private struct AddSiteSheet: View {
    var onAdd: (URL) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    private var url: URL? { WebAddress.site(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a site")
                    .font(.casitaTitle2)
                    .foregroundStyle(Theme.primary)
                Text("It opens with this space's logins, and only here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 10) {
                GlyphView(glyph: .web, lineWidth: 1.8)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(Theme.tertiary)
                TextField("example.com", text: $text)
                    .focused($focused)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(add)
                    .disabled(busy)
                    .accessibilityIdentifier("web.add.field")
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(Capsule().fill(Theme.raised))
            Button(action: add) {
                ZStack {
                    Text("Add site").opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(.black) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(url == nil || busy)
            .accessibilityIdentifier("web.add.confirm")
        }
        .padding(Theme.gutter)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(310)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(busy)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    private func add() {
        guard let url, !busy else { return }
        busy = true
        focused = false
        Task {
            await onAdd(url)
            dismiss()
        }
    }
}
