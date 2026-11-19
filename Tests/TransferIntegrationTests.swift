import Foundation
import XCTest
@testable import XMRMoneroWallet

final class TransferIntegrationTests: XCTestCase {
    func testPreparedAmountAndFeeMustFitTheSpendableBalance() {
        XCTAssertTrue(WalletTransfer.fitsSpendableBalance(amount: 95, fee: 5, available: 100))
        XCTAssertFalse(WalletTransfer.fitsSpendableBalance(amount: 95, fee: 6, available: 100))
        XCTAssertFalse(WalletTransfer.fitsSpendableBalance(amount: .max, fee: 1, available: .max))
        XCTAssertFalse(WalletTransfer.fitsSpendableBalance(amount: 0, fee: 1, available: 10))
    }

    func testNativeWalletRoundTripAndOfflineSpendGuard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = WalletEngine(testnet: true)
        let password = UUID().uuidString
        let url = directory.appendingPathComponent("wallet")
        do {
            let phrase = try await wallet.create(at: url, password: password)
            XCTAssertEqual(phrase.split(separator: " ").count, 25)
            let fresh = try await wallet.snapshot()
            let mainAddress = try XCTUnwrap(fresh.addresses.first?.address)
            let invoice = try await wallet.addAddress(label: "Test invoice")
            XCTAssertNotEqual(invoice.address, mainAddress)
            try await wallet.addContact(name: "Test", address: invoice.address)
            try await wallet.close()
            try await wallet.open(at: url, password: password)
            let reopened = try await wallet.snapshot()
            XCTAssertEqual(reopened.addresses.count, 2)
            let contacts = try await wallet.contacts()
            XCTAssertEqual(contacts.first?.address, invoice.address)
            do {
                _ = try await wallet.prepare(destination: invoice.address, amount: 1, priority: 1)
                XCTFail("A disconnected wallet prepared a spend")
            } catch is WalletEngineError { }
            let pairing = try await wallet.pairing()
            try await wallet.restore(at: directory.appendingPathComponent("viewer"), password: password,
                                     source: .keys(address: pairing.address, view: pairing.viewKey, spend: nil), height: 0)
            let viewer = try await wallet.snapshot()
            XCTAssertTrue(viewer.watchOnly)
            XCTAssertEqual(viewer.addresses.first?.address, mainAddress)
            let keyBackup = try await wallet.privateKeyBackup()
            XCTAssertEqual(keyBackup.address, mainAddress)
            XCTAssertTrue(keyBackup.view == pairing.viewKey)
            XCTAssertNil(keyBackup.spend)
            try await wallet.restore(at: directory.appendingPathComponent("restored"), password: password,
                                     source: .mnemonic(phrase), height: 0)
            let restored = try await wallet.snapshot()
            XCTAssertEqual(restored.addresses.first?.address, mainAddress)
            try await wallet.close()
        } catch {
            try? await wallet.close()
            throw error
        }
    }

    func testClassicSeedOffsetChangesAddressAndProtectsOriginalBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = WalletEngine(testnet: true)
        let password = UUID().uuidString, offset = UUID().uuidString
        do {
            let phrase = try await wallet.create(at: directory.appendingPathComponent("plain"), password: password)
            let plain = try await wallet.snapshot().addresses.first?.address
            try await wallet.restore(at: directory.appendingPathComponent("protected"), password: password,
                                     source: .protectedMnemonic(phrase, passphrase: offset), height: 0)
            let protected = try await wallet.snapshot().addresses.first?.address
            XCTAssertNotNil(protected)
            XCTAssertNotEqual(protected, plain)
            do {
                _ = try await wallet.seed()
                XCTFail("A seed-offset restore exposed a different native backup as the original phrase.")
            } catch is WalletEngineError {}
            try await wallet.restore(at: directory.appendingPathComponent("repeat"), password: password,
                                     source: .protectedMnemonic(phrase, passphrase: offset), height: 0)
            let repeated = try await wallet.snapshot().addresses.first?.address
            XCTAssertEqual(repeated, protected)
            try await wallet.close()
        } catch {
            try? await wallet.close()
            throw error
        }
    }
}
