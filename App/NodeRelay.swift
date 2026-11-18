import Foundation
import Network
import CryptoKit

/// wallet2 talks HTTP only to loopback. URLSession authenticates the one upstream
/// HTTPS origin using the system trust store. No RPC credentials leave the phone.
final class NodeRelay: @unchecked Sendable {
    let username = UUID().uuidString
    let password = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "wallet.node-relay")
    private let listener: NWListener
    private let upstream: URL
    private let configuration: URLSessionConfiguration
    private let realm = "monero-rpc"
    private var peers = [UUID: NWConnection]()
    private var requests = [UUID: BoundedRequest]()
    private var nonces = [String: UInt32]()
    private var startup: CheckedContinuation<URL, Error>?
    private var stopped = false
    private static let headerLimit = 16 * 1024
    private static let bodyLimit = 16 * 1024 * 1024

    init(upstream: URL, proxy: String?) throws {
        guard upstream.scheme == "https", upstream.host != nil else { throw WalletEngineError("The relay requires HTTPS.") }
        self.upstream = upstream
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        configuration = .ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        guard proxy == nil else { throw WalletEngineError("Tor connections require the native onion transport.") }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                self.startup = continuation
                self.listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let callback = self.startup else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port else { return }
                        self.startup = nil
                        callback.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                    case .failed(let error):
                        self.startup = nil
                        callback.resume(throwing: error)
                    case .cancelled:
                        self.startup = nil
                        callback.resume(throwing: CancellationError())
                    default: break
                    }
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener.cancel()
            self.startup?.resume(throwing: CancellationError())
            self.startup = nil
            for job in self.requests.values { job.cancel() }
            for peer in self.peers.values { peer.cancel() }
            self.requests.removeAll()
            self.peers.removeAll()
            self.nonces.removeAll()
        }
    }

    private func accept(_ peer: NWConnection) {
        guard !stopped, peers.count < 12 else { peer.cancel(); return }
        let id = UUID()
        peers[id] = peer
        peer.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 100) { [weak self] in self?.finish(id) }
        receive(id, buffer: Data(), header: nil)
    }

    private func finish(_ id: UUID) {
        requests.removeValue(forKey: id)?.cancel()
        peers.removeValue(forKey: id)?.cancel()
    }

    private struct Header {
        let method: String
        let path: String
        let length: Int
        let authorization: String?
    }

    private func parse(_ bytes: Data) -> Header? {
        guard let raw = String(data: bytes, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count == 3, ["POST", "GET"].contains(parts[0]), ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]) else { return nil }
        let path = String(parts[1])
        guard path.first == "/", path.count < 100, path.count > 1,
              path.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }),
              !path.contains("..") else { return nil }
        var fields = [String: String]()
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].lowercased()
            guard fields[key] == nil else { return nil }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["transfer-encoding"] == nil,
              let size = Int(fields["content-length"] ?? "0"), (0...Self.bodyLimit).contains(size) else { return nil }
        return Header(method: String(parts[0]), path: path, length: size, authorization: fields["authorization"])
    }

    private func receive(_ id: UUID, buffer: Data, header: Header?) {
        guard let peer = peers[id] else { return }
        peer.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, eof, error in
            guard let self, self.peers[id] != nil, error == nil, let chunk, !chunk.isEmpty else { self?.finish(id); return }
            var data = buffer
            data.append(chunk)
            var parsed = header
            if parsed == nil {
                guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
                    if data.count > Self.headerLimit || eof { self.finish(id) }
                    else { self.receive(id, buffer: data, header: nil) }
                    return
                }
                guard boundary.lowerBound <= Self.headerLimit, let value = self.parse(Data(data[..<boundary.lowerBound])) else {
                    self.reply(id, code: 400); return
                }
                parsed = value
                data = Data(data[boundary.upperBound...])
            }
            guard let h = parsed, data.count <= h.length else { self.reply(id, code: 400); return }
            if data.count == h.length {
                self.handle(id, header: h, body: data)
            } else if eof { self.finish(id) }
            else { self.receive(id, buffer: data, header: h) }
        }
    }

    private func authorized(_ h: Header) -> Bool {
        guard let value = h.authorization, value.hasPrefix("Digest ") else { return false }
        var params = [String: String]()
        for part in value.dropFirst(7).split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            params[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        guard params["username"] == username, params["realm"] == realm, params["uri"] == h.path,
              params["qop"] == "auth", let nonce = params["nonce"], let last = nonces[nonce],
              let nc = params["nc"], nc.count == 8, let count = UInt32(nc, radix: 16), count > last,
              let response = params["response"]?.lowercased() else { return false }
        func md5(_ text: String) -> String { Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        let ha1 = md5([username, realm, password].joined(separator: ":"))
        let ha2 = md5([h.method, h.path].joined(separator: ":"))
        let expected = md5([ha1, nonce, nc, params["cnonce"] ?? "", "auth", ha2].joined(separator: ":"))
        guard Data(expected.utf8) == Data(response.utf8) else { return false }
        nonces[nonce] = count
        return true
    }

    private func handle(_ id: UUID, header: Header, body: Data) {
        guard authorized(header) else {
            if nonces.count >= 128, let old = nonces.keys.first { nonces.removeValue(forKey: old) }
            let nonce = UUID().uuidString
            nonces[nonce] = 0
            reply(id, code: 401, extra: "WWW-Authenticate: Digest realm=\"\(realm)\", nonce=\"\(nonce)\", algorithm=MD5, qop=\"auth\"\r\n")
            return
        }
        var req = URLRequest(url: upstream.appending(path: String(header.path.dropFirst())))
        req.httpMethod = header.method
        if header.method == "POST" { req.httpBody = body }
        let type = header.path.hasSuffix(".bin") ? "application/octet-stream" : "application/json"
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        let job = BoundedRequest()
        requests[id] = job
        job.start(configuration: configuration, request: req) { [weak self] status, bytes in
            guard let self else { return }
            self.queue.async {
                guard self.peers[id] != nil else { return }
                self.reply(id, code: status, extra: "Content-Type: \(type)\r\n", data: bytes)
            }
        }
    }

    private func reply(_ id: UUID, code: Int, extra: String = "", data: Data = Data()) {
        guard let peer = peers[id] else { return }
        let status = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 502: "Bad Gateway"][code] ?? "Node Response"
        var response = Data("HTTP/1.1 \(code) \(status)\r\n\(extra)Content-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        peer.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }
}

/// An ephemeral, size-limited RPC. The default URLSession server-trust handler
/// validates certificates and hostnames. Redirects never change the selected node.
private final class BoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 64 * 1024 * 1024
    private var session: URLSession?
    private var bytes = Data()
    private var status = 502
    private var completion: ((Int, Data) -> Void)?

    func start(configuration: URLSessionConfiguration, request: URLRequest, completion: @escaping (Int, Data) -> Void) {
        self.completion = completion
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }
    func cancel() { session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 502
        completionHandler(response.expectedContentLength > Self.limit ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= Self.limit else { dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion?(error == nil ? status : 502, error == nil ? bytes : Data())
        completion = nil
        session.finishTasksAndInvalidate()
    }
}
