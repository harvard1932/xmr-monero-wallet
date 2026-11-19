import Foundation
import Network

enum ConnectionMode: String, CaseIterable, Identifiable {
    case offline, automatic, pinned, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .offline: return "Offline"
        case .automatic: return "Automatic"
        case .pinned: return "Choose a public node"
        case .custom: return "My node"
        }
    }
}

struct ConnectionSettings: Codable, Equatable {
    var mode = ConnectionMode.offline.rawValue
    var endpoint = ""
    var pinnedNode: URL?
    var useProxy = false
    var proxy = "127.0.0.1:9050"
    // Missing in v0.1 preferences, which always used an explicitly configured proxy.
    var externalTor: Bool? = false
    var usesExternalTor: Bool { externalTor ?? true }
    var selection: ConnectionMode { ConnectionMode(rawValue: mode) ?? .offline }

    func validate() throws {
        if selection == .pinned && !directory.contains(where: { $0.url == pinnedNode }) {
            throw WalletEngineError("Choose a public node")
        }
        if selection == .custom { _ = try customURL() }
        if useProxy && usesExternalTor && selection != .offline {
            let parts = proxy.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "127.0.0.1",
                  let port = UInt16(parts[1]), port > 0 else {
                throw WalletEngineError("Enter a local SOCKS proxy as 127.0.0.1:port.")
            }
        }
    }

    func customURL() throws -> URL {
        guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw WalletEngineError("Enter a full node URL including its scheme and port, without credentials or a path.")
        }
        if useProxy {
            let labels = host.split(separator: ".")
            guard parts.scheme?.lowercased() == "http", labels.count == 2, labels[1] == "onion",
                  labels[0].utf8.count == 56, labels[0].utf8.allSatisfy({ (97...122).contains($0) || (50...55).contains($0) }) else {
                throw WalletEngineError("Tor mode requires an http:// v3 onion node address.")
            }
        } else {
            guard !host.hasSuffix(".onion") else { throw WalletEngineError("Enable a local Tor proxy to use an onion node.") }
            guard parts.scheme?.lowercased() == "https" || ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else {
                throw WalletEngineError("Use HTTPS for a remote node, or an onion address through Tor.")
            }
        }
        parts.scheme = parts.scheme?.lowercased()
        guard let url = parts.url else { throw WalletEngineError("Check the node address.") }
        return url
    }

    struct PublicNode: Identifiable, Sendable {
        let name: String
        let url: URL
        var id: URL { url }

        init(_ name: String, _ url: String) {
            self.name = name
            self.url = URL(string: url)!
        }

        func matches(_ search: String) -> Bool {
            let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return term.isEmpty || name.localizedCaseInsensitiveContains(term) || (url.host ?? "").localizedCaseInsensitiveContains(term)
        }
    }

    // Static operator endpoints, including Feather's public directory. No directory
    // service is contacted. Clearnet entries must provide a trusted HTTPS certificate.
    static let directDirectory = [
        PublicNode("Cake Wallet", "https://xmr-node.cakewallet.com:18081"),
        PublicNode("Seth For Privacy", "https://node.sethforprivacy.com:443"),
        PublicNode("Ducks Party", "https://xmr.ducks.party:443"),
        PublicNode("MoneroDevs I", "https://node.monerodevs.org:18089"),
        PublicNode("MoneroDevs II", "https://node2.monerodevs.org:18089"),
        PublicNode("MoneroDevs III", "https://node3.monerodevs.org:18089"),
        PublicNode("RavFX I", "https://ravfx.its-a-node.org:18081"),
        PublicNode("RavFX II", "https://ravfx2.its-a-node.org:18089")
    ]
    static let torDirectory = [
        PublicNode("Plowsof I", "http://plowsof3t5hogddwabaeiyrno25efmzfxyro2vligremt7sxpsclfaid.onion:18089"),
        PublicNode("Rucknium", "http://rucknium757bokwv3ss35ftgc3gzb7hgbvvglbg3hisp7tsj2fkd2nyd.onion:18081"),
        PublicNode("Baz", "http://loveanvthlsepingenr7opdqy6nlhn5jidwvzzxfmwsw2rry5mn2gfqd.onion:18089"),
        PublicNode("Boldsuck", "http://ip4zpbps7unk6xhlanqtw24f75akfbl3upeckfjqjks7ftfnk4i73oid.onion:18081"),
        PublicNode("Plowsof II", "http://plowsoffjexmxalw73tkjmf422gq6575fc7vicuu4javzn2ynnte6tyd.onion:18089"),
        PublicNode("Plowsof III", "http://plowsofe6cleftfmk2raiw5h2x66atrik3nja4bfd3zrfa2hdlgworad.onion:18089"),
        PublicNode("RavFX I", "http://ravfxmrqgd4j2o2gdc2yaij2wcmkcflu2rdnzhng5htk5hgnh6gmyeid.onion:18081"),
        PublicNode("RavFX II", "http://ravfxmrzi3eet62s4nkuu5sgpq6otgtffluk3ylb2kuvimtb34sonryd.onion:18089"),
        PublicNode("StormyCloud", "http://a6orjo6aiotog3njppja5jwnd3rexzfjiejxnojvw74p3kma45fundid.onion:18089"),
        PublicNode("Witch of the Wind", "http://moneroxmrxw44lku6qniyarpwgznpcwml4drq7vb24ppatlcg4kmxpqd.onion:18089")
    ]
    static let publicNodes = directDirectory.map(\.url)
    static let onionNodes = torDirectory.map(\.url)
    var directory: [PublicNode] { useProxy ? Self.torDirectory : Self.directDirectory }
    var isPublic: Bool { selection == .automatic || selection == .pinned }

    static func responseTime(_ node: PublicNode, proxy: String?) async throws -> Duration {
        let start = ContinuousClock.now
        let data: Data
        if let proxy {
            guard torDirectory.contains(where: { $0.url == node.url }) else { throw URLError(.unsupportedURL) }
            data = try await OnionHealthProbe.read(node.url, proxy: proxy)
        } else {
            guard directDirectory.contains(where: { $0.url == node.url }) else { throw URLError(.unsupportedURL) }
            data = try await PublicJSON.read(node.url.appending(path: "get_info"), limit: 128 * 1024, timeout: 5)
        }
        let info = try JSONDecoder().decode(NodeInfo.self, from: data)
        guard info.healthy else { throw URLError(.badServerResponse) }
        return start.duration(to: .now)
    }

    // Probe directly only after choosing a direct public route. Start wallet2 as
    // soon as a healthy node replies, with the other origins available for failover.
    // Probes contain only get_info. A proxy selection never uses URLSession for probes.
    func candidates(through activeProxy: String? = nil) async throws -> [URL] {
        try validate()
        switch selection {
        case .offline: return []
        case .custom: return [try customURL()]
        case .pinned: return pinnedNode.map { [$0] } ?? []
        case .automatic:
            // Until Tor is ready the directory can be listed entirely offline.
            if useProxy && activeProxy == nil { return Self.onionNodes }
            let nodes = directory
            let origins = nodes.map(\.url)
            let routeProxy = useProxy ? activeProxy : nil
            return await withTaskGroup(of: URL?.self) { group in
                for node in nodes {
                    group.addTask {
                        guard (try? await Self.responseTime(node, proxy: routeProxy)) != nil else { return nil }
                        return node.url
                    }
                }
                for await result in group {
                    if let first = result {
                        group.cancelAll()
                        return [first] + origins.filter { $0 != first }
                    }
                }
                return []
            }
        }
    }

    struct NodeInfo: Decodable {
        let mainnet: Bool
        let height: UInt64
        let status: String
        let offline: Bool?
        let synchronized: Bool?
        let target_height: UInt64?
        var healthy: Bool {
            guard mainnet, status == "OK", height > 0, offline != true, synchronized != false else { return false }
            let target = target_height ?? 0
            return target <= height || target - height <= 3
        }
    }
}


