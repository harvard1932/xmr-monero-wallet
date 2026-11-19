import XCTest
@testable import XMRMoneroWallet

final class FeatureParityTests: XCTestCase {
    func testPrivacyPulseIsDeterministicAndEveryControlChangesItsScore() {
        var direct = ConnectionSettings()
        direct.mode = ConnectionMode.automatic.rawValue
        let plain = PrivacyPulse(backedUp: false, locked: false, hasSubaddress: false, route: direct)
        XCTAssertEqual(plain.score, 0)
        XCTAssertEqual(PrivacyPulse(backedUp: true, locked: true, hasSubaddress: true, route: direct).score, 60)
        direct.mode = ConnectionMode.custom.rawValue
        direct.useProxy = true
        let protected = PrivacyPulse(backedUp: true, locked: true, hasSubaddress: true, route: direct)
        XCTAssertEqual(protected.score, 100)
        XCTAssertEqual(protected.complete, Set(PrivacyPulse.Control.allCases))
    }

    func testNewTorChoicesUseEmbeddedClientAndPreviousProxyChoicesSurvive() throws {
        var fresh = ConnectionSettings()
        fresh.mode = ConnectionMode.automatic.rawValue
        fresh.useProxy = true
        XCTAssertFalse(fresh.usesExternalTor)
        let legacy = try JSONDecoder().decode(ConnectionSettings.self, from: Data(#"{"mode":"automatic","endpoint":"","useProxy":true,"proxy":"127.0.0.1:9150"}"#.utf8))
        XCTAssertTrue(legacy.usesExternalTor)
        XCTAssertEqual(legacy.proxy, "127.0.0.1:9150")
        XCTAssertEqual(try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(fresh)), fresh)
    }

    func testDisconnectedAndStalledPublicNodesAreRetried() throws {
        XCTAssertFalse(WalletSession.shouldRetry(connected: true, synced: false, elapsed: 40))
        XCTAssertTrue(WalletSession.shouldRetry(connected: true, synced: false, elapsed: 75))
        XCTAssertTrue(WalletSession.shouldRetry(connected: false, synced: false, elapsed: 15))
        XCTAssertFalse(WalletSession.shouldRetry(connected: true, synced: true, elapsed: 75))
        XCTAssertTrue(WalletSession.shouldRetry(connected: true, synced: true, elapsed: 900))
        func health(_ json: String) throws -> Bool {
            try JSONDecoder().decode(ConnectionSettings.NodeInfo.self, from: Data(json.utf8)).healthy
        }
        XCTAssertTrue(try health(#"{"mainnet":true,"height":10,"status":"OK","target_height":0}"#))
        XCTAssertFalse(try health(#"{"mainnet":true,"height":10,"status":"OK","target_height":500}"#))
        XCTAssertFalse(try health(#"{"mainnet":true,"height":10,"status":"OK","offline":true}"#))
    }

    func testIntradayAndLongTermChartsUseAppropriateIntervals() throws {
        XCTAssertEqual(PriceWindow.day.minutes, 5)
        XCTAssertEqual(PriceWindow.quarter.minutes, 1440)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let url = try XCTUnwrap(URLComponents(url: PriceWindow.week.request(at: now), resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "since" })?.value, String(2_000_000_000 - 7 * 86400))
        let valid = #"{"error":[],"result":{"XXMRZUSD":[[200,"0","0","0","2.01"],[100,"0","0","0","1.45"]]}}"#
        XCTAssertEqual(try MarketChart.prices(from: Data(valid.utf8)).map(\.usd), [1.45, 2.01])
        XCTAssertThrowsError(try MarketChart.prices(from: Data(#"{"error":["Unknown pair"]}"#.utf8)))
    }

    @MainActor
    func testLivePriceChartLoadsRealIntradayCandles() async throws {
        guard ProcessInfo.processInfo.environment["XMR_LIVE_MARKET"] == "1" else {
            throw XCTSkip("Opt in to requesting the chart's public XMR/USD prices from Kraken.")
        }
        let now = Date()
        let response = try await PublicJSON.read(PriceWindow.day.request(at: now), limit: 512 * 1024, timeout: 12)
        let candles = try MarketChart.prices(from: response)
        XCTAssertGreaterThan(candles.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(candles.last?.date), now.addingTimeInterval(-3600))
    }

    @MainActor
    func testNewWalletNeverInheritsAnotherWalletsOnlineRouteAndOldRouteMigrates() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = ConnectionSettings()
        legacy.mode = ConnectionMode.automatic.rawValue
        defaults.set(try JSONEncoder().encode(legacy), forKey: "connection")
        func wallet(_ name: String) throws -> VaultLocation {
            let dir = folder.appending(path: name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return VaultLocation(wallet: VaultWallet(id: UUID(), name: name, createdAt: Date(), backupVerified: true),
                                 fileURL: dir.appending(path: "wallet"), password: UUID().uuidString)
        }
        let session = WalletSession(preferences: defaults)
        let old = try wallet("older")
        let writer = WalletEngine()
        _ = try await writer.create(at: old.fileURL, password: old.password)
        try await writer.close()
        try await session.open(old)
        XCTAssertEqual(session.connection.selection, .automatic)
        XCTAssertFalse(session.needsNetworkChoice)
        await session.close()
        let new = try wallet("separate-signer")
        _ = try await session.create(new)
        XCTAssertEqual(session.connection.selection, .offline)
        XCTAssertTrue(session.needsNetworkChoice)
        try session.saveConnection(ConnectionSettings())
        await session.close()
        try await session.open(new)
        XCTAssertEqual(session.connection.selection, .offline)
        XCTAssertFalse(session.needsNetworkChoice)
        await session.close()
        try await session.open(old)
        XCTAssertEqual(session.connection.selection, .automatic)
        await session.close()
    }

    @MainActor
    func testLockDuringLiveScanRemovesWalletAccessAndRetainsProgress() async throws {
        guard ProcessInfo.processInfo.environment["XMR_LIVE_NODE_TEST"] == "1" else {
            throw XCTSkip("Opt in to testing a lock during public-node sync with a disposable wallet.")
        }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "syncActivity")
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loc = VaultLocation(wallet: VaultWallet(id: UUID(), name: "Lock test", createdAt: Date(), backupVerified: true),
                                fileURL: folder.appending(path: "wallet"), password: UUID().uuidString)
        let session = WalletSession(preferences: defaults)
        _ = try await session.create(loc)
        do {
            let original = try await session.primaryAddress()
            var route = ConnectionSettings()
            route.mode = ConnectionMode.automatic.rawValue
            try await session.chooseInitialConnection(route)
            let before = try XCTUnwrap(session.lockScreenProgress, session.problem ?? "Missing scan progress")
            XCTAssertEqual(before.phase, .scanning)
            session.lockForBackground(allowProgress: true)
            XCTAssertNil(session.data)
            XCTAssertThrowsError(try session.liveEngine())
            try await Task.sleep(for: .seconds(2))
            session.finishBackgroundScan()
            let after = try XCTUnwrap(session.lockScreenProgress)
            XCTAssertTrue(after.phase == .paused || after.phase == .complete)
            XCTAssertGreaterThanOrEqual(after.height, before.height)
            await session.close()
            try await session.open(loc)
            let reopened = try await session.primaryAddress()
            XCTAssertEqual(reopened, original)
            await session.close()
        } catch { await session.close(); throw error }
    }

    func testRestrictedScanDiscardsSpendingAuthorityAndReopensWithOriginalKeys() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = WalletEngine(testnet: true)
        let file = folder.appending(path: "wallet")
        let pass = UUID().uuidString
        let original = try await core.create(at: file, password: pass)
        do {
            try await core.configureRestrictedScan(password: pass)
            try await core.enterRestrictedScan()
            _ = try await core.scanHeight()
            do {
                _ = try await core.seed()
                XCTFail("An engine restricted to scanning must never return recovery words")
            } catch {}
            try await core.close()
            try await core.open(at: file, password: pass)
            let restored = try await core.seed()
            XCTAssertEqual(restored, original)
            try await core.close()
        } catch { try? await core.close(); throw error }
    }
}
