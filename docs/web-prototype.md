# Web prototype: moving WebKit logins between non-persistent stores

Date: 2026-10-19. Xcode 26.3, iOS 26.2 simulator runtime (23C54), iPhone 17 Pro simulator. Only the 26.2 runtime is installed, so 26.0 and 26.1 were not tried. Nothing here has run on a real iPhone yet.

The question from docs/adr/0003: can Casita keep a space's web logins inside its own encrypted storage by exporting a `WKWebsiteDataStore.nonPersistent()` store's data and restoring it into a fresh one later?

**Answer: yes, but not with the iOS 26 export API alone.** `fetchData(of:)` exports local storage and nothing else. Cookies, which carry the logins for Instagram, X and Reddit, go through `WKHTTPCookieStore` instead. The two halves together round-trip, and the tests in `CasitaTests/Web/WebSessionTests.swift` prove it on every run.

## The APIs

| What | API | Since | Works on a non-persistent store? |
|---|---|---|---|
| Export | `WKWebsiteDataStore.fetchData(of: Set<String>) async throws -> Data` (Objective-C `fetchDataOfTypes:completionHandler:`) | iOS 26.0, macOS 26, visionOS 26 | Yes, for `WKWebsiteDataTypeLocalStorage` only |
| Restore | `WKWebsiteDataStore.restoreData(_ data: Data) async throws` (`restoreData:completionHandler:`) | iOS 26.0 | Yes |
| Cookie export | `WKHTTPCookieStore.allCookies() async -> [HTTPCookie]` (`getAllCookies:`) | iOS 11 | Yes, HttpOnly cookies included, with their flags and expiry |
| Cookie restore | `WKHTTPCookieStore.setCookies(_: [HTTPCookie]) async` (`setCookies:completionHandler:`) | iOS 26.0 (`setCookie(_:)` one at a time since iOS 11) | Yes, HttpOnly and session cookies included |

The header docs for `fetchData` say only that "an error may occur if a requested data type is not supported". The supported set is not documented anywhere; the test `whichDataTypesExport` asks for every type in `WKWebsiteDataStore.allWebsiteDataTypes()` one at a time and records the answer.

## What round-trips (measured)

Tried on a non-persistent store after a page on `https://login.casita.test/` wrote to every storage and the cookie store got an HttpOnly cookie:

| Data | Export path | Round-trips? |
|---|---|---|
| Cookies, including HttpOnly, Secure, expiry and session cookies without expiry | `WKHTTPCookieStore` | Yes. Restored HttpOnly cookies stay hidden from `document.cookie`, as they should |
| `localStorage` | `fetchData(of: [.localStorage])` / `restoreData` | Yes |
| `sessionStorage` | none | No: `fetchData` throws |
| IndexedDB | none | No: `fetchData` throws |
| Cookies, disk and memory caches, fetch cache, service workers, file system, WebSQL, media keys, hash salt, search history, Screen Time | none | No: `fetchData` throws |

Every unsupported type fails with `WKErrorDomain` code 1, message `This API does not support fetching: <type>`. Asking for a set with one unsupported type fails the whole call, with no partial result.

Sizes: the hybrid blob for two cookies plus one localStorage key is about 1.2 KB. Cookies are an `NSKeyedArchiver` archive of each cookie's `properties`; the localStorage part is WebKit's own opaque blob (114 bytes for one key). Casita wraps both in one JSON file, `WebSession.export` / `WebSession.restore` in `Casita/Web/WebSession.swift`.

A real site: loading `https://www.reddit.com/` logged out set one cookie (`edgebucket`) on the simulator, and it came back in a fresh store with the same name. A logged-in session was **not** tested, because that needs an account and this run had none. The first manual check on a device is: open Web in a space, log into Reddit or X, lock, unlock, reopen Web, still logged in.

Nothing on disk: the test `nonPersistentStoreWritesNothingToDisk` lists the app's `Library` folder before and after using a non-persistent store with cookies, localStorage and IndexedDB, then exporting. No new files appeared at all.

## What this means for the presets

Where each site keeps the login decides whether it survives. This is from how the sites work today, not measured here:

- **Instagram**: cookies (`sessionid`, `csrftoken`, `ds_user_id`). Survives.
- **X**: cookies (`auth_token`, `ct0`). Survives.
- **Reddit**: cookies (`reddit_session`, `token_v2`). Survives.
- **Telegram Web**: wrong in the first version of this note. On 20 Oct 2026 Telegram Web logged out after every lock. Logged out, the K client keeps a single local storage key (`kz_version`); its login lives in IndexedDB. `fetchData(of:)` still exports local storage only on iOS 27.0.1, checked on an iPhone 15 Pro Max for every data type. So Casita now copies each site's IndexedDB out through the page itself (`IndexedDBBridge`): every database, store, index and record, with binary values, dates, maps and sets kept. It saves that encrypted in the space's `web/session.json`, and puts it back in a hidden same-origin page (`loadSimulatedRequest`, no network) before the site's own page runs. `IndexedDBBridgeTests` round-trips it.

Not kept: `sessionStorage`, which is meant to end with the visit; non-extractable `CryptoKey`s, which come back as null; and Blobs, which WebKit refuses in IndexedDB in an in-memory store anyway. A hidden web view must sit in a window, or WebKit suspends it and its scripts never finish.

## Gotchas

- The store owns the data, not the web view. Exporting after the `WKWebView` has been deallocated still returns everything, as long as the `WKWebsiteDataStore` object is alive. Casita keeps one store per open Web (`WebSpace.store`) and drops it on lock.
- `fetchData` is all or nothing. Ask for `[.localStorage]` alone; never pass `allWebsiteDataTypes()`.
- All WebKit calls are main-actor in the iOS 26 SDK. Tests that touch `WKWebView` must be `@MainActor` and run inside the host app, which `CasitaTests` does.
- `WKWebView`'s default user agent lacks `Version/26.0 ... Safari/604.1`, and some sites serve a stripped "open in app" page to it. `config.applicationNameForUserAgent` fixes that.
- Password AutoFill on `WKWebView` is a system feature of the keyboard, reading from the user's Passwords app. There is no public API to turn it off, and it writes nothing of Casita's to disk. Casita itself fills nothing.
- Two test runs sharing one simulator kill CoreSimulatorService under each other (`Mach error -308 server died`, `Invalid device state`). Each run needs its own device: `xcrun simctl create "iPhone 17 Pro web" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-2`.
- `print` from tests only reaches `xcodebuild` output with `-parallel-testing-enabled NO`; with simulator clones it is lost. The tests also append to `tmp/proto.log` in the app container.

## Still to verify on a device

- A real login on each preset after lock, unlock and relaunch (**device**, needs accounts).
- That `fetchData` behaves the same on iOS 26.0 and 26.1, which the installed runtime cannot show.
- Size of Telegram's localStorage blob after a real login, to size the space file.

## If the API goes away

If a future iOS drops localStorage from `fetchData`, the cookie half alone still covers Instagram, X and Reddit. Telegram would need its localStorage dumped per origin through `evaluateJavaScript` and written back the same way, which works only for origins Casita knows to visit.
