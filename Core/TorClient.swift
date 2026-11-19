import Darwin
import Foundation

enum EmbeddedTorError: LocalizedError {
    case configuration, control, unavailable, timeout

    var errorDescription: String? {
        switch self {
        case .configuration: return "The private Tor client could not start."
        case .control: return "The connection to the embedded Tor client closed."
        case .unavailable: return "Tor did not provide a local SOCKS listener."
        case .timeout: return "Tor could not build a circuit. Check your connection and try again."
        }
    }
}

struct TorBootstrapStatus {
    let progress: Int
    let established: Bool
    let endpoint: String?

    init(lines: [String]) {
        let phase = lines.first { $0.hasPrefix("status/bootstrap-phase=") } ?? ""
        let percent = phase.split(separator: " ").first { $0.hasPrefix("PROGRESS=") }
            .flatMap { Int($0.dropFirst("PROGRESS=".count)) }
        progress = min(100, max(0, percent ?? 0))
        established = lines.contains("status/circuit-established=1")
        let listeners = lines.first { $0.hasPrefix("net/listeners/socks=") }?
            .dropFirst("net/listeners/socks=".count).split(separator: " ") ?? []
        endpoint = listeners.lazy.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.first { item in
            let parts = item.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[0] == "127.0.0.1" && (UInt16(parts[1]) ?? 0) > 0
        }
    }
}

/// Owns the application half of an anonymous socketpair. Tor exits when this
/// descriptor closes. No network-accessible control port or credentials are used.
@MainActor
final class TorControlSession {
    private static let runQueue = DispatchQueue(label: "wallet.embedded-tor", qos: .utility)
    private var descriptor: Int32
    private var input = Data()
    private var busy = false
    private let finished = DispatchGroup()

    // Only the serial Tor thread accesses the config after setup. Tor's C API
    // forbids concurrent instances; this queue also serializes restarts.
    private struct NativeConfiguration: @unchecked Sendable {
        let handle: OpaquePointer

        func run(directory: URL) {
            let args = ["tor", "-f", directory.appendingPathComponent("wallet.torrc").path, "--quiet", "--ClientOnly", "1", "--AvoidDiskWrites", "1",
                        "--DataDirectory", directory.path, "--ControlPort", "0", "--SocksPort", "auto OnionTrafficOnly",
                        "--__DisableSignalHandlers", "1", "--CookieAuthentication", "0", "--SafeLogging", "1", "--DisableNetwork", "1"]
            var storage = args.map { strdup($0) } + [nil]
            defer {
                tor_main_configuration_free(handle)
                for ptr in storage { free(ptr) }
            }
            guard !storage.dropLast().contains(where: { $0 == nil }) else { return }
            storage.withUnsafeMutableBufferPointer { buffer in
                guard tor_main_configuration_set_command_line(handle, Int32(args.count), buffer.baseAddress) == 0 else { return }
                _ = tor_run_main(handle)
                XMRTorReleaseDispatchNames()
            }
        }
    }

