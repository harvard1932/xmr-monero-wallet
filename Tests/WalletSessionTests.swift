import Foundation
import XCTest
@testable import XMRMoneroWallet

final class WalletSessionTests: XCTestCase {
    @MainActor
    func testPresentedActionsCannotWriteToTheNextWallet() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func location(_ name: String) throws -> VaultLocation {
            let record = VaultWallet(id: UUID(), name: name, createdAt: Date(), backupVerified: true)
            let folder = root.appending(path: record.id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: folder.appending(path: "record.json"))
            return VaultLocation(wallet: record, fileURL: folder.appending(path: "wallet"), password: UUID().uuidString)
        }
        let a = try location("A")
        let b = try location("B")
        let vault = WalletVault(root: root)
        let session = WalletSession()
        _ = try await session.create(a)
        vault.enter(a.wallet)
        let stale = session.actions(vault: vault, settings: {}, wallets: {})
        await session.close()
        vault.select(b.wallet)
        _ = try await session.create(b)
        vault.enter(b.wallet)
        do {
            _ = try await stale.newAddress("Old review")
            XCTFail("A dismissed wallet action was allowed to write to a different wallet.")
        } catch is CancellationError {}
        await session.refresh()
        XCTAssertEqual(session.data?.addresses.count, 1)
        await session.close()
    }
}
