import SwiftUI
import XCTest
@testable import XMRMoneroWallet

final class WalletVaultTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func save(_ wallet: VaultWallet, to root: URL) throws {
        let dir = root.appending(path: wallet.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(wallet).write(to: dir.appending(path: "record.json"))
    }

    @MainActor
    func testIncompleteBackupSurvivesRelaunchAndBlocksWalletEntry() throws {
        let root = try temporaryRoot()
        let wallet = VaultWallet(id: UUID(), name: "Temporary", createdAt: Date(), backupVerified: false)
        try save(wallet, to: root)
        let vault = WalletVault(root: root)
        XCTAssertEqual(vault.phase, .locked)
        vault.enter(wallet)
        XCTAssertEqual(vault.phase, .locked)
        try vault.markBackupVerified(for: wallet)
        vault.enter(wallet)
        XCTAssertEqual(vault.phase, .locked, "A verified backup cannot bypass app authentication.")

        let relaunch = WalletVault(root: root)
        XCTAssertEqual(relaunch.phase, .locked)
        XCTAssertEqual(relaunch.active?.id, wallet.id)
        XCTAssertEqual(relaunch.active?.backupVerified, true)
    }

    @MainActor
    func testOldWalletOperationCannotResumeAfterLock() throws {
        let vault = WalletVault(root: try temporaryRoot())
        let operation = try XCTUnwrap(vault.beginOperation())
        XCTAssertNil(vault.beginOperation())
        vault.lock()
        XCTAssertThrowsError(try vault.requireCurrent(operation))
        XCTAssertNil(vault.beginOperation(), "Wait for interrupted native work to release the engine.")
        vault.endOperation(operation)
        let next = try XCTUnwrap(vault.beginOperation())
        XCTAssertNotEqual(next, operation)
        XCTAssertNoThrow(try vault.requireCurrent(next))
    }

    @MainActor
    func testCorruptMetadataPreservesWalletFiles() throws {
        let root = try temporaryRoot()
        let dir = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = dir.appending(path: "wallet.keys")
        let fixture = Data([1, 2, 3, 4])
        try fixture.write(to: keys)
        try Data("bad record".utf8).write(to: dir.appending(path: "record.json"))
        let vault = WalletVault(root: root)
        XCTAssertNotNil(vault.loadError)
        XCTAssertEqual(vault.phase, .loading)
        XCTAssertEqual(try Data(contentsOf: keys), fixture)
    }

    @MainActor
    func testProtectedDataLossDetachesWalletAndInvalidatesInFlightWork() async throws {
        let root = try temporaryRoot()
        let vault = WalletVault(root: root)
        let session = WalletSession()
        let record = VaultWallet(id: UUID(), name: "Fixture", createdAt: Date(), backupVerified: true)
        let location = VaultLocation(wallet: record, fileURL: root.appending(path: "wallet"), password: UUID().uuidString)
        _ = try await session.create(location)
        let ticket = try XCTUnwrap(vault.beginOperation())
        defer { vault.endOperation(ticket) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let mounted = expectation(description: "Wallet root receives lifecycle notifications")
        window.rootViewController = UIHostingController(rootView: WalletRoot(vault: vault, session: session).onAppear { mounted.fulfill() })
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        await fulfillment(of: [mounted], timeout: 5)
        XCTAssertNotNil(session.engine)
        NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: UIApplication.shared)
        XCTAssertThrowsError(try vault.requireCurrent(ticket))
        XCTAssertNil(session.engine)
        await session.close()
    }

    @MainActor
    func testRecoveryClipboardClearsOnlyItsOwnCopy() throws {
        let name = UIPasteboard.Name(rawValue: "wallet-unit-test-" + UUID().uuidString)
        let board = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let clipboard = WalletRecoveryClipboard(pasteboard: board)
        clipboard.copy("public fixture")
        XCTAssertTrue(board.hasStrings)
        clipboard.clearIfOwned()
        XCTAssertFalse(board.hasStrings)
        clipboard.copy("public fixture")
        board.string = "later unrelated copy"
        clipboard.clearIfOwned()
        XCTAssertEqual(board.string, "later unrelated copy")
    }

    @MainActor
    func testMissingLegacyMetadataAndRecordedZeroHeightRemainDistinct() throws {
        let root = try temporaryRoot()
        let old = VaultWallet(id: UUID(), name: "Old", createdAt: Date(), backupVerified: true)
        try save(old, to: root)
        let vault = WalletVault(root: root)
        XCTAssertNil(vault.active?.restoreHeight)
        XCTAssertNil(vault.active?.recoveryFormat)
        let new = VaultWallet(id: UUID(), name: "New", createdAt: Date(), backupVerified: true)
        let folder = root.appending(path: new.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let location = VaultLocation(wallet: new, fileURL: folder.appending(path: "wallet"), password: UUID().uuidString)
        try vault.register(location, recoveryFormat: "View-only", restoreHeight: 0)
        let restored = try XCTUnwrap(WalletVault(root: root).wallets.first { $0.id == new.id })
        XCTAssertEqual(restored.recoveryFormat, "View-only")
        XCTAssertEqual(restored.restoreHeight, 0)
    }
}