    init(directory: URL) throws {
        XMRInitializeNetworking()
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        // Tor rejects non-regular config files. Supply a known empty, private torrc.
        try Data().write(to: directory.appendingPathComponent("wallet.torrc"), options: .atomic)
        var location = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        #if os(iOS)
        try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        guard let handle = tor_main_configuration_new() else { throw EmbeddedTorError.configuration }
        descriptor = tor_main_configuration_setup_control_socket(handle)
        guard descriptor >= 0 else {
            tor_main_configuration_free(handle)
            throw EmbeddedTorError.control
        }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            tor_main_configuration_free(handle)
            throw EmbeddedTorError.control
        }
        let configuration = NativeConfiguration(handle: handle)
        finished.enter()
        let finished = self.finished
        Self.runQueue.async {
            configuration.run(directory: directory)
            finished.leave()
        }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func stop() {
        guard descriptor >= 0 else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            finished.notify(queue: .main) { continuation.resume() }
        }
    }

    /// Only internal fixed commands are sent. The control stream is nonblocking
    /// so lock and cancellation can interrupt bootstrap at every suspension.
    func command(_ command: String, until deadline: ContinuousClock.Instant) async throws -> [String] {
        guard !busy, descriptor >= 0 else { throw EmbeddedTorError.control }
        busy = true
        defer { busy = false }
        let bytes = Array((command + "\r\n").utf8)
        var offset = 0
        var result = [String]()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard descriptor >= 0 else { throw CancellationError() }
            if offset < bytes.count {
                let count = bytes.withUnsafeBytes {
                    Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0)
                }
                if count > 0 { offset += count }
                else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { throw EmbeddedTorError.control }
            } else {
                let count = Darwin.recv(descriptor, &scratch, scratch.count, 0)
                if count == 0 { throw EmbeddedTorError.control }
                if count < 0, errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw EmbeddedTorError.control }
                if count > 0 {
                    input.append(contentsOf: scratch.prefix(count))
                    guard input.count <= 32_768 else { throw EmbeddedTorError.control }
                    while let newline = input.firstIndex(of: 10) {
                        let line = String(decoding: input[..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
                        input.removeSubrange(...newline)
                        guard line.hasPrefix("250-") || line.hasPrefix("250 ") else { throw EmbeddedTorError.control }
                        result.append(String(line.dropFirst(4)))
                        if line.hasPrefix("250 ") { return result }
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw EmbeddedTorError.timeout
    }
}

@MainActor
final class EmbeddedTor {
    static let shared = EmbeddedTor(directory: stateDirectory)
    static var stateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XMRNetwork/Tor", isDirectory: true)
    }
    private let directory: URL
    private var session: TorControlSession?
    private var stopping: TorControlSession?
    private var attempt: Task<String, Error>?
    private var erasure: Task<Void, Error>?
    private var generation = UUID()
    private var lastProgress = 0
    private var listeners = [UUID: (Int) -> Void]()

    init(directory: URL) { self.directory = directory }

    func start(progress: @escaping (Int) -> Void = { _ in }) async throws -> String {
        guard erasure == nil else { throw CancellationError() }
        let listener = UUID()
        listeners[listener] = progress
        defer { listeners.removeValue(forKey: listener) }
        progress(lastProgress)
        if let previous = stopping {
            let token = generation
            await previous.waitForExit()
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            stopping = nil
        }
        if attempt == nil {
            let newSession = session == nil
            let control = try session ?? TorControlSession(directory: directory)
            session = control
            let token = generation
            attempt = Task { @MainActor in
                let deadline = ContinuousClock.now.advanced(by: .seconds(120))
                do {
                    if newSession {
                        _ = try await control.command("AUTHENTICATE", until: deadline)
                        _ = try await control.command("SETCONF DisableNetwork=0", until: deadline)
                    }
                    while ContinuousClock.now < deadline {
                        let lines = try await control.command("GETINFO status/bootstrap-phase status/circuit-established net/listeners/socks", until: deadline)
                        let state = TorBootstrapStatus(lines: lines)
                        guard generation == token else { throw CancellationError() }
                        if lastProgress != state.progress {
                            lastProgress = state.progress
                            for callback in Array(listeners.values) { callback(state.progress) }
                        }
                        if state.established && state.progress == 100 {
                            guard let endpoint = state.endpoint else { throw EmbeddedTorError.unavailable }
                            self.attempt = nil
                            return endpoint
                        }
                        try await Task.sleep(for: .milliseconds(450))
                    }
                    throw EmbeddedTorError.timeout
                } catch {
                    if generation == token { stop() }
                    throw error
                }
            }
        }
        let token = generation
        guard let current = attempt else { throw EmbeddedTorError.control }
        return try await withTaskCancellationHandler {
            let endpoint = try await current.value
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            return endpoint
        } onCancel: {
            Task { @MainActor in if token == self.generation { self.stop() } }
        }
    }

    func stop() {
        generation = UUID()
        if let session {
            session.stop()
            stopping = session
        }
        session = nil
        attempt?.cancel()
        attempt = nil
        lastProgress = 0
    }

    /// Wait for Tor's final state writes before removing its guard information.
    func eraseState() async throws {
        if let erasure { return try await erasure.value }
        stop()
        let previous = stopping
        let deletion = Task { @MainActor in
            await previous?.waitForExit()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            stopping = nil
        }
        erasure = deletion
        defer { erasure = nil }
        try await deletion.value
    }
}
