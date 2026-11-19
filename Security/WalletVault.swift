import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit

extension Notification.Name {
    static let walletVaultErased = Notification.Name("WalletVaultErased")
}

struct VaultWallet: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let createdAt: Date
    var backupVerified: Bool
}

struct VaultLocation {
    let wallet: VaultWallet
    let fileURL: URL
    let password: String
}

struct VaultRestore {
    let source: WalletRestoreSource
    let height: UInt64
}

enum VaultPhase { case loading, needsWallet, locked, opening, unlocked }

private enum VaultFailure: LocalizedError {
    case keychain(OSStatus), name, invalidRegistry, missingWallet

    var errorDescription: String? {
        switch self {
        case .keychain(errSecItemNotFound):
            return WalletL10n.text("This iPhone no longer holds the wallet’s unlock key. Restore it from your recovery backup.")
        case .keychain(errSecUserCanceled): return WalletL10n.text("Authentication was canceled.")
        case .keychain(let code): return WalletL10n.text("The iPhone Keychain could not complete this request (%lld).", Int64(code))
        case .name: return WalletL10n.text("Use a unique wallet name of 1 to 48 characters.")
        case .invalidRegistry: return WalletL10n.text("The local wallet list could not be read. Existing wallet files have been preserved.")
        case .missingWallet: return WalletL10n.text("This wallet is no longer available on this device.")
        }
    }
}

final class VaultAppDelegate: NSObject, UIApplicationDelegate {
    private var curtains: [ObjectIdentifier: UIWindow] = [:]

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(coverScene(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(revealScene(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(revealScene(_:)), name: UIScene.didDisconnectNotification, object: nil)
        return true
    }

    // A scene window also covers sheets, alerts, and the keyboard's app snapshot.
    // Keeping the window non-key leaves the system's authentication prompt usable.
    @objc private func coverScene(_ event: Notification) {
        guard let scene = event.object as? UIWindowScene else { return }
        let id = ObjectIdentifier(scene)
        guard curtains[id] == nil else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor(red: 0.082, green: 0.071, blue: 0.091, alpha: 1)
        let icon = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 35)))
        icon.tintColor = UIColor(red: 1, green: 0.659, blue: 0.45, alpha: 1)
        icon.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
        ])
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        curtains[id] = window
        window.isHidden = false
    }

    @objc private func revealScene(_ event: Notification) {
        guard let scene = event.object as? UIWindowScene else { return }
        curtains.removeValue(forKey: ObjectIdentifier(scene))?.isHidden = true
    }

    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier identifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        identifier != .keyboard
    }
}

// Version-one wallet passwords use their original user-presence Keychain ACL
// exactly once during migration to the PIN-protected wallet credential.
enum WalletCredential {
    private static let service = (Bundle.main.bundleIdentifier ?? "XMRMoneroWallet") + ".wallet-password.v1"

    static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    static func read(_ id: UUID, reason: String) async throws -> String {
        let context = LAContext()
        context.localizedReason = WalletL10n.text(reason)
        context.localizedCancelTitle = WalletL10n.text("Cancel")
        defer { context.invalidate() }
        var item = query(id)
        item[kSecUseAuthenticationContext as String] = context
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &value)
        guard status == errSecSuccess, let bytes = value as? Data, let password = String(data: bytes, encoding: .utf8) else {
            throw VaultFailure.keychain(status)
        }
        return password
    }

    static func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultFailure.keychain(status) }
    }

    static func removeAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultFailure.keychain(status) }
    }
}

@MainActor
final class WalletVault: ObservableObject {
    @Published private(set) var wallets = [VaultWallet]()
    @Published private(set) var active: VaultWallet?
    @Published private(set) var phase = VaultPhase.loading
    @Published private(set) var sessionID = UUID()
    @Published private(set) var working = false
    @Published private(set) var loadError: String?
    private var sessionKey: SymmetricKey?
    private let fm = FileManager.default
    private let root: URL
    private var runningOperation: UUID?

    init(root: URL = URL.applicationSupportDirectory.appending(path: "WalletVaults", directoryHint: .isDirectory)) {
        self.root = root
        reconcile()
    }

    private func folder(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    private func file(_ id: UUID) -> URL { folder(id).appending(path: "wallet") }
    private func manifest(_ id: UUID) -> URL { folder(id).appending(path: "record.json") }

    private func protectedFolder(_ path: URL) throws {
        try fm.createDirectory(at: path, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.complete])
        var path = path
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try path.setResourceValues(values)
    }

    private var eraseJournal: WalletEraseJournal { WalletEraseJournal(root: root) }

