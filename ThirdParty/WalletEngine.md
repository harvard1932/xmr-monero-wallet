# Monero wallet engine

Wallet2 runs in the app process. It creates and signs transactions and scans blocks on the device. Each wallet has encrypted native files. The selected daemon receives block requests and broadcasts. An explicitly authorized key-image import also allows that daemon to check spent outputs.

## Source and artifacts

| Component | Pinned input |
| --- | --- |
| Native distributor | [Cake Wallet / Monero.com v6.5.4 release](https://github.com/cake-tech/cake_wallet/releases/tag/v6.5.4) |
| C wrapper and patches | [monero_c 33671871de3d51696b66ffb3bd94f744e26974f6](https://github.com/MrCyjaneK/monero_c/tree/33671871de3d51696b66ffb3bd94f744e26974f6) |
| Monero wallet2 | [v0.18.5.3, 22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0](https://github.com/monero-project/monero/tree/22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0) |
| iPhone archive | `Monero_com_v6.5.4.ipa`, SHA-256 `2a486dbdd4edb1eaee35ebf59babf29e4689c2f063878a03aef6ef018f2a89c2` |
| iPhone framework executable in the archive | SHA-256 `0367554b764f1b6d07bce64187c938f3570c86b44b40c5e3b3534ca146a33d7b` |
| Matching macOS archive for the transfer harness | `Monero_com_v6.5.4.dmg`, SHA-256 `12609942cb06af45e02fdd1968b99c079601645b8299214f37d59edc8d5ee724` |
| Arm64 macOS dylib after thinning | SHA-256 `3d0786038cbe65ad0c5ecac510f22784afc9de47979ca474f28ba618cebff9a4` |
| Patched C++ API header | SHA-256 `0338bb84858c5140e2326dc77dea842668058544f53670dde19c5c2fb88ae229` |

On a Mac with Xcode, run `Scripts/prepare-core.sh`. It verifies the iPhone archive, the original Apple distribution signature from Cake Technologies, LLC (team `32J6BB6VUS`), the embedded library digest and the project's patched C++ header before packaging. Xcode signs the embedded framework with the application identity for device installation. Set `MONERO_IOS_ARCHIVE` to reuse a downloaded IPA. The transfer harness accepts an existing DMG via `MONERO_MAC_ARCHIVE`. [Preparation script](../Scripts/prepare-core.sh) · [Transfer harness](../Scripts/test-regtest.sh)

Cake's device library and its signed arm64 macOS library expose the Monero APIs used here and embed the wrapper's C header, C implementation, export list and Monero revision identifiers. The C header still matches byte for byte. The patched C++ interface adds a virtual method compared with the previous release, so the included header must be upgraded together with the library. The wrapper is dynamically linked under LGPLv3. Its license, the GPLv3 terms and the Monero license accompany the source. [Cake's wrapper pin](https://github.com/cake-tech/cake_wallet/blob/v6.5.4/scripts/prepare_moneroc.sh) · [Wrapper source identifiers](https://github.com/MrCyjaneK/monero_c/blob/33671871de3d51696b66ffb3bd94f744e26974f6/monero_libwallet2_api_c/src/main/cpp/monero_checksum.c)

## Simulator and independent builds

The Simulator slice is compiled from the pinned wrapper and Monero source using an arm64 iOS Simulator target. The build script produces a native Mach-O library from the same patched wallet and wrapper as the iPhone library, linking platform-specific dependencies from SHA-256-pinned archives. The wallet implementation and Apple SDK are compiled for their respective platforms. To package a trusted local source build, set `MONERO_SIMULATOR_LIBRARY` or `MONERO_DEVICE_LIBRARY` to its path. Packaging checks each slice’s architecture, actual Mach-O platform and embedded wrapper/Monero revision, and prints its SHA-256. These explicit local overrides use the developer’s own build provenance. [Apple source build and dependency manifest](../Scripts/AppleCore/README.md)

Cake's separately published CI device build has the same embedded wrapper identifiers as the distribution-signed release and distinct machine code. An independent reproducible build of the production device library and tests on physical hardware remain outstanding. [Cake iOS build configuration](https://github.com/cake-tech/cake_wallet/blob/v6.5.4/scripts/ios/docker/build.sh)

For an independent source build, check out the wrapper commit above, initialize its Monero submodule at the pinned revision and apply the wrapper’s patches with `apply_patches.sh monero`. The upstream builder supports `build_single.sh monero` for `aarch64-apple-ios`, `aarch64-apple-ios-simulator` and `aarch64-apple-darwin`. Compare release libraries before install-name edits or code signing. Preserve the matching C and C++ headers when compiling a modified engine. [Upstream builder](https://github.com/MrCyjaneK/monero_c/blob/33671871de3d51696b66ffb3bd94f744e26974f6/builder/Dockerfile)

## Security updates

The engine includes Monero's v0.18.5.0 change-address check, the v0.18.5.1 remote-daemon protections and v0.18.5.3 validation improvements for cold signing and output import. Monero v0.18.5.4 subsequently updated daemon DNSSEC checks and RPC JSON parsing. All 21 wrapper patches applied to v0.18.5.4 in an isolated checkout, and the resulting headers passed bridge compilation checks for arm64 iPhone and Simulator. Building and running v0.18.5.4 libraries is still pending. [v0.18.5.0 release](https://www.getmonero.org/2026/05/11/monero-0.18.5.0-released.html) · [v0.18.5.1 release](https://www.getmonero.org/2026/07/08/monero-0.18.5.1-released.html) · [v0.18.5.3 release](https://www.getmonero.org/2026/10/06/monero-0.18.5.3-released.html) · [v0.18.5.4 release](https://www.getmonero.org/2026/10/16/monero-0.18.5.4-released.html)

## Lifecycle and transport

Before storing the cache, switching nodes or closing, the Swift actor pauses native refresh, sets the client offline and drains the worker. Locked-screen scanning uses wallet2's spend-key-removing background mode. The bridge calls the matching C++ setup and status methods directly because the pinned C facade hardcodes the background mode and its status accessor calls `hasUnknownKeyImages()`. [Bridge](../Core/MoneroBridge.cpp) · [Wallet lifecycle](../Core/WalletEngine.swift) · [C wrapper](https://github.com/MrCyjaneK/monero_c/blob/33671871de3d51696b66ffb3bd94f744e26974f6/monero_libwallet2_api_c/src/main/cpp/monero_wallet2_api_c.cpp)

Public HTTPS RPC passes through the authenticated loopback relay, where Apple's URL loading system checks the server certificate and hostname. The native endpoint must be loopback or a v3 onion service reached through the configured SOCKS proxy. The proxy resolves onion names. The app also marks the daemon untrusted. [Network transport](../SECURITY.md)

An isolated compatibility check opened a disposable encrypted testnet wallet created by v0.18.4.6 with the new v0.18.5.3 library and verified its primary address, subaddress and saved label. Disposable-wallet integration tests cover backup and restore, subaddresses, watch-only pairing, transaction review and private-chain broadcasts. For the networks, rules and limitations of each fixture, see [transfer verification](../Docs/Regtest.md).
