import SwiftUI
import ActivityKit

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
    case source, settings, wallets
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
                        WalletDashboard(data: data, actions: session.actions(vault: vault, settings: { panel = .settings }, wallets: { panel = .wallets }))
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
                          close: session.close, readSeed: session.readSeed, onSource: { panel = .source })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WalletStyle.ink)
        .sheet(item: $panel) { item in
            switch item {
            case .source: WalletSource()
            case .settings: WalletSettings(vault: vault, session: session, lock: lock)
            case .wallets: WalletPicker(vault: vault, session: session)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { lock() }
            updateIdleTimer()
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
        .task(id: activityState) { await syncLiveActivity() }
        .alert("Wallet storage", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
            Button("OK") { session.notice = nil }
        } message: { Text(session.notice ?? "") }
        .onAppear { updateIdleTimer() }
        .onChange(of: vault.phase) { _, phase in
            if phase != .unlocked { updateIdleTimer() }
        }
    }

    private var activityState: SyncAttributes.ContentState? {
        guard vault.phase == .unlocked, showActivity, session.data?.syncProgress != nil, session.data?.synced == false else { return nil }
        return .init(height: session.height, target: session.chainHeight)
    }

    private func syncLiveActivity() async {
        let existing = Activity<SyncAttributes>.activities
        guard let state = activityState, ActivityAuthorizationInfo().areActivitiesEnabled else {
            for activity in existing { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))
        if let activity = existing.first { await activity.update(content) }
        else if !Task.isCancelled {
            do { _ = try Activity.request(attributes: SyncAttributes(), content: content, pushType: nil) }
            catch { /* The phone can disable Live Activities independently of wallet sync. */ }
        }
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
