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

    func testTransactionNotesPersistAndClearOnlyOnTheSelectedWallet() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first")
        let second = folder.appending(path: "second")
        let password = UUID().uuidString
        let engine = WalletEngine(testnet: true)
        let txid = String(repeating: "12", count: 32)
        _ = try await engine.create(at: first, password: password)
        try await engine.setTransactionNote("Coffee · 東京", for: txid)
        try await engine.close()
        _ = try await engine.create(at: second, password: password)
        let unrelated = try await engine.getTransactionNote(for: txid)
        XCTAssertEqual(unrelated, "")
        try await engine.open(at: first, password: password)
        let restored = try await engine.getTransactionNote(for: txid)
        XCTAssertEqual(restored, "Coffee · 東京")
        do {
            try await engine.setTransactionNote("Invalid\0suffix", for: txid)
            XCTFail("A note with an embedded null must be rejected.")
        } catch is WalletEngineError {}
        try await engine.setTransactionNote("", for: txid)
        try await engine.close()
        try await engine.open(at: first, password: password)
        let removed = try await engine.getTransactionNote(for: txid)
        XCTAssertEqual(removed, "")
        try await engine.close()
    }

    @MainActor
    func testActivitySearchDirectionAndExactTotals() {
        let item = WalletActivityItem(transactionHash: "abcdef", subaddresses: [0], incoming: false,
                                      amount: UInt64.max, date: Date(), confirmations: 10,
                                      note: "Museum café", recipients: ["destination"])
        let contacts = [WalletContactItem(name: "Alex", address: "destination")]
        for query in ["ABC", "museum", "STIN", "alex"] {
            XCTAssertTrue(ActivityHistory.matches(item, direction: .sent, query: query, contacts: contacts))
        }
        XCTAssertFalse(ActivityHistory.matches(item, direction: .received, query: "", contacts: contacts))
        XCTAssertFalse(ActivityHistory.matches(item, direction: .all, query: "train", contacts: contacts))
        var failed = item
        failed.failed = true
        let large = ActivityHistory.total([item, item, failed], incoming: false)
        XCTAssertEqual(large, Decimal(string: "36893488.147419103230")!)
    }

}
