import SwiftUI

struct PrivacyPulse {
    enum Control: CaseIterable, Identifiable {
        case deviceLock, biometrics, node, backup, invoices
        var id: Self { self }
        var points: Int {
            switch self {
            case .deviceLock: 8
            case .biometrics: 3
            case .node: 5
            case .backup: 7
            case .invoices: 10
            }
        }
        var title: LocalizedStringKey {
            switch self {
            case .deviceLock: "Wallet lock"
            case .biometrics: "Biometric unlock"
            case .node: "Node choice"
            case .backup: "Recovery backup"
            case .invoices: "Dedicated subaddress"
            }
        }
        var action: LocalizedStringKey {
            switch self {
            case .deviceLock, .biometrics: "App PIN and biometrics"
            case .node: "Choose a node"
            case .backup: "Review backup"
            case .invoices: "Payment requests"
            }
        }
    }

    let backedUp: Bool
    let hasPIN: Bool
    let hasBiometrics: Bool
    let freshInvoices: Bool
    let route: ConnectionSettings
    let choseRoute: Bool

    var complete: Set<Control> {
        var result = Set<Control>()
        if backedUp { result.insert(.backup) }
        if hasPIN { result.insert(.deviceLock) }
        if hasPIN && hasBiometrics { result.insert(.biometrics) }
        if choseRoute && (route.selection != .automatic || route.useProxy) { result.insert(.node) }
        if freshInvoices { result.insert(.invoices) }
        return result
    }

    // Account for each visible opportunity directly, without assigning undocumented baseline weights.
    var score: Int { 100 - Control.allCases.filter { !complete.contains($0) }.reduce(0) { $0 + $1.points } }

    static func hasFreshInvoices(_ invoices: [WalletInvoiceItem], addresses: [WalletAddressItem]) -> Bool {
        guard !invoices.isEmpty else { return false }
        let assigned = Set(invoices.map(\.address))
        let subaddresses = Set(addresses.filter { $0.id > 0 }.map(\.address))
        return assigned.count == invoices.count && assigned.isSubset(of: subaddresses)
    }

    func detail(_ control: Control) -> LocalizedStringKey {
        switch control {
        case .deviceLock: return hasPIN ? "Unlocking this wallet requires authentication." : "Enable a wallet lock to protect access on this iPhone."
        case .biometrics: return complete.contains(.biometrics) ? "Use your app PIN or enabled biometrics to unlock." : "Biometric unlock is disabled."
        case .node:
            if route.selection == .offline { return "Offline wallets can create addresses and review saved activity. Choose a node to scan or send payments." }
            if route.useProxy { return "Your selected route keeps your IP address away from a public Monero node." }
            return "A direct connection reveals your IP address to the node. Use Tor to conceal it."
        case .backup: return backedUp ? "Recovery setup is complete. Keep your written backup private." : "Verify your recovery backup so a lost iPhone does not cost you access."
        case .invoices: return "Each request uses its own subaddress to track the amount received."
        }
    }
}

extension PrivacyPulse {
    @MainActor init(vault: WalletVault, session: WalletSession) {
        self.init(backedUp: vault.active?.backupVerified == true, hasPIN: vault.hasPIN, hasBiometrics: vault.hasBiometrics,
                  freshInvoices: Self.hasFreshInvoices(session.data?.invoices ?? [], addresses: session.data?.addresses ?? []),
                  route: session.connection, choseRoute: !session.needsNetworkChoice)
    }
}

struct PrivacyPulseView: View {
    let pulse: PrivacyPulse
    let act: (PrivacyPulse.Control) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(WalletStyle.muted.opacity(0.2), lineWidth: 5)
                        Circle().trim(from: 0, to: CGFloat(pulse.score) / 100)
                            .stroke(WalletStyle.apricot, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(pulse.score, format: .number).font(.title.bold())
                            Text("/ 100").font(.caption).foregroundStyle(WalletStyle.muted)
                        }
                    }.frame(width: 80, height: 80)
                    Text("Incomplete checks deduct the points shown.").font(.subheadline)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 16))
                controls("Available to you", complete: false)
                controls("Enabled", complete: true)
                Text("Built-in protections").font(.headline).padding(.top, 8)
                VStack(alignment: .leading, spacing: 12) {
                    fact("Ring signatures and stealth addresses", "Ring signatures hide the real input among decoys. A one-time address receives each output.", points: 14)
                    Divider()
                    fact("Confidential amounts", "RingCT hides transfer amounts on the blockchain.", points: 10)
                    Divider()
                    fact("Local wallet keys", "Wallet files are encrypted on this iPhone. The unlock key is protected by the device Keychain.", points: 12)
                }.padding().background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 16))
            }.padding(20).frame(maxWidth: 600)
        }.frame(maxWidth: .infinity).background(WalletStyle.ink).navigationTitle("Privacy Pulse")
    }

    @ViewBuilder private func controls(_ title: LocalizedStringKey, complete: Bool) -> some View {
        let rows = PrivacyPulse.Control.allCases.filter { pulse.complete.contains($0) == complete }
        if !rows.isEmpty {
            Text(title).font(.headline).padding(.top, 8)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    if row != rows.first { Divider() }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(row.title, systemImage: complete ? "checkmark.circle.fill" : "plus.circle")
                            Spacer()
                            Text(row.points, format: .number.sign(strategy: complete ? .automatic : .always()))
                                .foregroundStyle(WalletStyle.apricot)
                        }.font(.subheadline.bold())
                        Text(pulse.detail(row)).font(.subheadline).foregroundStyle(WalletStyle.muted)
                        if !complete { Button(row.action) { act(row) }.font(.subheadline) }
                    }
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func fact(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, points: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: "checkmark.circle.fill")
                Spacer()
                Text(points, format: .number).foregroundStyle(WalletStyle.apricot)
            }.font(.subheadline.bold())
            Text(detail).font(.subheadline).foregroundStyle(WalletStyle.muted)
        }
    }
}
