import XCTest
@testable import XMRMoneroWallet

final class LegacyRecoveryTests: XCTestCase {
    // Public recovery-format compatibility fixtures. See Recovery/README.md for sources.
    func testPublishedMainnetAddressesThroughWallet2() async throws {
        let vectors: [(VaultSeedFormat, String, String)] = [
            (.myMonero, "slid otherwise jeers lurk swung tawny zodiac tusks twang cajun swagger peaches tawny",
             "48VWHdLTEpE5dqa5VpAy5xgQWBHZARiGmEmojNLqD4ef1FAzkPxCe9JXUYwCShRR5XNMGnyusrnkmMWr2HMdfDRx2vsrG7c"),
            (.bip39, "color ranch color remove subway public water embrace before begin liberty fault",
             "49MggvPosJugF8Zq7WAKbsSchz6vbyL6YiUxM4ryfGQDXphs6wiWiXLFWCSshnLPcceGTWUaKfWWMHQAAKESV3TQJVQsL9a")
        ]
        for (format, phrase, expected) in vectors {
            let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = try await LegacySeedRecovery.source(format: format, phrase: phrase, passphrase: "")
            let engine = WalletEngine()
            try await engine.restore(at: dir.appending(path: "wallet"), password: UUID().uuidString, source: source, height: 0)
            let snapshot = try await engine.snapshot()
            XCTAssertEqual(snapshot.addresses.first?.address, expected)
            try await engine.close()
        }
    }
}
