import SwiftUI

@main
struct XMRMoneroWalletApp: App {
    @UIApplicationDelegateAdaptor(VaultAppDelegate.self) private var appDelegate
    @StateObject private var vault = WalletVault()
    @StateObject private var session = WalletSession()
    var body: some Scene {
        WindowGroup {
            WalletRoot(vault: vault, session: session)
                .modifier(WalletLanguageEnvironment())
                .preferredColorScheme(.dark)
                .tint(WalletStyle.apricot)
        }
    }
}

enum WalletPanel: String, Identifiable {
    case source, settings, wallets, network, privacy
    var id: String { rawValue }
}

struct WalletRoot: View {
    @ObservedObject var vault: WalletVault
    @ObservedObject var session: WalletSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var panel: WalletPanel?
    @AppStorage("keepAwake") private var keepAwake = false
    @AppStorage("syncActivity") private var showActivity = false
    @State private var isCaptured = UIScreen.main.isCaptured

    var body: some View {
        Group {
            if vault.phase == .unlocked {
                Group {
                    if let data = session.data {
                        WalletDashboard(data: data, actions: session.actions(vault: vault, settings: { panel = .settings }, wallets: { panel = .wallets }),
                                        showNetwork: { panel = .network }, showPulse: { panel = .privacy })
                            .id(vault.sessionID)
                    } else {
                        VStack(spacing: 20) {
                            if let issue = session.problem {
                                WalletNotice(text: issue)
                                Button("Lock wallet") { lock() }
                            } else { ProgressView("Opening wallet…") }
                        }.padding()
                    }
                }
                .task(id: vault.sessionID) { await session.run() }
            } else {
                VaultGate(vault: vault, create: session.create, restore: session.restore, open: session.open,
                          close: session.close, readSeed: session.readSeed, onSource: { panel = .source },
                          primaryAddress: session.primaryAddress)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WalletStyle.ink)
        .sheet(item: $panel) { item in
            switch item {
            case .source: WalletSource()
            case .settings: WalletSettings(vault: vault, session: session, lock: lock)
            case .wallets: WalletPicker(vault: vault, session: session)
            case .network:
                NavigationStack {
                    NetworkSettings(session: session, lock: lock)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { panel = nil } } }
                }
            case .privacy: WalletSettings(vault: vault, session: session, lock: lock, initialPage: .privacy)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                let canScan = vault.phase == .unlocked && showActivity
                panel = nil
                vault.lock()
                session.lockForBackground(allowProgress: canScan)
            } else if phase == .active {
                session.finishBackgroundScan()
            }
            updateIdleTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .walletVaultErased)) { _ in
            panel = nil
            session.takeOffline()
            session.resetPreferences()
        }
        .onChange(of: session.data?.id) { _, id in
            if id != nil, vault.phase == .unlocked, session.needsNetworkChoice, panel == nil { panel = .network }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            session.finishBackgroundScan()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isCaptured = UIScreen.main.isCaptured
            if isCaptured { lock() }
        }
        .overlay {
            if isCaptured { ZStack { WalletStyle.ink.ignoresSafeArea(); Label("Stop screen recording to open your wallet.", systemImage: "lock.fill").padding() } }
        }
        .onChange(of: session.height) { _, _ in updateIdleTimer() }
        .onChange(of: session.data?.synced) { _, _ in updateIdleTimer() }
        .onChange(of: keepAwake) { _, _ in updateIdleTimer() }
        .task(id: activityState) {
            // The session publishes directly during its granted background time.
            if scenePhase == .active {
                await SyncLiveActivity.publish(activityState, allowCreation: vault.phase == .unlocked)
            }
        }
        .alert("Wallet storage", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
            Button("OK") { session.notice = nil }
        } message: { Text(session.notice ?? "") }
        .onAppear { updateIdleTimer() }
        .onChange(of: vault.phase) { _, phase in
            if phase != .unlocked { updateIdleTimer() }
        }
    }

    private var activityState: SyncAttributes.ContentState? {
        showActivity ? session.lockScreenProgress : nil
    }

    private func lock() {
        panel = nil
        vault.lock()
        session.takeOffline()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && vault.phase == .unlocked &&
            keepAwake && session.data?.syncProgress != nil && session.data?.synced == false
    }
}