    func reconcile() {
        guard !working else { return }
        do {
            try protectedFolder(root)
            let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            if contents.contains(where: { $0.lastPathComponent == eraseJournal.marker.lastPathComponent }) {
                phase = .loading; active = nil; wallets = []; loadError = nil
                if let ticket = beginOperation() {
                    Task {
                        defer { endOperation(ticket) }
                        do { try await finishErasure() } catch { loadError = WalletL10n.diagnostic(error) }
                    }
                }
                return
            }
            var discovered: [VaultWallet] = []
            for item in contents {
                let filename = item.lastPathComponent
                if filename.hasPrefix(".deleting-"), let id = UUID(uuidString: String(filename.dropFirst(10))) {
                    // A previous deletion was already confirmed. Finish before this wallet can reappear.
                    try WalletCredential.remove(id)
                    try fm.removeItem(at: item)
                    continue
                }
                guard let id = UUID(uuidString: item.lastPathComponent) else { continue }
                guard fm.fileExists(atPath: manifest(id).path) else {
                    // A crash before a wallet's first successful save can leave a draft.
                    // Only remove a marked draft. Never silently discard a registered wallet.
                    guard fm.fileExists(atPath: item.appending(path: ".draft").path) else { throw VaultFailure.invalidRegistry }
                    try WalletCredential.remove(id)
                    try fm.removeItem(at: item)
                    continue
                }
                let record = try JSONDecoder().decode(VaultWallet.self, from: Data(contentsOf: manifest(id)))
                guard record.id == id else { throw VaultFailure.invalidRegistry }
                discovered.append(record)
            }
            wallets = discovered.sorted { $0.createdAt < $1.createdAt }
            active = wallets.first(where: { $0.id == active?.id }) ?? wallets.first
            phase = wallets.isEmpty ? .needsWallet : .locked
            loadError = nil
        } catch {
            phase = .loading
            loadError = WalletL10n.diagnostic(error)
        }
    }

    func lock() {
        WalletPINPrompt.cancel()
        sessionKey = nil
        sessionID = UUID()
        if phase != .loading { phase = wallets.isEmpty ? .needsWallet : .locked }
    }

    func beginAdding() {
        guard !working else { return }
        lock()
        phase = .needsWallet
    }

    func select(_ wallet: VaultWallet) {
        guard !working, wallets.contains(wallet) else { return }
        lock()
        active = wallet
        phase = .locked
    }

    private func passwordFile(_ id: UUID) -> URL { folder(id).appending(path: "credential.sealed") }
    private func originalFile(_ id: UUID) -> URL { folder(id).appending(path: "original-backup.sealed") }

    func authorizeAction(reason: String, manage: Bool = false) async throws {
        let session = sessionID
        let hasCiphertexts = wallets.contains { fm.fileExists(atPath: passwordFile($0.id).path) }
        let key = try await WalletPINPrompt.request(reason: reason, existingCiphertexts: hasCiphertexts, manage: manage)
        try requireCurrent(session)
        sessionKey = key
    }

    func managePIN() async throws {
        try await authorizeAction(reason: "Authenticate to change wallet security.", manage: true)
    }

    func eraseAllFromSettings(close: () async -> Void) async throws {
        guard phase == .unlocked, let ticket = beginOperation() else { throw CancellationError() }
        defer { endOperation(ticket) }
        try await authorizeAction(reason: "Confirm erasing wallet data from this iPhone.")
        try requireCurrent(ticket)
        try await commitFullErasure(close: close)
    }

    func eraseAllFromLock() async throws {
        guard phase == .locked || (phase == .loading && loadError != nil), let ticket = beginOperation() else { throw CancellationError() }
        defer { endOperation(ticket) }
        try await WalletPINStore.shared.authorizeEmergencyErase()
        try requireCurrent(ticket)
        try await commitFullErasure(close: {})
    }

    private func commitFullErasure(close: () async -> Void) async throws {
        // Establish the durable user intent before closing any native handle.
        try eraseJournal.begin()
        phase = .loading; loadError = nil; active = nil; wallets = []
        lock()
        await close()
        do { try await finishErasure() }
        catch { loadError = WalletL10n.diagnostic(error); throw error }
    }

    private func finishErasure() async throws {
        try await eraseJournal.finish(retireCredentials: {
            try WalletCredential.removeAll()
            try await WalletPINStore.shared.eraseAll()
        }, eraseNetworkState: {
            try await EmbeddedTor.shared.eraseState()
        }, clearPreferences: {
            if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
        })
        sessionKey = nil; wallets = []; active = nil; phase = .needsWallet; loadError = nil
        NotificationCenter.default.post(name: .walletVaultErased, object: nil)
    }

    func authorizedLocation(for wallet: VaultWallet, reason: String) async throws -> VaultLocation {
        guard wallets.contains(where: { $0.id == wallet.id }) else { throw VaultFailure.missingWallet }
        let session = sessionID
        try await authorizeAction(reason: reason)
        try requireCurrent(session)
        guard let key = sessionKey else { throw CancellationError() }
        let password = try await WalletCredentialMigration.open(at: passwordFile(wallet.id), walletID: wallet.id, key: key,
            legacy: { try await WalletCredential.read(wallet.id, reason: "Authorize migration of this wallet to the app PIN.") },
            checkSession: { try self.requireCurrent(session) }, retireLegacy: { try WalletCredential.remove(wallet.id) })
        try requireCurrent(session)
        return VaultLocation(wallet: wallet, fileURL: file(wallet.id), password: password)
    }

