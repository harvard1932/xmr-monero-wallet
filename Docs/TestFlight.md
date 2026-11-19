# TestFlight beta

XMR Monero Wallet 0.4.0 (4) targets iPhone on iOS 17 and later. The public repository contains the app, the engine build instructions and the [feature comparison](FeatureCoverage.md). A working invitation is issued by App Store Connect after a build has been processed and made available to a testing group.

## Beta description

XMR Monero Wallet is a free, open-source, self-custody wallet. Create or restore a wallet on your iPhone, receive and request payments with subaddresses and QR codes, and review activity. Choose a public or personal Monero node, connect through Tor or stay offline. This developer preview is intended for disposable wallets. An independent security audit is pending.

## What to test

1. Use a disposable wallet. Set an app PIN, write down the generated recovery words and complete the backup quiz. Keep the words private.
2. On the Wallet tab, open Receive and enter an amount. Check that sharing produces a Monero payment request for the selected address and amount.
3. Open Store, create an invoice and open its QR. Open Activity to try the direction filters and search.
4. Open Market. On a direct online route, enable prices to see the XMR/USD chart. In Settings, choose an appearance and inspect the source and security links.
5. Lock the wallet and unlock it with the app PIN. Report the app version, iOS version and the step that produced any issue. Leave recovery words, private keys, wallet files and private transaction details out of feedback.

## Review notes

No app account, purchase, deposit or real funds are needed for the steps above. Wallet creation requires a device passcode. Choosing Offline during setup allows local wallet creation, addresses and invoices. Sending a payment requires an online synchronized wallet with spendable funds. The app charges no service fee. Monero network fees appear during payment review.

The distributing organization manages signing for both `io.github.harvard1932.xmrwallet` and its `.sync` extension. Use that organization's App Store Connect record to answer Apple's encryption questionnaire for the bundled Monero and Tor libraries. A public beta goes through Apple's external testing group and Beta App Review. [Apple’s wallet rules](https://developer.apple.com/app-store/review/guidelines/#cryptocurrencies) · [Export compliance for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/) · [External TestFlight invitations](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
