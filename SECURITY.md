# Security and privacy

This is a developer preview. The application, native bridge and packaged dependencies have not received an independent security audit. Use disposable wallets while evaluating the code. Public source makes independent review possible.

## Reporting a problem

Use [GitHub private vulnerability reporting](https://github.com/harvard1932/xmr-monero-wallet/security/advisories/new) for security issues. Include the commit, device and iOS version, and the behavior you observed. Keep seed words, wallet files, view keys, transaction QR frames and access tokens private.

## What stays on the phone

* Wallet2 creates keys, scans blocks and prepares and signs transactions locally. Each encrypted wallet has a random password held in the iOS Keychain under a device-passcode and user-presence policy. The app asks iOS to authenticate the owner on unlock and when revealing recovery information.
* Wallet files, contacts, output labels and invoice records are local. Wallet directories use complete iOS file protection and are excluded from device backups. Wallet names and backup status live in a device-protected local manifest. Invoice data is encrypted with a key derived from the individual wallet password.
* The app obscures the switcher preview, locks when backgrounded and disallows third-party keyboards. A written recovery backup is essential if the device, its passcode or its Keychain credential is lost. Device compromise and photographs of recovery words remain outside these protections.
* The privacy checks report configured controls. They cannot establish anonymity. A view-only pairing QR grants access to incoming transaction information. An offline signer should stay offline on a separate device throughout its life.

## Network behavior

New installations start offline. In Settings, public-node mode checks the available endpoints and selects a responding node. Custom mode lets the owner choose a daemon. A direct connection exposes the device IP and the timing of scans or broadcasts to the node. Connecting to a remote node does not send a seed or a spend key.

Public HTTPS connections pass through an authenticated loopback relay and Apple's normal hostname and certificate checks. The native adapter refuses direct remote HTTPS because the pinned wallet2 client can accept unverified certificates under TLS autodetection. The relay forwards requests to the selected HTTPS origin, blocks redirects, and discards request credentials before forwarding. The native wallet treats the daemon as untrusted, including the relay.

Tor routing requires a working Tor SOCKS proxy on the iPhone. With it enabled, the app skips all HTTPS probes and connects exclusively to v3 onion nodes through wallet2’s explicit native SOCKS4a transport. It has no direct-network fallback. Automatic mode uses a built-in pair of onion addresses from the [Feather node directory](https://github.com/feather-wallet/feather-nodes/blob/5a1bd38a0a34c4de02ea034a2c4ed224005d2bbe/nodes.yaml). Importing signed key images requires a custom node and explicit approval to query spent status.

The optional market chart contacts Kraken only after a user requests prices. It is unavailable offline or with proxy routing selected. Live Activities are optional and display blockchain heights on the Lock Screen. The source links open GitHub in the user's browser.

## Dependency review

Review the engine version, its differences from current Monero releases and the binary verification process in [the engine notes](ThirdParty/WalletEngine.md). Review legacy recovery code, test fixtures and package pins in [Recovery](Recovery/README.md). A matching download digest establishes which artifact is used. An independent rebuild and source-to-binary comparison are separate verification steps.
