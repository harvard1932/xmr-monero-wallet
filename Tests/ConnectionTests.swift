import XCTest
@testable import XMRMoneroWallet

final class ConnectionTests: XCTestCase {
    func testConnectionDefaultsAndProxyRestrictions() async throws {
        var config = ConnectionSettings()
        let offline = try await config.candidates()
        XCTAssertTrue(offline.isEmpty)
        config.mode = ConnectionMode.custom.rawValue
        for url in ["http://node.example", "https://name:secret@node.example", "https://node.example/other",
                    "http://example.onion:18081"] {
            config.endpoint = url
            XCTAssertThrowsError(try config.validate())
        }
        config.endpoint = "https://node.example:18089"
        XCTAssertNoThrow(try config.validate())
        config.useProxy = true
        config.externalTor = true
        config.proxy = "192.0.2.2:9050"
        XCTAssertThrowsError(try config.validate())
    }

    func testDirectoryHasFiftyDistinctTLSHostsAndSeparateOnionRoutes() {
        let direct = ConnectionSettings.directDirectory
        XCTAssertEqual(direct.count, 50)
        XCTAssertEqual(Set(direct.compactMap { $0.url.host }).count, direct.count)
        XCTAssertTrue(direct.allSatisfy { $0.url.scheme == "https" && $0.url.user == nil && $0.url.password == nil })
        let tor = ConnectionSettings.torDirectory
        XCTAssertTrue(tor.allSatisfy { $0.url.host?.hasSuffix(".onion") == true })
        XCTAssertTrue(Set(direct.map(\.url)).isDisjoint(with: tor.map(\.url)))
    }

    func testPinnedNodesPersistWithoutBecomingTrustedCustomNodes() async throws {
        var settings = ConnectionSettings()
        settings.mode = ConnectionMode.pinned.rawValue
        XCTAssertThrowsError(try settings.validate())
        let node = try XCTUnwrap(settings.directory.first { $0.matches("monerodevs iii") })
        XCTAssertTrue(node.matches("node3.monero"))
        XCTAssertFalse(node.matches("onion"))
        settings.pinnedNode = node.url
        let roundTrip = try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings))
        let direct = try await roundTrip.candidates()
        XCTAssertEqual(direct, [node.url])
        XCTAssertEqual(roundTrip.selection, .pinned)
        settings.useProxy = true
        XCTAssertThrowsError(try settings.validate())
        settings.pinnedNode = try XCTUnwrap(settings.directory.first?.url)
        let onion = try await settings.candidates()
        XCTAssertEqual(onion, [settings.pinnedNode!])
        settings.pinnedNode = URL(string: "http://127.0.0.1")
        XCTAssertThrowsError(try settings.validate())
    }

    func testLoopbackListenerChallengesUnauthenticatedRequests() async throws {
        let relay = try NodeRelay(upstream: URL(string: "https://node.invalid")!, proxy: nil)
        defer { relay.stop() }
        let base = try await relay.start()
        XCTAssertEqual(base.host, "127.0.0.1")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: base.appending(path: "get_info"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        XCTAssertTrue(http.value(forHTTPHeaderField: "WWW-Authenticate")?.hasPrefix("Digest ") == true)
    }

    /// Run explicitly with XMR_LIVE_NODE_TEST=1 in the test process environment.
    func testWallet2ConnectsThroughSystemTLS() async throws {
        guard ProcessInfo.processInfo.environment["XMR_LIVE_NODE_TEST"] == "1" else {
            throw XCTSkip("Opt in to contacting a public mainnet node with a fresh, empty wallet.")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = WalletEngine()
        let relay = try NodeRelay(upstream: ConnectionSettings.publicNodes[0], proxy: nil)
        defer { relay.stop() }
        do {
            _ = try await core.create(at: folder.appending(path: "wallet"), password: UUID().uuidString)
            let url = try await relay.start()
            try await core.connect(node: url, username: relay.username, password: relay.password)
            let snapshot = try await core.snapshot()
            XCTAssertTrue(snapshot.connected)
            XCTAssertGreaterThan(snapshot.targetHeight, 3_000_000)
            try await core.close()
        } catch {
            try? await core.close()
            throw error
        }
    }
}
