import UIKit
import WebKit

/// Copies a site's IndexedDB in and out through the page itself, because
/// `WKWebsiteDataStore.fetchData(of:)` exports local storage only (checked on
/// iOS 26.2 and 27.0.1). Telegram Web keeps its login there, so without this
/// it logged out at every lock.
///
/// A dump is JSON: every database of the page's origin with its version,
/// object stores, indexes and records. Values keep their types through a
/// small tagged encoding (dates, binary, blobs, maps, sets). Keys that can't
/// leave the browser (non-extractable `CryptoKey`s) come back as null.
@MainActor
enum IndexedDBBridge {
    /// Casita's own script world, so a page can't tamper with these scripts.
    static let world = WKContentWorld.world(name: "casita")
    /// Above this a site's databases are not kept, so one site can't fill
    /// the space; its other data still is.
    static let maximumBytes = 32 * 1_048_576

    /// "https://web.telegram.org", the key a site's dump is kept under.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host()?.lowercased() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// Every database of the page now showing in `view`. Nil when it has
    /// none; throws when the page wouldn't answer.
    static func dump(_ view: WKWebView, seconds: Double = 15) async throws -> Data? {
        guard let json = try await run(codec + dumpBody, in: view, seconds: seconds) else { return nil }
        let data = Data(json.utf8)
        return data.count > maximumBytes ? nil : data
    }

    /// Writes `dump` into `store` for `origin`, before any page of that
    /// origin runs: a hidden web view loads a blank page that claims to be
    /// the origin, without touching the network, and restores there.
    static func restore(_ dump: Data, origin: String, into store: WKWebsiteDataStore) async {
        guard let url = URL(string: origin + "/") else { return }
        let view = WebSession.makeWebView(store: store)
        attach(view)
        defer { view.removeFromSuperview() }
        let waiter = LoadWaiter()
        view.navigationDelegate = waiter
        view.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<!doctype html><meta charset=utf-8><title></title>")
        await waiter.wait(seconds: 5)
        _ = try? await run(codec + restoreBody, arguments: ["json": String(decoding: dump, as: UTF8.self)], in: view, seconds: 20)
    }

