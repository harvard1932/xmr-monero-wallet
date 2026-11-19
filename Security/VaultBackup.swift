import CryptoKit
import Foundation
import SwiftUI

struct VaultBackup: Codable {
    let format: String
    let phrase: String?
    let address: String?
    let view: String?
    let spend: String?
    let requiresPassphrase: Bool
}

struct VaultBackupContent: View {
    let backup: VaultBackup
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(backup.format)).font(.headline)
            if let phrase = backup.phrase { VaultSeedWords(phrase: phrase) }
            if backup.requiresPassphrase { Text("Keep the original passphrase separately. Both the words and passphrase are needed for recovery.") }
            if let address = backup.address { backupLine("Primary address", address) }
            if let view = backup.view { backupLine("Private view key", view) }
            if let spend = backup.spend { backupLine("Private spend key", spend) }
        }.privacySensitive()
    }
    private func backupLine(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.footnote).foregroundStyle(WalletStyle.muted)
            Text(verbatim: value).font(.body.monospaced()).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum WalletSealedFile {
    static func write(_ data: Data, to url: URL, walletID: UUID, key: SymmetricKey) throws {
        let binding = Data((walletID.uuidString + "/" + url.lastPathComponent).utf8)
        guard let sealed = try AES.GCM.seal(data, using: key, authenticating: binding).combined else {
            throw PINFailure("Could not encrypt the wallet credential.")
        }
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
    }
    static func read(_ url: URL, walletID: UUID, key: SymmetricKey) throws -> Data {
        let binding = Data((walletID.uuidString + "/" + url.lastPathComponent).utf8)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key, authenticating: binding)
    }
}

enum WalletCredentialMigration {
    /// Commits and verifies the protected copy before retiring the old Keychain
    /// password. A second unlock can finish cleanup without reopening the old item.
    @MainActor static func open(at url: URL, walletID: UUID, key: SymmetricKey,
                                legacy: () async throws -> String, checkSession: () throws -> Void,
                                retireLegacy: () throws -> Void) async throws -> String {
        try checkSession()
        let plain: Data
        if let committed = try? WalletSealedFile.read(url, walletID: walletID, key: key) {
            plain = committed
        } else {
            // If verification of an interrupted first write failed, the previous
            // user-presence Keychain item still authorizes repair. Missing or
            // invalid credentials never result in a freshly generated password.
            plain = Data(try await legacy().utf8)
            try checkSession()
            try WalletSealedFile.write(plain, to: url, walletID: walletID, key: key)
            guard try WalletSealedFile.read(url, walletID: walletID, key: key) == plain else {
                throw PINFailure("The wallet credential could not be verified.")
            }
        }
        guard let password = String(data: plain, encoding: .utf8), !password.isEmpty else {
            throw PINFailure("The wallet credential could not be read.")
        }
        try retireLegacy()
        return password
    }
}
