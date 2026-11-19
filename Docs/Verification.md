# Verification

The app targets arm64 iPhones running iOS 17 or later. Version 0.3.0 was checked on an iPhone 17 Pro simulator running iOS 26.5 and on isolated chains using disposable wallets. The UI checks used a separate bundle identifier. The project’s [feature comparison](FeatureCoverage.md) records the reference screens, known differences and hardware checks that remain open.

On November 18, 2026, the full native suite passed **48 of 48 tests** with the source-built Monero 0.18.5.3 simulator engine, real Tor and HTTPS nodes, live CoinGecko data and the 100-cycle Tor test enabled. Both production UI tests passed on the same model with zero skips, and all six JavaScript recovery tests passed. Xcode built the arm64 iPhone Release target with the signed-distribution device engine. The same public recipe also compiled wallet2 for both arm64 iPhone and Simulator. Framework packaging verified the platform for each slice. The isolated-chain tests confirmed the exact hot and cold transfer amounts in independent recipient wallets. All test funds were disposable.

The UI runs exercised view-only restore and address confirmation on a disposable installation, then reopening, receiving, photo-scan entry, activity filters, the privacy view, light/dark appearance and locking. The operating system’s photo picker and the generated QR image test cover different stages. A physical iPhone camera and an independent spending-wallet audit remain outstanding.

| Check | What was checked |
| --- | --- |
| Build | Xcode 27.1 built the native wallet, embedded Tor, SwiftUI application, and Live Activity extension for an arm64 iPhone simulator and an unsigned arm64 iPhone Release target. |
| Recovery and migration | XCTest restores public MyMonero and BIP39 vectors to their expected mainnet addresses, round-trips a native testnet wallet, and restores an encrypted Polyseed using the production wallet2 import path and compares its primary address with an independent fixture. Local JavaScript tests cover all ten BIP39 dictionaries and MyMonero’s active and historical dictionaries. Rebuilding the adapter produced identical bytes. |
| PIN and wallet files | Checks cover PIN envelope tamper detection, persisted retry limits, wallet- and purpose-specific authenticated encryption, migration after interrupted cleanup, full erasure retry, incomplete backups, and invalidated unlock work. On a disposable iOS 17.2 simulator the production PIN store required a fresh biometric match, rejected an attempted unlock with enrollment removed, revoked that opt-in, and accepted PIN fallback. In a remove-and-reenroll sequence with no intervening unlock, Simulator returned the same enrollment hash. Physical hardware must verify Keychain invalidation for that case. |
| Network isolation | A new wallet begins offline, and one wallet’s selected node cannot automatically connect a new signer. Tests cover old settings migration, route-specific public-node pins, failover policy, TLS relay authentication, and a loopback server verifying the requested v3 onion hostname and daemon response through SOCKS4a. |
| Tor and active scans | Tests exercise a real embedded Tor circuit, a public onion daemon, encrypted cache save/reopen, and a restricted scan that denies access to recovery words. Native stress checks also repeatedly start and stop the Tor runtime in one process. [Tor details](../ThirdParty/Tor/README.md) |
| Payments and invoice receipts | The isolated chain test exchanges outputs and signed key images, reviews and signs a payment offline, broadcasts it from a view-only wallet, and verifies that the intended invoice received exactly 1.25 unlocked test XMR. A label and freeze survive a restart, and the received output can be thawed. A separate private testnet verifies a direct 0.25 test XMR send with the selected subaddress. Further checks cover fee-adjusted Max, single-address funding and fallback, cancelled signing reviews, rescan and frozen-output protection. [Reproduce the test](Regtest.md) |
| QR and activity | A generated QR image is read through the iPhone photo-decoding path. Tests cover exact requested atomic amounts, ambiguous QR rejection, native notes across reopen, wallet isolation, direction filters and history totals. |
| Interface and translations | The localization validator checks key coverage, formatting arguments, permission text, and compiled resources in 23 languages. Machine-assisted translations are marked for native-speaker review. |
| Price chart | Tests cover the four CoinGecko chart requests, per-transaction USD display, rejection of stale spot quotes, and a live intraday price query. |

## Reproduce the checks

Run both dependency preparation scripts in the [build instructions](../README.md#build-and-run). Use **Product → Test** with the **XMRMoneroWallet** scheme. The ordinary tests run locally. Set these variables in the scheme’s **Test** environment to exercise the corresponding network paths with disposable wallets.

| Variable | Additional coverage |
| --- | --- |
| `XMR_LIVE_NODE_TEST=1` | Public HTTPS and locking the wallet during an active public-node scan. |
| `XMR_LIVE_TOR=1` | Bootstrap built-in Tor and connect an empty native wallet to an onion daemon. |
| `XMR_LIVE_MARKET=1` | Fetch, parse and check the time of the latest intraday XMR/USD sample. |
| `XMR_TOR_STRESS=1` | Exercise 100 start/stop cycles of the embedded Tor runtime. |

You can also pass the switches as Xcode build settings. Replace the simulator name with one installed on your Mac.

```sh
xcodebuild -scheme XMRMoneroWallet -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  XMR_LIVE_NODE_TEST=1 XMR_LIVE_TOR=1 XMR_LIVE_MARKET=1 XMR_TOR_STRESS=1 test
```

Use the **WalletUIFlows** scheme on a disposable iPhone simulator with device authentication available. Set `XMR_UI_TEST_DISPOSABLE=1` to opt into the PIN-enrollment, view-only restore and navigation flow. The fixture uses public test material and creates a local wallet. Run on a separate installation reserved for testing.

## Release work

Physical Face ID enrollment changes, passcode removal, camera-to-camera QR transfer, and Live Activity delivery across physical Lock Screen and power-management transitions still require iPhone testing. The cold-payment fixture uses protocol 16. The direct hot-send fixture starts at testnet genesis under protocol 1 and exercises production preparation, signing and submission. A modern-protocol funded hot send still needs verification. Independent reviewers still need to examine the app and its dependencies, and reproduce the distributed iPhone binary from source. The device library embeds Monero v0.18.5.3. The latest v0.18.5.4 daemon DNSSEC and RPC JSON changes remain outside this binary. The arm64 Simulator library is built for Simulator from the same wrapper and Monero source revisions. [Engine review](../ThirdParty/WalletEngine.md)
