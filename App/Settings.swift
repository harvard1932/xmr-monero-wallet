import SwiftUI

enum ProjectLinks {
    static let source = URL(string: "https://github.com/harvard1932/xmr-monero-wallet")!
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    static let revision = source.appending(path: "tree").appending(path: "v" + version)
    static let verification = source.appending(path: "blob/v" + version + "/Docs/Verification.md")
    static let tor = revision.appending(path: "ThirdParty/Tor")
    static let core = URL(string: "https://github.com/MrCyjaneK/monero_c/tree/v0.18.4.6-RC2")!
}

struct WalletSource: View {
    var body: some View {
        WalletSheet(title: "Open source") {
            Image(systemName: "curlybraces").font(.system(size: 38, weight: .medium)).foregroundStyle(WalletStyle.apricot)
            Text("XMR Monero Wallet - Safe and opensource").font(.largeTitle.weight(.semibold))
            Text("Every screen, wallet operation and build instruction is public. You can read the Swift code, inspect the native engine and build your own copy.")
                .foregroundStyle(WalletStyle.muted)
            WalletLine(label: "App version", value: ProjectLinks.version)
            WalletLine(label: "App license", value: "MIT")
            WalletLine(label: "App fee", value: WalletL10n.text("Free"))
            WalletLine(label: "Independent audit", value: WalletL10n.text("Pending"))
            Divider()
            Text("The wallet uses Monero wallet2 for keys, signatures and fees. The build script checks the native library archive against a pinned SHA-256 digest.")
                .font(.callout).foregroundStyle(WalletStyle.muted)
            Link(destination: ProjectLinks.source) { Label("View project on GitHub", systemImage: "arrow.up.right") }
                .buttonStyle(WalletPrimaryButton())
            Link("Source for this version", destination: ProjectLinks.revision)
            Link("Build and test results", destination: ProjectLinks.verification)
            Link("Inspect the pinned engine", destination: ProjectLinks.core)
            Link("Inspect embedded Tor", destination: ProjectLinks.tor)
            Text("Independent developer preview. Monero network fees apply when you send XMR.")
                .font(.footnote).foregroundStyle(WalletStyle.muted)
        }
    }
}

