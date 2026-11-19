import Foundation
import XCTest
@testable import XMRMoneroWallet

final class TorClientTests: XCTestCase {
    func testBootstrapRequiresEstablishedCircuitAndLoopbackSOCKS() {
        let incomplete = TorBootstrapStatus(lines: ["status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=75",
                                                    "status/circuit-established=0", "net/listeners/socks=\"192.0.2.44:9050\""])
        XCTAssertEqual(incomplete.progress, 75)
        XCTAssertFalse(incomplete.established)
        XCTAssertNil(incomplete.endpoint)
        let ready = TorBootstrapStatus(lines: ["status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100",
                                               "status/circuit-established=1", "net/listeners/socks=\"127.0.0.1:49190\""])
        XCTAssertEqual(ready.progress, 100)
        XCTAssertTrue(ready.established)
        XCTAssertEqual(ready.endpoint, "127.0.0.1:49190")
    }

    @MainActor
    func testOwningSocketStopsNativeThreadAndAllowsRestartWithoutNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cycles = ProcessInfo.processInfo.environment["XMR_TOR_STRESS"] == "1" ? 100 : 6
        for _ in 0..<cycles {
            let session = try TorControlSession(directory: folder)
            do {
                let until = ContinuousClock.now.advanced(by: .seconds(15))
                _ = try await session.command("AUTHENTICATE", until: until)
                let settings = try await session.command("GETCONF DisableNetwork ControlPort __DisableSignalHandlers", until: until)
                XCTAssertTrue(settings.contains("DisableNetwork=1"))
                XCTAssertTrue(settings.contains("ControlPort=0"))
                XCTAssertTrue(settings.contains("__DisableSignalHandlers=1"))
            } catch {
                session.stop()
                await session.waitForExit()
                throw error
            }
            session.stop()
            await session.waitForExit()
        }
    }

    @MainActor
    func testLiveMainnetNodeThroughEmbeddedTor() async throws {
        guard ProcessInfo.processInfo.environment["XMR_LIVE_TOR"] == "1" else {
            throw XCTSkip("Set XMR_LIVE_TOR=1 to contact the Tor network and a public Monero onion node.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tor = EmbeddedTor(directory: folder.appendingPathComponent("tor"))
        let wallet = WalletEngine()
        do {
            var progress = [Int]()
            let proxy = try await tor.start { progress.append($0) }
            XCTAssertTrue(progress.contains(100))
            let walletFile = folder.appendingPathComponent("test-wallet")
            let password = UUID().uuidString
            _ = try await wallet.create(at: walletFile, password: password)
            let node = try XCTUnwrap(ConnectionSettings.onionNodes.first)
            try await wallet.connect(node: node, proxy: proxy)
            let snapshot = try await wallet.snapshot()
            XCTAssertTrue(snapshot.connected)
            XCTAssertGreaterThan(snapshot.targetHeight, 0)
            _ = try await wallet.addAddress(label: "Live scan")
            tor.stop()
            try await wallet.close()
            try await wallet.open(at: walletFile, password: password)
            let reopened = try await wallet.snapshot()
            XCTAssertTrue(reopened.addresses.contains { $0.label == "Live scan" })
            try await wallet.close()
            try await tor.eraseState()
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tor").path))
        } catch {
            tor.stop()
            try? await wallet.close()
            try? await tor.eraseState()
            throw error
        }
    }
}
