import SwiftUI

/// Only observable, user-controlled settings contribute to the score.
struct PrivacyPulse {
    enum Control: String, CaseIterable, Identifiable {
        case backup, deviceLock, route, node, subaddress
        var id: Self { self }
    }
    let backedUp: Bool
    let locked: Bool
    let hasSubaddress: Bool
    let route: ConnectionSettings

    var complete: Set<Control> {
        var result = Set<Control>()
        if backedUp { result.insert(.backup) }
        if locked { result.insert(.deviceLock) }
        if route.selection == .offline || route.useProxy { result.insert(.route) }
        if route.selection == .offline || route.selection == .custom { result.insert(.node) }
        if hasSubaddress { result.insert(.subaddress) }
        return result
    }

    var score: Int { 100 * complete.count / Control.allCases.count }
}

struct PrivacyPulseView: View {
    let pulse: PrivacyPulse
    let act: (PrivacyPulse.Control) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pulse.score, format: .number).font(.system(size: 64, weight: .semibold, design: .rounded))
                    Text("/ 100").font(.title2).foregroundStyle(.secondary)
                }
                Text("Your score reflects five settings on this iPhone. Each contributes 20 points.")
                    .foregroundStyle(.secondary)
                ForEach(PrivacyPulse.Control.allCases) { control in
                    let done = pulse.complete.contains(control)
                    VStack(alignment: .leading, spacing: 8) {
                        Label(title(control), systemImage: done ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.headline).foregroundStyle(done ? WalletStyle.mint : WalletStyle.apricot)
                        Text(detail(control, done)).font(.subheadline)
                        if !done {
                            Button { act(control) } label: { Text(action(control)) }
                                .buttonStyle(.bordered).tint(WalletStyle.apricot)
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 16))
                }
            }.padding(20).frame(maxWidth: 600)
        }
        .background(WalletStyle.ink).navigationTitle("Privacy Pulse")
    }

    private func title(_ c: PrivacyPulse.Control) -> LocalizedStringKey {
        switch c { case .backup: "Recovery backup"; case .deviceLock: "Wallet lock"; case .route: "Network privacy"; case .node: "Node choice"; case .subaddress: "Receiving addresses" }
    }
    private func action(_ c: PrivacyPulse.Control) -> LocalizedStringKey {
        switch c { case .backup: "Review backup"; case .deviceLock: "Set up wallet lock"; case .route: "Set up Tor"; case .node: "Choose a node"; case .subaddress: "Create a subaddress" }
    }
    private func detail(_ c: PrivacyPulse.Control, _ done: Bool) -> LocalizedStringKey {
        switch (c, done) {
        case (.subaddress, true): "This wallet has a dedicated subaddress. Use a fresh one for each contact or request."
        case (.subaddress, false): "Create a fresh receiving address to avoid sharing your primary address with every contact."
        case (.backup, true): "Recovery setup is complete. Keep your written backup private."
        case (.backup, false): "Verify your recovery backup so a lost iPhone does not cost you access."
        case (.deviceLock, true): "Unlocking this wallet requires authentication."
        case (.deviceLock, false): "Enable a wallet lock to protect access on this iPhone."
        case (.route, true): "Your selected route keeps your IP address away from a public Monero node."
        case (.route, false): "A direct connection reveals your IP address to the node. Use Tor to conceal it."
        case (.node, true): "You selected your own node or chose to stay offline."
        case (.node, false): "Choose a node you operate to control who handles wallet requests."
        }
    }
}
