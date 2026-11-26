import Foundation
import Testing
import WebKit
@testable import Casita

/// What Telegram Web needs: a site's IndexedDB, copied out of one in-memory
/// store and put back into a fresh one, reads back the same.
@MainActor @Suite(.serialized)
struct IndexedDBBridgeTests {
    static let origin = "https://casita.test"

    static let writer = """
    <!doctype html><script>
    try {
    document.title = 'origin:' + location.origin + ' idb:' + typeof indexedDB;
    const r = indexedDB.open('app', 3);
    r.onerror = () => { document.title = 'error:' + r.error; };
    r.onblocked = () => { document.title = 'blocked'; };
    r.onupgradeneeded = () => {
      const db = r.result;
      db.createObjectStore('kv');
      const items = db.createObjectStore('items', { keyPath: 'id', autoIncrement: true });
      items.createIndex('byName', 'name', { unique: false });
    };
    r.onsuccess = () => {
      const db = r.result;
      const tx = db.transaction(['kv', 'items'], 'readwrite');
      tx.objectStore('kv').put(new Uint8Array([1, 2, 3, 250]), 'dc2_auth_key');
      tx.objectStore('kv').put({ user: 42, when: new Date(1700000000000), tags: new Set(['a']), map: new Map([['k', 1]]) }, 'user_auth');
      // Not a Blob: WebKit refuses Blobs in IndexedDB in an in-memory store.
      tx.objectStore('kv').put(new ArrayBuffer(4), 'buffer');
      tx.objectStore('items').put({ name: 'first' });
      tx.objectStore('items').put({ name: 'second', nested: { deep: [1, 'two', null] } });
      tx.oncomplete = () => { document.title = 'ready'; };
      tx.onerror = () => { document.title = 'txerror:' + tx.error; };
    };
    } catch (e) { document.title = 'threw:' + e; }
    </script>
    """

    static let reader = """
    const db = await new Promise((res, rej) => { const r = indexedDB.open('app'); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
    const get = (store, key) => new Promise(res => { const q = db.transaction(store).objectStore(store).get(key); q.onsuccess = () => res(q.result); });
    const all = store => new Promise(res => { const q = db.transaction(store).objectStore(store).getAll(); q.onsuccess = () => res(q.result); });
    const key = await get('kv', 'dc2_auth_key');
    const auth = await get('kv', 'user_auth');
    const buffer = await get('kv', 'buffer');
    const items = await all('items');
    const index = db.transaction('items').objectStore('items').indexNames.contains('byName');
    return JSON.stringify({
      version: db.version,
      key: key instanceof Uint8Array ? Array.from(key) : null,
      user: auth.user, when: auth.when instanceof Date ? auth.when.getTime() : null,
      set: auth.tags instanceof Set && auth.tags.has('a'), map: auth.map instanceof Map ? auth.map.get('k') : null,
      buffer: buffer instanceof ArrayBuffer ? buffer.byteLength : null,
      items: items.map(i => i.id + ':' + i.name), deep: items[1].nested.deep, index
    });
    """

    @Test func indexedDBSurvivesCopyOutAndBack() async throws {
        let url = URL(string: Self.origin + "/")!
        let first = WebSession.makeWebView(store: .nonPersistent())
        IndexedDBBridge.attach(first)
        defer { first.removeFromSuperview() }
        first.loadSimulatedRequest(URLRequest(url: url), responseHTML: Self.writer)
        for _ in 0..<100 where first.title != "ready" { try await Task.sleep(for: .milliseconds(100)) }
        #expect(first.title == "ready", "page said \(first.title ?? "nothing")")

        let dump = try #require(try await IndexedDBBridge.dump(first))
        let fresh = WKWebsiteDataStore.nonPersistent()
        await IndexedDBBridge.restore(dump, origin: Self.origin, into: fresh)

        let second = WebSession.makeWebView(store: fresh)
        IndexedDBBridge.attach(second)
        defer { second.removeFromSuperview() }
        second.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<!doctype html><title>blank</title>")
        for _ in 0..<50 where second.title != "blank" { try await Task.sleep(for: .milliseconds(100)) }
        let answer = try await second.callAsyncJavaScript(Self.reader, arguments: [:], in: nil, contentWorld: .page) as? String
        let read = try JSONSerialization.jsonObject(with: Data(try #require(answer).utf8)) as? [String: Any] ?? [:]
        #expect(read["version"] as? Int == 3)
        #expect(read["key"] as? [Int] == [1, 2, 3, 250])
        #expect(read["user"] as? Int == 42)
        #expect(read["when"] as? Double == 1_700_000_000_000)
        #expect(read["set"] as? Bool == true)
        #expect(read["map"] as? Int == 1)
        #expect(read["buffer"] as? Int == 4)
        #expect(read["items"] as? [String] == ["1:first", "2:second"])
        #expect(read["index"] as? Bool == true)
        #expect((read["deep"] as? [Any])?.count == 3)
    }

    @Test func sessionFileKeepsDumpsByOrigin() async throws {
        let dumps = [Self.origin: Data("{\"dbs\":[]}".utf8)]
        let file = try await WebSession.export(.nonPersistent(), databases: dumps)
        let back = try await WebSession.restore(file, into: .nonPersistent())
        #expect(back == dumps)
    }

    @Test func originsAreSchemeHostAndPort() {
        #expect(IndexedDBBridge.origin(of: URL(string: "https://Web.Telegram.org/k/#@me")!) == "https://web.telegram.org")
        #expect(IndexedDBBridge.origin(of: URL(string: "http://localhost:8080/a")!) == "http://localhost:8080")
        #expect(IndexedDBBridge.origin(of: URL(string: "about:blank")!) == nil)
    }
}
