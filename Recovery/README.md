# Recovery formats

Classic 25-word Monero seeds and 16-word Polyseed phrases go directly to wallet2. Two older formats use a local JavaScriptCore context with bundled code. It has no host network or filesystem bridge.

* **MyMonero** supports the 13 complete English words including the checksum. It derives the original spend and view keys independently from the unreduced spend hash. Wallet2 checks the keys against the primary address. Keep the original phrase for future restores. [Public key and address fixtures](https://github.com/moneroexamples/mymonero-keys/blob/33e9d2f047e05e2674000814cfb9b1cab8148c2f/README.md#example-1)
* **Exodus / Cake BIP39** supports the English wordlist, a BIP39 passphrase, and account 0 at `m/44'/128'/0'/0/0`. It converts to a standard 25-word Monero mnemonic, which wallet2 restores. A different BIP39 passphrase creates a different valid wallet. Verify the primary address against the original wallet. Other paths and hardware-wallet derivations require their own recovery method. [Cake Wallet implementation and fixtures](https://github.com/cake-tech/cake_wallet/blob/0b121b07217ddaa5e3a886e95d2393286728b59d/cw_monero/test/bip39_seed_test.dart) · [Independent primary address fixture](https://github.com/ManyMath/monero-rust/blob/4403c7b3397f049d0661d628e9c50d7208b74e80/rust/monero-rust/tests/bip39_conv_test.rs)

The adapter uses the pinned scure and noble libraries for BIP32, BIP39, Keccak, Edwards arithmetic, and Monero Base58. The English Monero list comes from the [Monero 0.18.4.3 English dictionary](https://github.com/monero-project/monero/blob/7c6e84466a90f6701ebe09ff8f61ea8af3883181/src/mnemonics/english.h). Redistribution notices are in `ThirdParty/Recovery-NOTICES.txt`.

With Node 22.22 or later and npm, run the following here to inspect or rebuild the packaged code.

```sh
npm ci --ignore-scripts
npm test
npm run build
git diff --exit-code -- ../Resources/legacy-recovery.js
```

The iOS test suite additionally checks both public mainnet addresses by opening the derived wallets with native wallet2, offline. The original legacy phrases are used only during import. A MyMonero imported key pair cannot be exported as a standard 25-word seed.
