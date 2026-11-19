import Foundation

/// A committed erase request survives device locking, app termination, and a
/// partially completed cleanup. The marker sits inside the backup-excluded vault.
struct WalletEraseJournal {
    let root: URL
    var marker: URL { root.appending(path: ".erase-everything-v1") }
    private let content = Data("confirmed-wallet-erasure-v1".utf8)

    func begin() throws {
        try content.write(to: marker, options: [.atomic, .completeFileProtection])
    }

    @MainActor func finish(retireCredentials: () async throws -> Void, eraseNetworkState: () async throws -> Void,
                           clearPreferences: () -> Void) async throws {
        guard try Data(contentsOf: marker) == content else { throw PINFailure("The wallet erase journal could not be verified.") }
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where item.lastPathComponent != marker.lastPathComponent {
            try fm.removeItem(at: item)
        }
        try await retireCredentials()
        try await eraseNetworkState()
        clearPreferences()
        try fm.removeItem(at: marker)
    }
}
