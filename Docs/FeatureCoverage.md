# iPhone feature comparison

This comparison follows the published iPhone feature list and the developer’s support instructions. It covers features a user can access in this project. The reference app’s private implementation is unavailable for comparison. [Reference App Store listing](https://apps.apple.com/us/app/monero-wallet-xmr/id6814596825) · [Reference support](https://monerowallet.app/support)

| Feature | Where to use it in this app | Implementation and checks |
| --- | --- | --- |
| Create a self-custody wallet | Welcome → Create wallet | Native wallet2 creates a classic 25-word wallet locally. Two randomly chosen words must match the written backup before first entry. |
| Keep separate wallets | Overview → wallet name → Add a wallet | Each wallet has a separate encrypted file, password, primary address, balances, history, contacts and invoice records. Switching invalidates the previous session. |
| Restore by words or keys | Restore wallet → recovery method | Supports classic 25-word seeds with optional offsets, 13-word MyMonero across its supported dictionaries, 16-word Polyseed, supported BIP39, private spend/view keys, and address plus private view key. The result shows the primary address for confirmation. [Exact formats and migration details](../Recovery/README.md) |
| Receive and share a QR | Overview → Receive → New subaddress | A primary address and each labeled subaddress have their own QR, copy and share controls. |
| Send Monero | Overview → Send or Scan | Accepts pasted addresses, contacts, QR codes and Monero payment requests. Choose a fee priority, review the recipient, exact amount, fee and total, then swipe and authenticate. View-only wallets can export the unsigned payment. |
| Balances and history | Overview and Activity → select a payment | Native balances distinguish unlocked and locked funds. Transaction details show status, confirmations, fee and transaction hash. |
| Automatic nodes and failover | Tap the node in the header → Public nodes | In direct mode, concurrent health probes select the fastest available healthy response. A stalled scan or lost connection triggers another candidate. Tor mode selects from onion nodes without direct probes. |
| Custom node and Tor | Node and sync settings → My node or Route through Tor | Use your own HTTPS daemon, an on-device daemon, or a v3 onion node. Tor can bootstrap inside the app. An existing local SOCKS proxy is also supported. [Transport and privacy](../SECURITY.md) |
| Keep awake and Lock Screen progress | Settings → Synchronization | Opt into keeping the display on during scans or viewing heights in a Live Activity. The app locks and runs a restricted scan during available iOS background time. The activity displays a paused state when the scan stops. |
| Coin control | Tools → Coin control, or Send → inputs | See individual unspent outputs, label, freeze or thaw them. The transaction builder accepts selected key images and the corresponding source subaddresses. |
| Cold signing | Tools → Cold signing and Restore wallet → View only | Pair using address and view key, move outputs and signed key images, review the unsigned transaction on the offline signer, and broadcast the signed result from the online wallet. Uses wallet2 multipart UR. [Isolated payment test](Regtest.md) |
| Invoices | Tools → Invoices | Create a dedicated subaddress and a QR with the requested amount. Its incoming funds determine awaiting, partially paid and paid status. Spending a receipt keeps the amount received on that invoice. |
| Privacy Pulse | Tools → Privacy Pulse, or Settings → Privacy | Five visible controls contribute 20 points each. Unmet checks lead directly to backup, lock, Tor, node selection or a new receiving subaddress. The score measures local choices. |
| Contacts | Tools → Contacts, or Send → Contacts | Save and remove local address-book entries, choose a recipient and initiate a payment. |
| Live price chart | Tools → XMR price | On a direct online route, opt into Kraken XMR/USD prices. Switch between four time ranges, pause, refresh and see when the chart last updated. The chart refreshes every 30 seconds while visible. |
| Interface languages | Welcome → globe or Settings → Language | Ships 23 languages, including all languages named on the reference listing. Arabic uses a right-to-left layout and confirmation gesture. The catalog flags machine-assisted translations for human review. [Language coverage](../Localization/README.md) |
| PIN and Face ID | During setup and Settings → Wallet security | The PIN protects the wallet unlock key. Users can enroll biometrics, change their PIN, and reset it using the device passcode. Backgrounding locks the wallet. |
| Encrypted recovery backup | Settings → View recovery backup | Fresh authentication reveals the original recovery material for new imports. Older wallet files expose their native backup material. Seed passphrases must be retained separately. |
| Delete all data | Settings or the locked screen → erase all → type DELETE | The app authenticates, clears wallet files, recovery credentials, Tor state and preferences, and can resume an interrupted full erase. |

For the distinction between features implemented, checks run with disposable wallets and release work that needs physical iPhones, see [verification results](Verification.md).