struct WalletPicker: View {
    @ObservedObject var vault: WalletVault
    @ObservedObject var session: WalletSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        WalletSheet(title: "Your wallets") {
            ForEach(vault.wallets) { wallet in
                Button {
                    dismiss()
                    session.takeOffline()
                    vault.select(wallet)
                } label: {
                    HStack {
                        Image(systemName: "wallet.bifold").foregroundStyle(WalletStyle.apricot)
                        Text(wallet.name).font(.headline)
                        Spacer()
                        if vault.active?.id == wallet.id { Image(systemName: "checkmark") }
                    }.padding().background(WalletStyle.panel, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            Button {
                dismiss()
                session.takeOffline()
                vault.beginAdding()
            } label: { Label("Add a wallet", systemImage: "plus") }.buttonStyle(WalletPrimaryButton())
        }
    }
}

enum SettingsPage: Hashable { case privacy, network, tor, security }

struct WalletSettings: View {
    @ObservedObject var vault: WalletVault
    @ObservedObject var session: WalletSession
    let lock: () -> Void
    var initialPage: SettingsPage?
    @State private var path = [SettingsPage]()
    @State private var backup: VaultBackup?
    @State private var showWords = false
    @State private var showSource = false
    @State private var deleting: Deletion?
    @State private var eraseConfirmation = ""
    @State private var eraseAll = false
    @State private var createdAddress: WalletAddressItem?
    @State private var error: String?
    @State private var busy = false
    @AppStorage("keepAwake") private var keepAwake = false
    @AppStorage("syncActivity") private var liveActivity = false
    @Environment(\.dismiss) private var dismiss

    enum Deletion: String, Identifiable { case one, all; var id: Self { self } }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Monero network") {
                    NavigationLink(value: SettingsPage.network) { Label("Node and sync settings", systemImage: "network") }
                    if let node = session.nodeName { WalletLine(label: "Active node", value: node) }
                }
                Section("Synchronization") {
                    Toggle("Keep screen awake during sync", isOn: $keepAwake)
                    Toggle("Show sync Live Activity", isOn: Binding(get: { liveActivity }, set: configureActivity))
                    if session.chainHeight > 0 {
                        WalletLine(label: "Scanned height", value: "\(session.height) / \(session.chainHeight)")
                    }
                }
                Section("Privacy") {
                    NavigationLink(value: SettingsPage.privacy) {
                        HStack { Label("Privacy Pulse", systemImage: "shield.lefthalf.filled"); Spacer(); Text("\(pulse.score) / 100").foregroundStyle(.secondary) }
                    }
                }
                Section("Wallet security") { security }
                Section { WalletLanguagePicker() }
                Section("Project") {
                    Button { showSource = true } label: { Label("Source code and license", systemImage: "curlybraces") }
                }
                if let error { Section { WalletNotice(text: error) } }
            }
            .scrollContentBackground(.hidden).background(WalletStyle.ink)
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .network, .tor: NetworkSettings(session: session, preselectTor: page == .tor, lock: lock)
                case .privacy:
                    PrivacyPulseView(pulse: pulse) { control in
                        switch control {
                        case .route: path.append(.tor)
                        case .node: path.append(.network)
                        case .backup: revealSeed()
                        case .deviceLock: path.append(.security)
                        case .subaddress:
                            Task {
                                do {
                                    createdAddress = try await session.actions(vault: vault, settings: {}, wallets: {})
                                        .newAddress(WalletL10n.text("Private receiving address"))
                                } catch { self.error = WalletL10n.diagnostic(error) }
                            }
                        }
                    }
                case .security: Form { security }.navigationTitle("Wallet security")
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onAppear { if let initialPage, path.isEmpty { path = [initialPage] } }
        .sheet(isPresented: $showSource) { WalletSource() }
        .sheet(isPresented: $showWords, onDismiss: { backup = nil }) {
            WalletSheet(title: "Recovery backup") {
                if let backup { VaultBackupContent(backup: backup) }
            }
        }
        .sheet(item: $createdAddress) { item in
            WalletSheet(title: "Receiving address") {
                PaymentQR(payload: item.address)
                Text(item.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                ShareLink(item: item.address)
            }
        }
        .onDisappear { backup = nil }
        .sheet(isPresented: $eraseAll) {
            WalletSheet(title: "Erase all app data") {
                Text("This removes every wallet, recovery backup, contact, invoice, Tor cache and setting from this iPhone.")
                TextField("Type DELETE", text: $eraseConfirmation)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Erase all app data", role: .destructive) { erase(.all) }
                    .disabled(eraseConfirmation != "DELETE" || busy)
                if let error { WalletNotice(text: error) }
            }
        }
        .alert(item: $deleting) { choice in
            Alert(title: Text(choice == .all ? "Erase every wallet on this iPhone?" : "Remove this wallet?"),
                  message: Text("You will need your recovery backup to regain access. Local labels, contacts and invoices will be lost."),
                  primaryButton: .destructive(Text("Erase")) { erase(choice) }, secondaryButton: .cancel())
        }
    }

    private var pulse: PrivacyPulse {
        PrivacyPulse(backedUp: vault.active?.backupVerified == true, locked: vault.phase == .unlocked, hasSubaddress: (session.data?.addresses.count ?? 0) > 1, route: session.connection)
    }

    @ViewBuilder private var security: some View {
        WalletPINSettingsButton(vault: vault)
        Button("View recovery backup") { revealSeed() }.disabled(busy)
        Button("Lock wallet", action: lock)
        Button("Remove this wallet", role: .destructive) { deleting = .one }
        Button("Erase all app data", role: .destructive) { eraseConfirmation = ""; error = nil; eraseAll = true }
    }

    private func configureActivity(_ enabled: Bool) {
        guard enabled, let wallet = vault.active else { liveActivity = false; return }
        Task {
            do {
                let location = try await vault.authorizedLocation(for: wallet, reason: WalletL10n.text("Allow this wallet to scan while the Lock Screen is visible."))
                let core = try session.liveEngine()
                try await core.configureRestrictedScan(password: location.password)
                try session.check(core)
                liveActivity = true
            } catch { self.error = WalletL10n.diagnostic(error) }
        }
    }

    private func revealSeed() {
        guard let wallet = vault.active else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let ticket = vault.sessionID
                let value = try await vault.recoveryBackup(for: wallet, nativeSeed: session.readSeed, rawKeys: {
                    try await session.liveEngine().privateKeyBackup()
                })
                try vault.requireCurrent(ticket)
                backup = value
                showWords = true
            } catch { self.error = WalletL10n.diagnostic(error) }
        }
    }

    private func erase(_ choice: Deletion) {
        guard let active = vault.active, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if choice == .all {
                    try await vault.eraseAllFromSettings(close: session.close)
                } else {
                    let ticket = vault.sessionID
                    try await vault.authorizeAction(reason: "Confirm erasing wallet data from this iPhone.")
                    await session.close()
                    try vault.requireCurrent(ticket)
                    try vault.erase(active)
                }
                dismiss()
            } catch { self.error = WalletL10n.diagnostic(error) }
        }
    }
}
