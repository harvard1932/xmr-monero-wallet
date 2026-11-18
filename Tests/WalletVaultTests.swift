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
        XCTAssertEqual(vault.phase, .unlocked)

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
}
