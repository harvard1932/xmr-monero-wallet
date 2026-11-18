# Verification

The iPhone 17 Pro simulator suite passed all 18 XCTest cases on iOS 26.5 with the optional public-node test enabled. Xcode also produced an unsigned arm64 Release build for iPhone. These are development checks. An independent review, source-to-binary reproduction and physical-device signing and camera tests remain open.

| Check | Evidence |
| --- | --- |
| iPhone simulator build and launch | Xcode built the app and sync widget, embedded the pinned arm64 native framework, and launched the welcome screen. |
| Wallet and receive screens | The screenshots use the production SwiftUI components with a newly generated, empty Monero **testnet** wallet. An iPhone 17 simulator UI test opened its receive QR. |
| Amounts and scanned data | XCTest covers exact atomic units, overflow, payment-URI parsing and bounded multipart QR collection. |
| File and session lifecycle | XCTest covers backup verification across relaunch, invalidating an interrupted unlock and preserving wallet files with unreadable metadata. |
| Legacy recovery | Local JavaScript tests check public fixtures. iOS 17.2 JavaScriptCore plus native wallet2 restored both MyMonero and supported BIP39 fixtures to their expected addresses. |
| Tor routing | Native wallet2 sent the v3 onion hostname to a local SOCKS4a test listener. A refused handshake left the wallet disconnected. Other tests reject non-onion destinations in Tor mode and check that automatic onion selection issues zero direct node probes. |
| HTTPS transport | On an iPhone 17 Pro simulator, native wallet2 connected through the authenticated loopback listener and iOS TLS validation to a public mainnet daemon. The test used a fresh empty wallet and checked the reported chain height. The unauthenticated-listener test checks the Digest challenge without contacting an upstream node. |

On an isolated regression network, an upstream wallet RPC prepared an unsigned 1.25 XMR test payment with a 0.0025992 XMR network fee. The app engine reviewed and signed it offline. A view-only wallet using the app engine broadcast the signed transaction. The recipient independently observed exactly 1.25 unlocked test XMR after 12 mined blocks. [Reproduce the test](Regtest.md)

The wallet was also evaluated against a disposable local Monero regression network. That network activates later protocol rules at height one. A normal mainnet wallet correctly refuses to mark that history synchronized. Real-money transfers and a signed App Store build have not been tested.
