import SwiftUI

struct NetworkSettings: View {
    @ObservedObject var session: WalletSession
    let lock: () -> Void
    @State private var draft: ConnectionSettings
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(session: WalletSession, preselectTor: Bool = false, lock: @escaping () -> Void) {
        self.session = session
        self.lock = lock
        var value = session.connection
        if session.needsNetworkChoice && value.selection == .offline { value.mode = ConnectionMode.automatic.rawValue }
        if preselectTor {
            value.mode = ConnectionMode.automatic.rawValue
            value.useProxy = true
            value.externalTor = false
        }
        _draft = State(initialValue: value)
    }

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Connection mode", selection: $draft.mode) {
                    ForEach(ConnectionMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0.rawValue) }
                }
                if draft.selection == .custom {
                    TextField("Node URL", text: $draft.endpoint).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().keyboardType(.URL)
                }
                if draft.selection != .offline {
                    Toggle("Route through Tor", isOn: $draft.useProxy)
                    if draft.useProxy {
                        Toggle("Use my own Tor proxy", isOn: Binding(get: { draft.usesExternalTor }, set: { draft.externalTor = $0 }))
                        if draft.usesExternalTor {
                            TextField("127.0.0.1:9050", text: $draft.proxy)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else { Text("Tor runs inside the wallet and connects to onion nodes.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                Text(explanation).font(.footnote).foregroundStyle(.secondary)
                Button { apply() } label: {
                    if draft.selection == .offline { Text("Stay offline") }
                    else if session.connection.selection == .offline { Text("Connect") }
                    else { Text("Apply and lock wallet") }
                }.disabled(busy || (!session.needsNetworkChoice && draft == session.connection))
            }
            Section("Node status") {
                if let percent = session.torProgress {
                    ProgressView(value: Double(percent), total: 100) { Text("Connecting to Tor · \(percent)%") }
                } else if session.changingNode { ProgressView("Connecting") }
                if let name = session.nodeName { WalletLine(label: "Active node", value: name) }
                if session.chainHeight > 0 { WalletLine(label: "Scanned height", value: "\(session.height) / \(session.chainHeight)") }
                if let issue = error ?? session.problem { WalletNotice(text: issue) }
                if session.connection.selection != .offline {
                    Button("Reconnect") {
                        busy = true
                        Task { await session.retryConnection(); busy = false }
                    }.disabled(busy || session.changingNode)
                }
            }
        }
        .scrollContentBackground(.hidden).background(WalletStyle.ink)
        .navigationTitle("Node and sync settings")
    }

    private var explanation: LocalizedStringKey {
        switch draft.selection {
        case .offline: return "Create addresses and review saved activity offline. A node is required to scan or send."
        case .automatic where draft.useProxy: return "Try public onion nodes through Tor. If a node stalls, the wallet changes nodes."
        case .automatic: return "Use the fastest responding public Monero node. Direct nodes can see your IP address."
        case .custom where draft.useProxy: return "Enter the http:// address of your v3 onion node."
        case .custom: return "Enter your Monero daemon’s HTTPS address or a loopback HTTP address."
        }
    }

    private func apply() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if session.connection.selection == .offline {
                    try await session.chooseInitialConnection(draft)
                    if session.problem == nil { dismiss() }
                } else {
                    try session.saveConnection(draft)
                    lock()
                }
            } catch { self.error = WalletL10n.diagnostic(error) }
        }
    }
}
