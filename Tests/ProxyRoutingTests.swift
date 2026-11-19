import Foundation
import Network
import ObjectiveC
import XCTest
@testable import XMRMoneroWallet

final class ProxyRoutingTests: XCTestCase {
    func testWallet2SendsOnionHostnameToSelectedSOCKS4aProxyAndHonorsRefusal() async throws {
        var settings = ConnectionSettings()
        settings.mode = ConnectionMode.automatic.rawValue
        settings.useProxy = true
        let candidates = try await settings.candidates()
        let host = try XCTUnwrap(candidates.first?.host)
        XCTAssertTrue(host.hasSuffix(".onion"))
        let endpoint = try XCTUnwrap(URL(string: "http://\(host):18081"))
        let received = XCTestExpectation(description: "Native wallet requests the exact onion host through SOCKS4a")
        let socks = try LoopbackTestListener { peer in
            // The frame includes the requested port, SOCKS4a address marker,
            // user ID, and NUL-terminated hostname. Wait for a full frame.
            let prefix: [UInt8] = [4, 1, 0x46, 0xA1, 0, 0, 0, 1]
            let expected = Data(prefix + [0] + Array(host.utf8) + [0])
            peer.receive(minimumIncompleteLength: expected.count, maximumLength: 1024) { bytes, _, _, _ in
                XCTAssertEqual(bytes, expected, "The proxy must receive the hostname, without local DNS resolution.")
                if bytes == expected { received.fulfill() }
                // SOCKS4 request rejected. No bytes are forwarded to an external peer.
                peer.send(content: Data([0, 91, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in peer.cancel() })
            }
        }
        let port = try await socks.start()
        defer { socks.stop() }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wallet = WalletEngine(testnet: true)
        _ = try await wallet.create(at: root.appending(path: "wallet"), password: UUID().uuidString)
        do {
            try await wallet.connect(node: endpoint, proxy: "127.0.0.1:\(port)")
            XCTFail("A refused SOCKS4a request must fail the connection.")
        } catch {}
        do {
            let state = try await wallet.snapshot()
            XCTAssertFalse(state.connected)
            XCTAssertFalse(state.synchronized)
            try await wallet.close()
        } catch {
            try? await wallet.close()
            throw error
        }
        await fulfillment(of: [received], timeout: 3)
    }

    func testCustomTorModeRejectsHTTPSAndLoopbackBeforeOpeningTransport() throws {
        var settings = ConnectionSettings()
        settings.mode = ConnectionMode.custom.rawValue
        settings.useProxy = true
        for endpoint in ["https://example.com:18081", "https://127.0.0.1:18081",
                         "http://127.0.0.1:18081", "http://localhost:18081", "http://short.onion:18081"] {
            settings.endpoint = endpoint
            XCTAssertThrowsError(try settings.validate(), endpoint)
        }
        XCTAssertThrowsError(try NodeRelay(upstream: XCTUnwrap(URL(string: "https://127.0.0.1:18081")),
                                            proxy: "127.0.0.1:9050"))
    }

    func testManualOnionHealthCheckSendsHostnameToSelectedProxy() async throws {
        let onion = try XCTUnwrap(ConnectionSettings.torDirectory.first)
        let host = try XCTUnwrap(onion.url.host)
        let rpc = UInt16(try XCTUnwrap(onion.url.port))
        let request = Data([4, 1, UInt8(rpc >> 8), UInt8(truncatingIfNeeded: rpc), 0, 0, 0, 1, 0] + Array(host.utf8) + [0])
        let socks = try LoopbackTestListener { peer in
            peer.receive(minimumIncompleteLength: request.count, maximumLength: request.count) { bytes, _, _, _ in
                guard bytes == request else { XCTFail("The check did not send the onion hostname to the selected proxy."); peer.cancel(); return }
                peer.send(content: Data([0, 90, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in
                    peer.receive(minimumIncompleteLength: 14, maximumLength: 4096) { bytes, _, _, _ in
                        XCTAssertTrue(String(decoding: bytes ?? Data(), as: UTF8.self).hasPrefix("GET /get_info "))
                        let reply = "HTTP/1.0 200 OK\r\nConnection: close\r\n\r\n" + #"{"mainnet":true,"height":55,"status":"OK","synchronized":true}"#
                        peer.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true,
                                  completion: .contentProcessed { _ in peer.cancel() })
                    }
                })
            }
        }
        let port = try await socks.start()
        defer { socks.stop() }
        let duration = try await ConnectionSettings.responseTime(onion, proxy: "127.0.0.1:\(port)")
        XCTAssertGreaterThan(duration, .zero)
        do {
            _ = try await ConnectionSettings.responseTime(onion, proxy: nil)
            XCTFail("Onion checks require a proxy.")
        } catch {}
        do {
            _ = try await ConnectionSettings.responseTime(ConnectionSettings.directDirectory[0], proxy: "127.0.0.1:\(port)")
            XCTFail("Tor checks only allow onion destinations.")
        } catch {}
    }

    func testAutomaticProxiedCandidatesDoNotProbePublicNodes() async throws {
        // candidates() normally probes with an ephemeral URLSession. In this test
        // those sessions get a protocol that records and rejects each public-node
        // request before DNS or network I/O. A control request checks the trap.
        let type: AnyClass = URLSessionConfiguration.self
        let normal = try XCTUnwrap(class_getClassMethod(type, NSSelectorFromString("ephemeralSessionConfiguration")))
        let intercepted = try XCTUnwrap(class_getClassMethod(type, #selector(URLSessionConfiguration.proxyTestEphemeral)))
        method_exchangeImplementations(normal, intercepted)
        defer { method_exchangeImplementations(normal, intercepted) }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        ProbeBlocker.clear()
        do {
            _ = try await session.data(from: ConnectionSettings.publicNodes[0].appending(path: "get_info"))
            XCTFail("The control probe should have been intercepted.")
        } catch {}
        XCTAssertEqual(ProbeBlocker.takeCount(), 1, "The test must observe a direct URLSession probe.")
        var settings = ConnectionSettings()
        settings.mode = ConnectionMode.automatic.rawValue
        settings.useProxy = true
        let result = try await settings.candidates()
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result, ConnectionSettings.onionNodes)
        for candidate in result {
            XCTAssertEqual(candidate.scheme, "http")
            let host = try XCTUnwrap(candidate.host)
            XCTAssertNotNil(host.range(of: "^[a-z2-7]{56}\\.onion$", options: .regularExpression), "Expected a Tor v3 hostname.")
        }
        XCTAssertEqual(ProbeBlocker.takeCount(), 0, "Selecting candidates must not contact public nodes directly.")
    }

}

private final class LoopbackTestListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "wallet.tests.proxy-listener")

    init(accepted: @escaping @Sendable (NWConnection) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] peer in
            peer.start(queue: queue)
            accepted(peer)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: URLError(.cannotCreateFile)) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

private extension URLSessionConfiguration {
    @objc dynamic class func proxyTestEphemeral() -> URLSessionConfiguration {
        // While exchanged, this selector invokes Foundation's original implementation.
        let config = proxyTestEphemeral()
        config.protocolClasses = [ProbeBlocker.self] + (config.protocolClasses ?? [])
        return config
    }
}

private final class ProbeBlocker: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var count = 0

    static func clear() { _ = takeCount() }
    static func takeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = count
        count = 0
        return value
    }

    override class func canInit(with request: URLRequest) -> Bool {
        (ConnectionSettings.publicNodes + ConnectionSettings.onionNodes).contains { $0.host == request.url?.host }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