    func saveOriginal(_ backup: VaultBackup, for wallet: VaultWallet) throws {
        guard let key = sessionKey else { throw CancellationError() }
        try WalletSealedFile.write(JSONEncoder().encode(backup), to: originalFile(wallet.id), walletID: wallet.id, key: key)
    }

    func recoveryBackup(for wallet: VaultWallet, nativeSeed: () async throws -> String,
                        rawKeys: (() async throws -> (address: String, view: String, spend: String?))? = nil) async throws -> VaultBackup {
        let ticket = sessionID
        _ = try await authorizedLocation(for: wallet, reason: "View the original wallet recovery backup.")
        try requireCurrent(ticket)
        guard let key = sessionKey else { throw CancellationError() }
        let url = originalFile(wallet.id)
        if fm.fileExists(atPath: url.path) {
            let data = try WalletSealedFile.read(url, walletID: wallet.id, key: key)
            return try JSONDecoder().decode(VaultBackup.self, from: data)
        }
        do {
            let words = try await nativeSeed()
            try requireCurrent(ticket)
            return .init(format: "Native wallet recovery words", phrase: words, address: nil, view: nil, spend: nil, requiresPassphrase: false)
        } catch {
            try requireCurrent(ticket)
            guard let rawKeys else { throw error }
            let keys = try await rawKeys()
            try requireCurrent(ticket)
            return .init(format: "Native wallet keys", phrase: nil, address: keys.address,
                         view: keys.view, spend: keys.spend, requiresPassphrase: false)
        }
    }

    func beginOperation() -> UUID? {
        guard runningOperation == nil else { return nil }
        runningOperation = sessionID
        working = true
        return sessionID
    }

    func endOperation(_ session: UUID) {
        if runningOperation == session {
            runningOperation = nil
            working = false
        }
    }

    func requireCurrent(_ session: UUID) throws {
        guard session == sessionID, !Task.isCancelled else { throw CancellationError() }
    }

    func draft(name input: String, restored: Bool, session: UUID) async throws -> VaultLocation {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 48,
              !wallets.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw VaultFailure.name
        }
        try await authorizeAction(reason: "Protect this wallet with your app PIN.")
        try requireCurrent(session)
        guard let key = sessionKey else { throw CancellationError() }
        let wallet = VaultWallet(id: UUID(), name: name, createdAt: Date(), backupVerified: restored)
        try protectedFolder(folder(wallet.id))
        do {
            try Data().write(to: folder(wallet.id).appending(path: ".draft"), options: [.atomic, .completeFileProtection])
            let password = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            try WalletSealedFile.write(Data(password.utf8), to: passwordFile(wallet.id), walletID: wallet.id, key: key)
            return VaultLocation(wallet: wallet, fileURL: file(wallet.id), password: password)
        } catch {
            try? fm.removeItem(at: folder(wallet.id))
            throw error
        }
    }

    func register(_ location: VaultLocation) throws {
        let wallet = location.wallet
        // Apply complete protection explicitly to the wallet core's initial files.
        for url in try fm.contentsOfDirectory(at: folder(wallet.id), includingPropertiesForKeys: nil) {
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        }
        try save(wallet)
        try? fm.removeItem(at: folder(wallet.id).appending(path: ".draft"))
        wallets.append(wallet)
        active = wallet
    }

    func discardDraft(_ location: VaultLocation) throws {
        guard !fm.fileExists(atPath: manifest(location.wallet.id).path) else { return }
        try WalletCredential.remove(location.wallet.id)
        try fm.removeItem(at: folder(location.wallet.id))
    }

    private func save(_ wallet: VaultWallet) throws {
        try JSONEncoder().encode(wallet).write(to: manifest(wallet.id), options: [.atomic, .completeFileProtection])
    }

    func markBackupVerified(for wallet: VaultWallet) throws {
        guard let i = wallets.firstIndex(where: { $0.id == wallet.id }) else { throw VaultFailure.missingWallet }
        var updated = wallets[i]
        updated.backupVerified = true
        try save(updated)
        wallets[i] = updated
        active = updated
    }

    func enter(_ wallet: VaultWallet) {
        guard sessionKey != nil, let wallet = wallets.first(where: { $0.id == wallet.id }), wallet.backupVerified else { return }
        active = wallet
        phase = .unlocked
    }

    // The calling flow must confirm deletion, authenticate, and close the core first.
    func erase(_ wallet: VaultWallet) throws {
        guard wallets.contains(where: { $0.id == wallet.id }) else { throw VaultFailure.missingWallet }
        // Moving the entire directory is an atomic deletion journal. A failed move
        // leaves the wallet usable. A crash after the move is completed on startup.
        let tombstone = root.appending(path: ".deleting-" + wallet.id.uuidString, directoryHint: .isDirectory)
        try fm.moveItem(at: folder(wallet.id), to: tombstone)
        wallets.removeAll { $0.id == wallet.id }
        active = wallets.first
        lock()
        try WalletCredential.remove(wallet.id)
        try fm.removeItem(at: tombstone)
    }
}
