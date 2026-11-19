# Verification

Version 0.2.0 was exercised with disposable wallets. The app targets iOS 17 and later on arm64. On the iPhone 17 Pro simulator running iOS 26.5, all 38 XCTest cases passed with zero skips. This run enabled the public HTTPS, real Tor, live price and 100-cycle Tor restart checks. All six JavaScript recovery tests passed. Two additional production interface tests passed on the same iPhone simulator. They covered the recovery choices, PIN enrollment, a view-only restore, address confirmation, node settings, Privacy Pulse and locking and reopening the wallet. The [feature comparison](FeatureCoverage.md) maps the published iPhone features to their entry points.

| Check | What was checked |
| --- | --- |
| Build | Xcode 27.1 built the native wallet, embedded Tor, SwiftUI application, and Live Activity extension for an arm64 iPhone simulator and an unsigned arm64 iPhone Release target. |
| Recovery and migration | XCTest restores public MyMonero and BIP39 vectors to their expected mainnet addresses, round-trips a native testnet wallet, and checks offset and encrypted Polyseed handling. Local JavaScript tests cover all ten BIP39 dictionaries and MyMonero’s active and historical dictionaries. Rebuilding the adapter produced identical bytes. |
| PIN and wallet files | Checks cover PIN envelope tamper detection, persisted retry limits, wallet- and purpose-specific authenticated encryption, migration after interrupted cleanup, full erasure retry, incomplete backups, and invalidated unlock work. On a disposable iOS 17.2 simulator the production PIN store required a fresh biometric match, rejected an attempted unlock with enrollment removed, revoked that opt-in, and accepted PIN fallback. In a remove-and-reenroll sequence with no intervening unlock, Simulator returned the same enrollment hash. Physical hardware must verify Keychain invalidation for that case. |
| Network isolation | A new wallet begins offline, and one wallet’s selected node cannot automatically connect a new signer. Tests cover old settings migration, public-node retry policy, TLS relay authentication, and rejection of direct probing or clearnet destinations in Tor mode. |
| Tor and active scans | Tests exercise a real embedded Tor circuit, a public onion daemon, encrypted cache save/reopen, and a restricted scan that denies access to recovery words. Native stress checks also repeatedly start and stop the Tor runtime in one process. [Tor details](../ThirdParty/Tor/README.md) |
| Payments and invoice receipts | The isolated chain test exchanges outputs and signed key images, reviews and signs a payment offline, broadcasts it from a view-only wallet, and verifies that the intended invoice received exactly 1.25 unlocked test XMR. A label and freeze survive a restart, and the received output can be thawed. A separate private testnet verifies a direct 0.25 test XMR send using only outputs from the selected subaddress. [Reproduce the test](Regtest.md) |
| Interface and translations | The localization validator checks key coverage, formatting arguments, permission text, and compiled resources in 23 languages. Machine-assisted translations are marked for native-speaker review. |
| Price chart | The parser checks candle values and the four selectable periods. The live test requests the same XMR/USD endpoint used by the iPhone chart after opt-in. |

## Reproduce the checks

Run both dependency preparation scripts in the [build instructions](../README.md#build-and-run). Use **Product → Test** with the **XMRMoneroWallet** scheme. The ordinary tests run locally. Set these variables in the scheme’s **Test** environment to exercise the corresponding network paths with disposable wallets.

| Variable | Additional coverage |
| --- | --- |
| `XMR_LIVE_NODE_TEST=1` | Public HTTPS and locking the wallet during an active public-node scan. |
| `XMR_LIVE_TOR=1` | Bootstrap built-in Tor and connect an empty native wallet to an onion daemon. |
| `XMR_LIVE_MARKET=1` | Fetch, parse and check the time of the latest intraday XMR/USD candle. |

You can also pass the switches as Xcode build settings. Replace the simulator name with one installed on your Mac.

```sh
xcodebuild -scheme XMRMoneroWallet -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  XMR_LIVE_NODE_TEST=1 XMR_LIVE_TOR=1 XMR_LIVE_MARKET=1 test
```

Use the **WalletUIFlows** scheme on a disposable iPhone simulator with device authentication available. Set `XMR_UI_TEST_DISPOSABLE=1` to opt into the PIN-enrollment, view-only restore and navigation flow. The fixture uses public test material and creates a local wallet. Run on a separate installation reserved for testing.

## Release work

Physical Face ID enrollment changes, passcode removal, camera-to-camera QR transfer, and Live Activity delivery across physical Lock Screen and power-management transitions still require iPhone testing. The cold-payment fixture uses protocol 16. The direct hot-send fixture starts at testnet genesis under protocol 1 and exercises production preparation, signing and submission. A modern-protocol funded hot send still needs verification. The app and its binary dependencies need independent security review and source-to-binary reproduction. The pinned wallet2 base predates newer upstream security changes. [Engine review](../ThirdParty/WalletEngine.md)