/// Price requests and node probes go only to the selected origin. Limit both
/// claimed and actual bytes, including responses using chunked transfer.
enum PublicJSON {
    static func read(_ url: URL, limit: Int, timeout: TimeInterval) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: NoNodeRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

private final class NoNodeRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Manual health checks send the onion hostname to the selected SOCKS4a listener.
/// The only socket opened by this code targets the numeric loopback address.
private enum OnionHealthProbe {
    private static let queue = DispatchQueue(label: "wallet.onion-health")
    private static let bodyLimit = 128 * 1024

    static func read(_ url: URL, proxy: String) async throws -> Data {
        let parts = proxy.components(separatedBy: ":")
        guard parts.count == 2, parts[0] == "127.0.0.1", let port = UInt16(parts[1]),
              port > 0, let proxyPort = NWEndpoint.Port(rawValue: port), let host = url.host,
              let rpcPort = UInt16(exactly: url.port ?? 80) else { throw URLError(.unsupportedURL) }
        let connection = NWConnection(host: .ipv4(.loopback), port: proxyPort, using: .tcp)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 15, execute: deadline)
        defer { deadline.cancel(); connection.cancel() }
        return try await withTaskCancellationHandler {
            connection.start(queue: queue)
            var request = Data([4, 1, UInt8(rpcPort >> 8), UInt8(truncatingIfNeeded: rpcPort), 0, 0, 0, 1, 0])
            request.append(contentsOf: host.utf8)
            request.append(0)
            try await send(request, to: connection)
            var reply = Data()
            while reply.count < 8 {
                let (bytes, end) = try await receive(connection, length: 8 - reply.count)
                reply += bytes
                if end && reply.count < 8 { throw URLError(.cannotConnectToHost) }
            }
            guard reply[0] == 0, reply[1] == 90 else { throw URLError(.cannotConnectToHost) }
            // HTTP/1.0 provides a close-delimited response without chunk framing.
            let query = "GET /get_info HTTP/1.0\r\nHost: \(host):\(rpcPort)\r\nConnection: close\r\n\r\n"
            try await send(Data(query.utf8), to: connection)
            var response = Data()
            while true {
                let (bytes, end) = try await receive(connection, length: 8192)
                response += bytes
                guard response.count <= bodyLimit + 8192 else { throw URLError(.dataLengthExceedsMaximum) }
                if end { break }
            }
            guard let separator = response.range(of: Data("\r\n\r\n".utf8)), separator.lowerBound <= 8192,
                  let header = String(data: response[..<separator.lowerBound], encoding: .isoLatin1),
                  header.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first == "200",
                  response.count - separator.upperBound <= bodyLimit else { throw URLError(.badServerResponse) }
            return Data(response[separator.upperBound...])
        } onCancel: { connection.cancel() }
    }

    private static func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    private static func receive(_ connection: NWConnection, length: Int) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { done in
            connection.receive(minimumIncompleteLength: 1, maximumLength: length) { bytes, _, end, error in
                if let error { done.resume(throwing: error) }
                else if bytes?.isEmpty != false && !end { done.resume(throwing: URLError(.networkConnectionLost)) }
                else { done.resume(returning: (bytes ?? Data(), end)) }
            }
        }
    }
}
