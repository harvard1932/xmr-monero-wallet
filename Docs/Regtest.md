# Isolated payment test

On an Apple silicon Mac with Xcode, Python 3 and an internet connection for the three pinned build inputs, run this command from the checkout.

```sh
Scripts/test-regtest.sh
```

The script verifies SHA-256 hashes before extraction and builds the production Swift wallet actor with the arm64 macOS slice of the same wallet2 archive used on iPhone. It starts a private offline fakechain and wallet RPC on random, password-protected loopback ports. It makes fresh disposable wallets, mines test funds, and removes its temporary directory and services on exit. It prints amounts and status. No wallet seeds are printed.

The Monero RPC fixture creates the unsigned 1.25 XMR payment. The app's offline signer reads the QR frames, verifies the destination and displayed amount, signs the payment, and rejects a repeated signature request. A separate view-only app wallet submits the signed frames. After 12 blocks the upstream RPC receiver and the app reading that receiver's cache both verify the amount and unlock state.

The fakechain activates Monero protocol version 16 at block 1. Only the external fixture wallet RPC uses its upstream regression-testing option for that fork schedule. The app preserves all production fork checks. This test covers the app's offline review, signature, broadcast and reading of confirmed receipts. It does not exercise hot-wallet transaction preparation or app-side scanning of fakechain blocks. Simulator coverage of wallet creation, backups, subaddresses, contacts and offline spending guards is in `TransferIntegrationTests.swift`.

## Inputs

- The official Monero v0.18.5.4 Apple silicon CLI archive supplies the daemon and wallet RPC. The archive checksum is recorded in the script and in the [Monero release hashes](https://www.getmonero.org/downloads/hashes.txt).
- The wallet framework is the same [monero_c release and pinned source used in the app](../ThirdParty/WalletEngine.md).
- The test compiles the [BC-UR source revision used by monero_c](https://github.com/MrCyjaneK/bc-ur/tree/d82e7c753e710b8000706dc3383b498438795208) to encode the RPC fixture as QR frames.
