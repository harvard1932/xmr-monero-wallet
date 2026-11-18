import Foundation
import XCTest
@testable import XMRMoneroWallet

final class TransferIntegrationTests: XCTestCase {
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
}
