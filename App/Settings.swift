import SwiftUI

enum ProjectLinks {
    static let source = URL(string: "https://github.com/harvard1932/xmr-monero-wallet")!
    static let core = URL(string: "https://github.com/MrCyjaneK/monero_c/tree/v0.18.4.6-RC2")!
}

struct WalletSource: View {
    var body: some View {
        WalletSheet(title: "Open source") {
            Image(systemName: "curlybraces").font(.system(size: 38, weight: .medium)).foregroundStyle(WalletStyle.apricot)
            Text("XMR Monero Wallet - Safe and opensource").font(.largeTitle.weight(.semibold))
            Text("Every screen, wallet operation and build instruction is public. You can read the Swift code, inspect the native engine and build your own copy.")
                .foregroundStyle(WalletStyle.muted)
            WalletLine(label: "App license", value: "MIT")
            WalletLine(label: "App fee", value: "Free")
            WalletLine(label: "Independent audit", value: "Pending")
            Divider()
            Text("The wallet uses Monero wallet2 for keys, signatures and fees. The build script checks the native library archive against a pinned SHA-256 digest.")
                .font(.callout).foregroundStyle(WalletStyle.muted)
            Link(destination: ProjectLinks.source) { Label("View project on GitHub", systemImage: "arrow.up.right") }
                .buttonStyle(WalletPrimaryButton())
            Link("Inspect the pinned engine", destination: ProjectLinks.core)
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

struct WalletSettings: View {
    @ObservedObject var vault: WalletVault
    @ObservedObject var session: WalletSession
    let lock: () -> Void
    @State private var prefs = ConnectionSettings()
    @State private var words: String?
    @State private var showWords = false
    @State private var showSource = false
    @State private var deleting: Deletion?
    @State private var error: String?
    @State private var busy = false
    @AppStorage("keepAwake") private var keepAwake = false
    @AppStorage("syncActivity") private var liveActivity = false
    @Environment(\.dismiss) private var dismiss

    enum Deletion: String, Identifiable { case one, all; var id: Self { self } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Connection", selection: $prefs.mode) {
                        ForEach(ConnectionMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if prefs.selection == .custom {
                        TextField("https://node.example:18081", text: $prefs.endpoint).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().keyboardType(.URL)
                    }
                    if prefs.selection != .offline {
                        Toggle("Use local Tor proxy", isOn: $prefs.useProxy)
                        if prefs.useProxy {
                            TextField("127.0.0.1:9050", text: $prefs.proxy)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Text("Start a Tor SOCKS proxy on this iPhone. Tor mode connects only to v3 onion nodes.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button("Apply and lock wallet") {
                        do { try session.saveConnection(prefs); lock() } catch { self.error = error.localizedDescription }
                    }.disabled(prefs == session.connection)
                    if let node = session.nodeName { WalletLine(label: "Active node", value: node) }
                    if let problem = session.problem { WalletNotice(text: problem) }
                } header: { Text("Monero network") } footer: {
                    Text(connectionHelp)
                }
                Section("Synchronization") {
                    Toggle("Keep screen awake during sync", isOn: $keepAwake)
                    Toggle("Show sync Live Activity", isOn: $liveActivity)
                    if session.chainHeight > 0 {
                        WalletLine(label: "Scanned height", value: "\(session.height) / \(session.chainHeight)")
                    }
                }
                Section("Privacy checks") {
                    ForEach(checks, id: \.0) { title, complete in
                        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(complete ? WalletStyle.mint : WalletStyle.muted)
                    }
                    Text("\(checks.filter(\.1).count) of \(checks.count) controls in use")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Wallet security") {
                    if session.data?.viewOnly != true {
                        Button("View recovery words") { revealSeed() }.disabled(busy)
                    }
                    Button("Lock wallet", action: lock)
                    Button("Remove this wallet", role: .destructive) { deleting = .one }
                    Button("Erase all app data", role: .destructive) { deleting = .all }
                }
                Section { WalletLanguagePicker() }
                Section("Project") {
                    Button { showSource = true } label: { Label("Source code and license", systemImage: "curlybraces") }
                }
                if let error { Section { WalletNotice(text: error) } }
            }
            .scrollContentBackground(.hidden).background(WalletStyle.ink)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onAppear { prefs = session.connection }
        .sheet(isPresented: $showSource) { WalletSource() }
        .sheet(isPresented: $showWords, onDismiss: { words = nil }) {
            WalletSheet(title: "Recovery words") {
                Text("Anyone with this phrase can spend your XMR. Keep your written copy private.").foregroundStyle(WalletStyle.muted)
                if let words { VaultSeedWords(phrase: words) }
            }
        }
        .onDisappear { words = nil }
        .alert(item: $deleting) { choice in
            Alert(title: Text(choice == .all ? "Erase every wallet on this iPhone?" : "Remove this wallet?"),
                  message: Text("You will need your recovery backup to regain access. Local labels, contacts and invoices will be lost."),
                  primaryButton: .destructive(Text("Erase")) { erase(choice) }, secondaryButton: .cancel())
        }
    }

    private var connectionHelp: String {
        switch prefs.selection {
        case .offline: return "Offline wallets can create addresses and review saved activity. Choose a node to scan or send payments."
        case .automatic where prefs.useProxy: return "Public Tor mode tries two onion nodes through your local proxy."
        case .automatic: return "Public mode checks Cake Wallet and Seth For Privacy nodes. A direct node connection reveals your IP address to the node."
        case .custom: return "Use a Monero daemon you trust. Applying a change closes the current connection and requires unlocking again."
        }
    }

    private var checks: [(String, Bool)] {
        [("Device authentication enabled", vault.phase == .unlocked),
         ("Recovery setup completed", vault.active?.backupVerified == true),
         ("Custom node selected", session.connection.selection == .custom),
         ("Offline or proxy routing selected", session.connection.selection == .offline || session.connection.useProxy)]
    }

    private func revealSeed() {
        guard let wallet = vault.active else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let ticket = vault.sessionID
                _ = try await vault.authorizedLocation(for: wallet, reason: "View your wallet’s recovery words.")
                let phrase = try await session.readSeed()
                try vault.requireCurrent(ticket)
                words = phrase
                showWords = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func erase(_ choice: Deletion) {
        guard let active = vault.active, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let ticket = vault.sessionID
                _ = try await vault.authorizedLocation(for: active, reason: "Confirm erasing wallet data from this iPhone.")
                await session.close()
                try vault.requireCurrent(ticket)
                let targets = choice == .all ? vault.wallets : [active]
                for record in targets { try vault.erase(record) }
                if choice == .all {
                    if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
                    try session.saveConnection(ConnectionSettings())
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
