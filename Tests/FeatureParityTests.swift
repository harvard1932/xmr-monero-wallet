import XCTest
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import ImageIO
@testable import XMRMoneroWallet

final class FeatureParityTests: XCTestCase {
    func testPrivacyPulseReflectsWalletProtectionsAndChosenRoute() {
        var route = ConnectionSettings()
        func score(pin: Bool = false, biometric: Bool = false, backup: Bool = false, invoices: Bool = true, choseRoute: Bool = true) -> Int {
            PrivacyPulse(backedUp: backup, hasPIN: pin, hasBiometrics: biometric, freshInvoices: invoices, route: route, choseRoute: choseRoute).score
        }
        XCTAssertEqual(score(choseRoute: false), 77)
        XCTAssertEqual(score(), 82)
        route.mode = ConnectionMode.automatic.rawValue
        XCTAssertEqual(score(), 77)
        XCTAssertEqual(score(invoices: false), 67)
        XCTAssertEqual(score(pin: true), 85)
        XCTAssertEqual(score(biometric: true), 77)
        XCTAssertEqual(score(pin: true, biometric: true), 88)
        XCTAssertEqual(score(backup: true), 84)
        route.useProxy = true
        XCTAssertEqual(score(pin: true, biometric: true, backup: true), 100)
        route.useProxy = false
        route.mode = ConnectionMode.custom.rawValue
        XCTAssertEqual(score(), 82)
    }

    func testPrivacyPulseCreditsDistinctSavedInvoiceSubaddresses() {
        let primary = WalletAddressItem(id: 0, label: "", address: "primary")
        let first = WalletAddressItem(id: 1, label: "", address: "first")
        let second = WalletAddressItem(id: 2, label: "", address: "second")
        let addresses = [primary, first, second]
        func invoice(_ address: String) -> WalletInvoiceItem { .init(label: "", address: address, amount: 1) }
        XCTAssertFalse(PrivacyPulse.hasFreshInvoices([], addresses: addresses))
        XCTAssertFalse(PrivacyPulse.hasFreshInvoices([invoice("primary")], addresses: addresses))
        XCTAssertFalse(PrivacyPulse.hasFreshInvoices([invoice("other")], addresses: addresses))
        XCTAssertFalse(PrivacyPulse.hasFreshInvoices([invoice("first"), invoice("first")], addresses: addresses))
        XCTAssertTrue(PrivacyPulse.hasFreshInvoices([invoice("first"), invoice("second")], addresses: addresses))
    }

    @MainActor
    func testAmountSpecificReceiveQRAndPhotoImport() throws {
        let address = "44yQXfkWZNmJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmJ7suhUXwdrDJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmCYrSgjJ"
        let locale = Locale(identifier: "de_DE")
        let uri = try XCTUnwrap(ReceiveView.paymentRequest(for: address, amount: "0,000000000001", locale: locale))
        XCTAssertEqual(try MoneroPaymentTarget(uri).amount, 1)
        XCTAssertEqual(ReceiveView.paymentRequest(for: address, amount: "", locale: locale), address)
        XCTAssertNil(ReceiveView.paymentRequest(for: address, amount: "0", locale: locale))
        XCTAssertNil(ReceiveView.paymentRequest(for: address, amount: "0,0000000000001", locale: locale))

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        let encoded = try XCTUnwrap(filter.outputImage)
        let extent = encoded.extent.insetBy(dx: -5, dy: -5)
        let padded = encoded.composited(over: CIImage(color: .white).cropped(to: extent))
        let image = padded.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let raster = try XCTUnwrap(context.createCGImage(image, from: image.extent))
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(file, raster, nil)
        XCTAssertTrue(CGImageDestinationFinalize(file))
        XCTAssertEqual(try PaymentQRPhoto.read(url), uri)
        XCTAssertThrowsError(try PaymentQRPhoto.singlePayload([uri, "another QR"]))
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
        for window in PriceWindow.allCases {
            let url = try XCTUnwrap(URLComponents(url: window.request, resolvingAgainstBaseURL: false))
            XCTAssertEqual(url.host, "api.coingecko.com")
            XCTAssertEqual(url.queryItems?.first(where: { $0.name == "days" })?.value, String(window.rawValue))
        }
        let valid = #"{"prices":[[200000,2.01],[100000,1.45]]}"#
        XCTAssertEqual(try MarketChart.prices(from: Data(valid.utf8)).map(\.usd), [1.45, 2.01])
        XCTAssertThrowsError(try MarketChart.prices(from: Data(#"{"error":"Unknown pair"}"#.utf8)))
        let data = Data(#"{"monero":{"usd":210.5,"usd_24h_change":-3.2,"last_updated_at":200}}"#.utf8)
        let quote = try WalletMarketQuote.read(data, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(quote.fiat(XMRAmount.scale, locale: Locale(identifier: "en_US")), "$210.50")
        XCTAssertEqual(quote.change24h, -0.032, accuracy: 0.000001)
        XCTAssertThrowsError(try WalletMarketQuote.read(data, now: Date(timeIntervalSince1970: 5000)))
    }

    @MainActor
    func testLivePriceChartLoadsRealIntradayCandles() async throws {
        guard ProcessInfo.processInfo.environment["XMR_LIVE_MARKET"] == "1" else {
            throw XCTSkip("Opt in to requesting the chart's public XMR/USD prices from CoinGecko.")
        }
        let now = Date()
        let response = try await PublicJSON.read(PriceWindow.day.request, limit: 512 * 1024, timeout: 12)
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
