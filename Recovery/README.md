# Recovery formats

Classic 25-word Monero seeds support a native seed offset. The bundled Polyseed decoder verifies 16-word phrases, including standard encrypted Polyseeds. An explicit recovery setting also supports a plaintext Polyseed with the originating wallet’s Monero seed offset. After import the app displays the derived primary address so the owner can compare it with the original. [Polyseed source revision and license](../ThirdParty/Polyseed-NOTICE) Two older formats use a local JavaScriptCore context with bundled code. It has no host network or filesystem bridge.

* **MyMonero** accepts 13 complete words including the checksum. It recognizes simplified Chinese, Dutch, English, Esperanto, French, German, Italian, Japanese, Lojban, Portuguese, Russian, Spanish and the historical EnglishOld decoder. EnglishOld retains the original decoder’s handling of duplicate four-letter prefixes. Inspect the derived address when recovering an old phrase. It derives the original spend and view keys independently from the unreduced spend hash. Wallet2 checks the keys against the primary address. Keep the original phrase for future restores. [Public key and address fixtures](https://github.com/moneroexamples/mymonero-keys/blob/33e9d2f047e05e2674000814cfb9b1cab8148c2f/README.md#example-1)
* **Exodus / Cake BIP39** supports all ten standard BIP39 wordlists, a BIP39 passphrase, and account 0 at `m/44'/128'/0'/0/0`. It converts to a standard 25-word Monero mnemonic, which wallet2 restores. A different BIP39 passphrase creates a different valid wallet. Verify the primary address against the original wallet. Other paths and hardware-wallet derivations require their own recovery method. [Cake Wallet implementation and fixtures](https://github.com/cake-tech/cake_wallet/blob/0b121b07217ddaa5e3a886e95d2393286728b59d/cw_monero/test/bip39_seed_test.dart) · [Independent primary address fixture](https://github.com/ManyMath/monero-rust/blob/4403c7b3397f049d0661d628e9c50d7208b74e80/rust/monero-rust/tests/bip39_conv_test.rs)

The adapter uses the pinned scure and noble libraries for BIP32, BIP39, Keccak, Edwards arithmetic, and Monero Base58. The English Monero list comes from the [Monero 0.18.4.3 English dictionary](https://github.com/monero-project/monero/blob/7c6e84466a90f6701ebe09ff8f61ea8af3883181/src/mnemonics/english.h). MyMonero's recognition order, dictionary prefixes and word lists come from its pinned core. The twelve active-language test phrases were encoded and decoded by the official `@mymonero/mymonero-monero-client@3.0.3` WebAssembly implementation using its public 16-byte test seed. The same implementation also decoded the EnglishOld fixture. [MyMonero legacy entry point](https://github.com/mymonero/mymonero-core-cpp/blob/9637c91cbe5f46e67156c66c739932294808109d/src/monero_wallet_utils.cpp) · [Pinned dictionaries and reference decoder](https://github.com/mymonero/monero-core-custom/tree/d0d4ec2c99a1db96518a98ff47773d76cf729d84/mnemonics) · [Reference WebAssembly package](https://www.npmjs.com/package/@mymonero/mymonero-monero-client/v/3.0.3)

To check the vendored dictionaries, run `python3 import-dictionaries.py` in this directory. It verifies each pinned header’s SHA-256 and regenerates the readable JSON in the upstream decoder’s language order. Supply `--local /path/to/mnemonics` to use an existing checkout offline.

Redistribution notices are in `ThirdParty/Recovery-NOTICES.txt`.

With Node 22.22 or later and npm, run the following here to inspect or rebuild the packaged code.

```sh
npm ci --ignore-scripts
npm test
npm run build
git diff --exit-code -- ../Resources/legacy-recovery.js
```

The iOS test suite additionally checks both public mainnet addresses by opening the derived wallets with native wallet2, offline. Starting in 0.2, a new import keeps its original words or key material encrypted on this iPhone. Viewing the backup requires fresh authentication. A passphrase is kept separately by the owner. A 0.1 wallet can reveal whatever its native wallet file retained. An earlier BIP39 import can yield its equivalent Monero words, and an earlier MyMonero import can yield its spend and view keys. Recovering the original BIP39 or MyMonero words in those cases requires the owner’s original copy.
