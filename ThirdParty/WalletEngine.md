# Monero wallet engine

The app loads Monero wallet2 in the application process. Signing and wallet scanning run on the device. Each wallet has its own encrypted wallet2 files. The selected daemon receives block requests and broadcast transactions. A user who explicitly authorizes a key-image import also allows that daemon to check which outputs have been spent.

## Source and binary identity

| Component | Pinned input |
| --- | --- |
| C wrapper and wallet patches | [monero_c v0.18.4.6-RC2, commit 3bfb385](https://github.com/MrCyjaneK/monero_c/tree/3bfb3856a838f2bf6b729501837bb0295dedf25d) |
| Upstream wallet2 | [monero-project/monero dbcc7d2](https://github.com/monero-project/monero/tree/dbcc7d212c094bd1a45f7291dbb99a4b4627a96d) |
| Distributed archive | [release-bundle.zip](https://github.com/MrCyjaneK/monero_c/releases/download/v0.18.4.6-RC2/release-bundle.zip) |
| Archive SHA-256 | `94ae3d99f878d1e392b9c49d4c5431e4d0b7780c6177081df5369d05e68cea70` |

`Scripts/prepare-core.sh` verifies the full archive before extracting the arm64 iOS and arm64 Simulator libraries. It assigns the framework install name, adds the framework plist and signs the development framework ad hoc. Xcode re-signs the embedded framework with the application identity when installing on a device. Run the script from a Mac with Xcode. To verify an existing download, set `MONERO_RELEASE_BUNDLE` to its absolute path.

The bundled headers match the pinned source. `monero_wallet2_api_c.h` and `monero_checksum.h` come from the wrapper's `monero_libwallet2_api_c/src/main/cpp/` directory. `wallet2_api.hpp` is Monero's `src/wallet/api/wallet2_api.h` with the wrapper's patches applied, used for virtual calls missing from the C wrapper. The app links the LGPLv3 wrapper dynamically. Its license and the incorporated GPLv3 terms accompany this file. The Monero license appears in `Monero-LICENSE`. Dependencies built into the upstream engine retain their respective notices in the pinned source trees.

To rebuild the engine independently, clone the wrapper at the exact commit above and use its [Docker build](https://github.com/MrCyjaneK/monero_c/blob/3bfb3856a838f2bf6b729501837bb0295dedf25d/builder/Dockerfile) and [release script](https://github.com/MrCyjaneK/monero_c/blob/3bfb3856a838f2bf6b729501837bb0295dedf25d/builder/release.sh). Compare the two resulting iOS dylibs with the corresponding archive members before install-name editing or code signing. This project's verification covered the distribution archive digest, not an independent source-to-binary reproduction. Developers can compile modifications in that source checkout, wrap their libraries in equivalent framework slices and rebuild and sign the app from source in Xcode.

## Network transport

The pinned engine's native HTTP client uses TLS autodetection. In this version that mode may accept an unverified certificate or retry with plaintext, even when given an HTTPS URL. `WalletEngine.connect` therefore rejects direct remote HTTPS traffic. The raw native endpoint must be loopback or a v3 onion service reached through a SOCKS4a-compatible proxy. For onion destinations the proxy resolves the hostname. The engine never falls back from an onion connection to a direct clearnet connection.

The wallet2 base in this wrapper predates Monero v0.18.5.4. The [upstream v0.18.5.0 release](https://github.com/monero-project/monero/releases/tag/v0.18.5.0) includes additional change-address checks and HTTP client authentication fixes. The newer upstream changes need to be evaluated and incorporated where applicable before a production release. A matching archive digest identifies the expected bytes. It does not provide independent security assurance.

## Verification

`TransferIntegrationTests` creates random disposable testnet wallets offline. It verifies a 25-word backup and restore, an address book entry, subaddress persistence, view-only pairing and refusal to prepare an offline spend.

A standard Monero regtest daemon activates protocol v16 at block 1. Production wallet2 checks the real network hard-fork schedule, so a standard fakechain cannot validate the app's mainnet synchronization. Keep the production version checks enabled.
