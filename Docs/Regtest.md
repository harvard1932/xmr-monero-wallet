# Isolated payment tests

On an Apple silicon Mac with Xcode, Python 3 and an internet connection for the three pinned build inputs, run this command from the checkout.

```sh
Scripts/test-regtest.sh
```

The script verifies SHA-256 hashes before extraction and builds the production Swift wallet actor with the arm64 macOS library from the matching signed Cake Wallet release. It runs two private, offline chains in separate temporary directories. The daemon and wallet RPC use password-protected loopback ports. Each scenario creates disposable wallets and mines its own funds. The script removes its temporary directory and services on exit. Its output includes amounts and status.

## Cold signing and invoice receipt

The app creates a dedicated invoice subaddress. On the sending side the harness preserves an empty offline spending wallet, funds a matching wallet on the private chain, and scans it with a view-only wallet. The app exports the outputs as multipart UR, imports them on the signer, returns signed key images, and imports them on the view-only wallet with explicit node trust. The Monero RPC fixture then prepares the unsigned 1.25 XMR payment to the invoice. The app's offline signer reads the QR frames, verifies the destination and displayed amount, signs the payment, and rejects a repeated signature request. A separate view-only app wallet submits the signed frames. After 12 blocks the upstream RPC receiver and the app reading that receiver's cache both verify the amount and unlock state. The app checks that the invoice address received the payment, the primary address received zero, and the transaction has at least ten confirmations. It labels and freezes the received output, reopens the wallet to verify persistence, and thaws the output.

The fakechain activates Monero protocol version 16 at block 1. Only the external fixture wallet RPC uses its upstream regression-testing option for that fork schedule. The app preserves all production fork checks. This scenario covers the app's offline review, signature, broadcast and reading of confirmed receipts.

## Hot send from a selected subaddress

The second daemon starts at testnet genesis with offline mode, zero peers, loopback-only RPC and peer listeners, and fixed mining difficulty one. A fixture miner submits standard block templates through the testnet RPC. The daemon and both wallets use the ordinary testnet fork schedule and perform the usual wallet version checks.

The app generates a disposable seed, restores it with scan height zero and creates subaddress 1 in account 0. The miner pays **3 test XMR to the primary address (index 0)** and **2 test XMR to the subaddress (index 1)**. The app independently scans the private chain, verifies both address balances and selects only spendable outputs belonging to index 1. It also verifies that a rescan refuses frozen outputs and recovers the original funded balances after thawing. It calls production `WalletEngine.prepare` and `commit` for a **0.25 test XMR** payment. After twelve more blocks, upstream wallet RPC confirms the exact transaction ID, recipient amount and unlock state. It independently checks that the sender used account 0, subaddress 1 exclusively.

The hot-wallet fixture also prepares and cancels a full-account sweep and a sweep restricted to the two-XMR subaddress. It checks the exact native amount plus fee against each source balance. A separate payment covers the requested amount on the smaller subaddress but needs the larger one to pay its fee. A final review needs both addresses. The harness checks the actual source count in each prepared transaction. The cold fixture verifies that cancelling a review prevents signing it and that a delayed cancellation preserves a newer review.

Near genesis the genuine testnet schedule runs protocol version 1. This fixture exercises the production wallet's hot-send path and source selection under those historical transaction rules. The fakechain fixture exercises protocol 16 cold review, signing and broadcast. Hot sends under current mainnet rules remain unverified by this harness. Simulator coverage of wallet creation, backups, subaddresses, contacts and offline spending guards is in `TransferIntegrationTests.swift`.

## Inputs

- The official Monero v0.18.5.4 Apple silicon CLI archive supplies the daemon and wallet RPC. The archive checksum is recorded in the script and in the [Monero release hashes](https://www.getmonero.org/downloads/hashes.txt).
- The Apple-signed Monero.com v6.5.4 macOS archive supplies an arm64 wallet library with the same wrapper and Monero v0.18.5.3 revisions as the device engine. The script checks the archive and the thinned library digests. [Engine provenance](../ThirdParty/WalletEngine.md)
- The test compiles the [BC-UR source revision used by monero_c](https://github.com/MrCyjaneK/bc-ur/tree/d82e7c753e710b8000706dc3383b498438795208) to encode the RPC fixture as QR frames.