    /// WebKit suspends a web view that is in no window, and its scripts never
    /// finish; so a hidden one sits in Casita's window, invisible and out of
    /// reach of touches and VoiceOver, while it works.
    static func attach(_ view: WKWebView) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first(where: { $0.windowLevel == .normal }) else { return }
        view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.insertSubview(view, at: 0)
    }

    /// One of Casita's scripts, given up on after `seconds` so a stuck page
    /// can never hold a save or a lock.
    private static func run(_ body: String, arguments: [String: String] = [:], in view: WKWebView, seconds: Double) async throws -> String? {
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
            once.continuation = continuation
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                once.finish(result.map { $0 as? String })
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                once.finish(.failure(CancellationError()))
            }
        }
    }

    // MARK: Scripts

    /// Shared helpers: base64 and the tagged encoding.
    private static let codec = #"""
    const T = '\u0000casita';
    function b64(u) { let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); }
    function unb64(s) { const b = atob(s); const u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u; }
    function enc(v, blobs) {
      if (v === null) return null;
      const t = typeof v;
      if (t === 'string' || t === 'boolean') return v;
      if (t === 'number') return Number.isFinite(v) ? v : { [T]: 'n', v: String(v) };
      if (t === 'undefined') return { [T]: 'u' };
      if (t === 'bigint') return { [T]: 'bi', v: v.toString() };
      if (v instanceof Date) return { [T]: 'd', v: v.getTime() };
      if (v instanceof ArrayBuffer) return { [T]: 'ab', v: b64(new Uint8Array(v)) };
      if (ArrayBuffer.isView(v)) return { [T]: 'ta', k: v.constructor.name, v: b64(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)) };
      if (typeof Blob !== 'undefined' && v instanceof Blob) {
        blobs.push({ blob: v, type: v.type, name: v.name, lm: v.lastModified });
        return { [T]: (typeof File !== 'undefined' && v instanceof File) ? 'f' : 'b', i: blobs.length - 1 };
      }
      if (v instanceof Map) return { [T]: 'm', v: Array.from(v, ([k, x]) => [enc(k, blobs), enc(x, blobs)]) };
      if (v instanceof Set) return { [T]: 's', v: Array.from(v, x => enc(x, blobs)) };
      if (v instanceof RegExp) return { [T]: 'r', s: v.source, f: v.flags };
      if (typeof CryptoKey !== 'undefined' && v instanceof CryptoKey) return { [T]: 'x' };
      if (Array.isArray(v)) return v.map(x => enc(x, blobs));
      const o = {};
      for (const k of Object.keys(v)) o[k] = enc(v[k], blobs);
      return o;
    }
    function dec(v, blobs) {
      if (v === null || typeof v !== 'object') return v;
      if (Array.isArray(v)) return v.map(x => dec(x, blobs));
      switch (v[T]) {
        case 'n': return Number(v.v);
        case 'u': return undefined;
        case 'bi': return BigInt(v.v);
        case 'd': return new Date(v.v);
        case 'ab': return unb64(v.v).buffer;
        case 'ta': { const u = unb64(v.v); const C = globalThis[v.k] || Uint8Array; return new C(u.buffer, 0, u.byteLength / (C.BYTES_PER_ELEMENT || 1)); }
        case 'b': { const b = blobs[v.i]; return new Blob([unb64(b.v)], { type: b.type }); }
        case 'f': { const b = blobs[v.i]; return new File([unb64(b.v)], b.name, { type: b.type, lastModified: b.lm }); }
        case 'm': return new Map(v.v.map(([k, x]) => [dec(k, blobs), dec(x, blobs)]));
        case 's': return new Set(v.v.map(x => dec(x, blobs)));
        case 'r': return new RegExp(v.s, v.f);
        case 'x': return null;
      }
      const o = {};
      for (const k of Object.keys(v)) o[k] = dec(v[k], blobs);
      return o;
    }
    function req(r) { return new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); }); }

    """#

    private static let dumpBody = #"""
    if (!self.indexedDB || !indexedDB.databases) return null;
    const infos = await indexedDB.databases();
    const blobs = [], dbs = [];
    for (const info of infos) {
      if (!info.name) continue;
      const db = await new Promise((res, rej) => {
        const r = indexedDB.open(info.name);
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
        r.onupgradeneeded = () => r.transaction.abort();
      }).catch(() => null);
      if (!db) continue;
      try {
        const stores = [];
        for (const name of Array.from(db.objectStoreNames)) {
          const st = db.transaction(name, 'readonly').objectStore(name);
          const meta = { name, keyPath: st.keyPath, autoIncrement: st.autoIncrement,
            indexes: Array.from(st.indexNames, n => { const ix = st.index(n); return { name: n, keyPath: ix.keyPath, unique: ix.unique, multiEntry: ix.multiEntry }; }) };
          const [keys, values] = await Promise.all([req(st.getAllKeys()), req(st.getAll())]);
          stores.push({ meta, records: keys.map((k, i) => [enc(k, blobs), enc(values[i], blobs)]) });
        }
        dbs.push({ name: info.name, version: db.version, stores });
      } finally { db.close(); }
    }
    for (const b of blobs) { b.v = b64(new Uint8Array(await b.blob.arrayBuffer())); delete b.blob; }
    return dbs.length ? JSON.stringify({ dbs, blobs }) : null;
    """#

    private static let restoreBody = #"""
    const data = JSON.parse(json);
    for (const d of data.dbs) {
      await new Promise(res => { const r = indexedDB.deleteDatabase(d.name); r.onsuccess = r.onerror = r.onblocked = () => res(); });
      const db = await new Promise((res, rej) => {
        const r = indexedDB.open(d.name, d.version);
        r.onupgradeneeded = () => {
          for (const s of d.stores) {
            const options = { autoIncrement: s.meta.autoIncrement };
            if (s.meta.keyPath !== null) options.keyPath = s.meta.keyPath;
            const st = r.result.createObjectStore(s.meta.name, options);
            for (const ix of s.meta.indexes) st.createIndex(ix.name, ix.keyPath, { unique: ix.unique, multiEntry: ix.multiEntry });
          }
        };
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
      });
      for (const s of d.stores) {
        if (!s.records.length) continue;
        await new Promise(res => {
          const tx = db.transaction(s.meta.name, 'readwrite');
          const st = tx.objectStore(s.meta.name);
          for (const [k, v] of s.records) {
            try {
              const value = dec(v, data.blobs);
              const put = s.meta.keyPath === null ? st.put(value, dec(k, data.blobs)) : st.put(value);
              // One bad record must not throw the rest of the store away.
              put.onerror = e => e.preventDefault();
            } catch (e) {}
          }
          tx.oncomplete = tx.onerror = tx.onabort = () => res();
        });
      }
      db.close();
    }
    return true;
    """#
}

/// Resumes its caller with the first result only.
@MainActor
private final class Once {
    var continuation: CheckedContinuation<String?, any Error>?

    func finish(_ result: Result<String?, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Resumes once the hidden page has loaded, or after a timeout.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func wait(seconds: Double) async {
        await withCheckedContinuation { continuation in
            if done { return continuation.resume() }
            self.continuation = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                self.finish()
            }
        }
    }

    private func finish() {
        done = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish() }
}
