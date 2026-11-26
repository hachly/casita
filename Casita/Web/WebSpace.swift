import CryptoKit
import UIKit
import WebKit

/// One space's Web while it is open: its bookmarks and a WebKit store that
/// lives only in memory. `load` fills both from the space's files, `save`
/// writes them back. Drop the object to forget the logins.
@MainActor @Observable
final class WebSpace {
    static let bookmarksFile = "web/bookmarks.json"
    static let sessionFile = "web/session.json"

    let storage: ReservedStorage
    let space: SpaceRef
    let store = WKWebsiteDataStore.nonPersistent()
    var bookmarks: [Bookmark] = Bookmark.presets
    /// Shown on the Web screen when the last save failed.
    var saveError: String?
    /// True once `load` has read the space's bookmarks and logins.
    private(set) var loaded = false
    /// Each site's IndexedDB, by origin (see `IndexedDBBridge`).
    @ObservationIgnored private var databases: [String: Data] = [:]
    /// Sites whose saved IndexedDB is already back in `store`, or that had
    /// none. Only these are copied out again, so a site reached by a link
    /// before it was put back can't overwrite what was saved.
    @ObservationIgnored private var prepared: Set<String> = []
    /// What the last save wrote, to skip writing the same thing again.
    @ObservationIgnored private var lastSaved: SHA256.Digest?

    init(storage: ReservedStorage, space: SpaceRef) {
        self.storage = storage
        self.space = space
    }

    func load() async {
        guard !loaded else { return }
        if let data = try? await storage.readFile(named: Self.bookmarksFile, in: space),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        }
        if let data = try? await storage.readFile(named: Self.sessionFile, in: space) {
            databases = (try? await WebSession.restore(data, into: store)) ?? [:]
        }
        loaded = true
    }

    /// Puts a site's saved IndexedDB back before its page first opens.
    func prepare(for url: URL) async {
        await load()
        guard let origin = IndexedDBBridge.origin(of: url), !prepared.contains(origin) else { return }
        prepared.insert(origin)
        if let dump = databases[origin] {
            await IndexedDBBridge.restore(dump, origin: origin, into: store)
        }
    }

    /// Copies the IndexedDB of the page in `view` out for the next save. The
    /// page must still be on screen: WebKit suspends one that isn't.
    func capture(_ view: WKWebView, seconds: Double = 15) async {
        guard loaded, !view.isLoading, let url = view.url, let origin = IndexedDBBridge.origin(of: url) else { return }
        if !prepared.contains(origin) {
            guard databases[origin] == nil else { return }
            prepared.insert(origin)
        }
        guard let dump = try? await IndexedDBBridge.dump(view, seconds: seconds),
              view.url == url, !view.isLoading else { return }
        databases[origin] = dump
    }

    /// Writes logins and bookmarks into the space. Cheap; called after every
    /// page load so a lock that lands first loses nothing.
    func save() async {
        guard loaded else { return }  // never overwrite a space's logins with an empty store
        do {
            let marks = try JSONEncoder().encode(bookmarks)
            let session = try await WebSession.export(store, databases: databases)
            var hash = SHA256()
            hash.update(data: marks)
            hash.update(data: session)
            let digest = hash.finalize()
            guard digest != lastSaved else { return }
            try await storage.writeFile(named: Self.bookmarksFile, data: marks, in: space)
            try await storage.writeFile(named: Self.sessionFile, data: session, in: space)
            lastSaved = digest
            saveError = nil
        } catch StorageError.noRoom {
            saveError = "No room left in this space to keep web logins."
        } catch {
            saveError = "Couldn't keep web logins: \(error.localizedDescription)"
        }
    }

    func add(_ url: URL) async {
        var bookmark = Bookmark(name: url.host() ?? url.absoluteString, url: url)
        bookmark.icon = await Self.fetchIcon(for: url)
        bookmarks.append(bookmark)
        await save()
    }

    func remove(_ bookmark: Bookmark) async {
        bookmarks.removeAll { $0.id == bookmark.id }
        await save()
    }

    /// The site's own icon, fetched with nothing cached on disk.
    private static func fetchIcon(for url: URL) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        config.httpAdditionalHeaders = ["User-Agent": WebSession.safariUserAgent]
        let session = URLSession(configuration: config)
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            guard let iconURL = URL(string: path, relativeTo: url)?.absoluteURL,
                  let (data, response) = try? await session.data(from: iconURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  UIImage(data: data) != nil
            else { continue }
            return data
        }
        return nil
    }
}
