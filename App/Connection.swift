import Foundation

enum ConnectionMode: String, CaseIterable, Identifiable {
    case offline, automatic, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .offline: return "Offline"
        case .automatic: return "Public nodes"
        case .custom: return "My node"
        }
    }
}

struct ConnectionSettings: Codable, Equatable {
    var mode = ConnectionMode.offline.rawValue
    var endpoint = ""
    var useProxy = false
    var proxy = "127.0.0.1:9050"
    // Missing in v0.1 preferences, which always used an explicitly configured proxy.
    var externalTor: Bool? = false
    var usesExternalTor: Bool { externalTor ?? true }
    var selection: ConnectionMode { ConnectionMode(rawValue: mode) ?? .offline }

    func validate() throws {
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

    static let publicNodes = [
        URL(string: "https://xmr-node.cakewallet.com:18081")!,
        URL(string: "https://node.sethforprivacy.com:443")!
    ]

    // Embedded from the Feather Wallet mainnet directory. Node lists are never fetched at runtime.
    static let onionNodes = [
        URL(string: "http://plowsof3t5hogddwabaeiyrno25efmzfxyro2vligremt7sxpsclfaid.onion:18089")!,
        URL(string: "http://rucknium757bokwv3ss35ftgc3gzb7hgbvvglbg3hisp7tsj2fkd2nyd.onion:18081")!
    ]

    // Probe directly only after choosing a direct public route. Start wallet2 as
    // soon as a healthy node replies, with the other origins available for failover.
    // Probes contain only get_info. A proxy selection never uses URLSession for probes.
    func candidates() async throws -> [URL] {
        try validate()
        switch selection {
        case .offline: return []
        case .custom: return [try customURL()]
        case .automatic:
            if useProxy { return Self.onionNodes }
            return await withTaskGroup(of: URL?.self) { group in
                for node in Self.publicNodes {
                    group.addTask {
                        guard let data = try? await PublicJSON.read(node.appending(path: "get_info"), limit: 128 * 1024, timeout: 5),
                              let info = try? JSONDecoder().decode(NodeInfo.self, from: data),
                              info.healthy else { return nil }
                        return node
                    }
                }
                for await result in group {
                    if let first = result {
                        group.cancelAll()
                        return [first] + Self.publicNodes.filter { $0 != first }
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
