# Minimum iOS 26

Website logins in Web are stored by WebKit, not by Casita. Before iOS 26 the only way to keep them separate per space is a persistent `WKWebsiteDataStore` per space, whose on-disk stores let a forensic copy count how many spaces use Web. iOS 26 lets an app export a store's data and restore it later, so Casita keeps every space's logins inside its own encrypted storage and uses non-persistent stores while a space is open. We chose iOS 26 as the minimum over iOS 17's wider reach, because privacy wins ties and every iPhone from the iPhone 11 on can run iOS 26.

## Consequences

- Do not lower the minimum for reach without solving the store-count leak another way.
- The iOS 26 export/restore API is thinly documented; prototype it before building Web.
