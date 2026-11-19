import SwiftUI
import CryptoKit

/// A distinct native wallet per unlock prevents late work from affecting a different wallet.
@MainActor
final class WalletSession: ObservableObject {
    @Published private(set) var data: WalletPresentation?
    @Published private(set) var connection = ConnectionSettings()
    @Published private(set) var nodeName: String?
    @Published private(set) var height: UInt64 = 0
    @Published private(set) var chainHeight: UInt64 = 0
    @Published private(set) var problem: String?
    @Published private(set) var changingNode = false
    @Published var notice: String?

    @Published private(set) var lockScreenProgress: SyncAttributes.ContentState?
    @Published private(set) var probeProxy: String?
    @Published private(set) var torProgress: Int?
    @Published private(set) var needsNetworkChoice = true
    private var backgroundEngine: WalletEngine?
    private var scanTask: Task<Void, Never>?
    private var scanGrant: WalletScanGrant?

    private(set) var engine: WalletEngine?
    private var generation = UUID()
    private var pendingClose: Task<Void, Never>?
    private var wallet: VaultWallet?
    private struct WalletRoutePreference: Codable { var connection: ConnectionSettings? }
    private var connectionURL: URL?
    private let preferences: UserDefaults
    private var metadataURL: URL?
    private var metadataKey: SymmetricKey?
    private var invoices = [WalletInvoiceItem]()
    private var pending = [String: WalletTransfer]()
    private var lastProgress = Date()
    private var attempted = Set<URL>()
    private(set) var activeNode: URL?
    private var relay: NodeRelay?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    /// A new offline signer must never inherit another wallet’s online route.
    /// Existing v0.1 wallets keep their route on their first v0.2 unlock.
    private func loadConnection(in directory: URL, migratingLegacy: Bool) throws {
        let url = directory.appending(path: "network.json")
        let choice: ConnectionSettings?
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            choice = (try? JSONDecoder().decode(WalletRoutePreference.self, from: bytes))?.connection
        } else {
            let legacy = migratingLegacy ? preferences.data(forKey: "connection") : nil
            choice = legacy.flatMap { try? JSONDecoder().decode(ConnectionSettings.self, from: $0) }
            let bytes = try JSONEncoder().encode(WalletRoutePreference(connection: choice))
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        }
        connectionURL = url
        connection = choice ?? ConnectionSettings()
        needsNetworkChoice = choice == nil
    }

    private func begin(_ location: VaultLocation, migratingLegacy: Bool = false) async throws -> WalletEngine {
        takeOffline()
        let reservation = generation
        await pendingClose?.value
        guard reservation == generation else { throw CancellationError() }
        try Task.checkCancellation()
        let next = WalletEngine()
        try loadConnection(in: location.fileURL.deletingLastPathComponent(), migratingLegacy: migratingLegacy)
        wallet = location.wallet
        metadataURL = location.fileURL.deletingLastPathComponent().appending(path: "invoices.sealed")
        metadataKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(location.password.utf8)),
            salt: Data(location.wallet.id.uuidString.utf8), info: Data("invoice-metadata-v1".utf8), outputByteCount: 32)
        if let url = metadataURL, FileManager.default.fileExists(atPath: url.path), let key = metadataKey {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
            invoices = try JSONDecoder().decode([WalletInvoiceItem].self, from: AES.GCM.open(box, using: key))
        }
        engine = next
        return next
    }

    func create(_ location: VaultLocation) async throws -> String {
        let next = try await begin(location)
        let phrase = try await next.create(at: location.fileURL, password: location.password)
        await configureScanIfRequested(next, location: location)
        try check(next)
        return phrase
    }

    func restore(_ location: VaultLocation, _ request: VaultRestore) async throws {
        let next = try await begin(location)
        try await next.restore(at: location.fileURL, password: location.password, source: request.source, height: request.height)
        await configureScanIfRequested(next, location: location)
        try check(next)
    }

    func open(_ location: VaultLocation) async throws {
        let next = try await begin(location, migratingLegacy: true)
        try await next.open(at: location.fileURL, password: location.password)
        await configureScanIfRequested(next, location: location)
        try check(next)
    }

    private func configureScanIfRequested(_ core: WalletEngine, location: VaultLocation) async {
        guard preferences.bool(forKey: "syncActivity") else { return }
        do { try await core.configureRestrictedScan(password: location.password) }
        catch { if engine === core { notice = WalletL10n.diagnostic(error) } }
    }

    func primaryAddress() async throws -> String {
        let current = try liveEngine()
        let snapshot = try await current.snapshot()
        try check(current)
        guard let address = snapshot.addresses.first?.address, !address.isEmpty else {
            throw WalletEngineError("The restored wallet did not provide a primary address.")
        }
        return address
    }

    func readSeed() async throws -> String {
        let current = try liveEngine()
        let words = try await current.seed()
        try check(current)
        return words
    }

    func liveEngine() throws -> WalletEngine {
        guard let engine else { throw WalletEngineError("Unlock the wallet to continue.") }
        return engine
    }

    func check(_ expected: WalletEngine) throws {
        guard engine === expected, !Task.isCancelled else { throw CancellationError() }
    }

    /// Immediately revoke UI actions and release decoded wallet metadata.
    private func detachWallet() -> WalletEngine? {
        generation = UUID()
        let old = engine
        engine = nil
        wallet = nil
        data = nil
        metadataKey = nil
        metadataURL = nil
        connectionURL = nil
        invoices = []
        pending.removeAll()
        nodeName = nil
        activeNode = nil
        probeProxy = nil
        torProgress = nil
        height = 0
        chainHeight = 0
        problem = nil
        changingNode = false
        attempted.removeAll()
        return old
    }

    private func stopTransport() {
        relay?.stop()
        relay = nil
        EmbeddedTor.shared.stop()
    }

    private func enqueueClose(_ old: WalletEngine?) {
        guard let old else { return }
        let prior = pendingClose
        pendingClose = Task {
            await prior?.value
            do { try await old.close() }
            catch { self.notice = WalletL10n.text("Wallet files could not be saved. Unlock and check your wallet before continuing.") }
        }
    }

    func takeOffline() {
        finishBackgroundScan()
        lockScreenProgress = nil
        stopTransport()
        enqueueClose(detachWallet())
    }

    func lockForBackground(allowProgress: Bool) {
        guard allowProgress, backgroundEngine == nil,
              var state = lockScreenProgress, state.phase == .scanning,
              let core = detachWallet() else {
            if backgroundEngine == nil { takeOffline() }
            return
        }
        backgroundEngine = core
        let grant = WalletScanGrant()
        scanGrant = grant
        grant.begin { [weak self] in
            if self?.backgroundEngine === core { self?.finishBackgroundScan() }
        }
        guard grant.active else { finishBackgroundScan(); return }
        scanTask = Task {
            do {
                // Full wallets discard their spend key in native wallet2 before polling.
                // View-only wallets already lack this key.
                try await core.enterRestrictedScan()
                while backgroundEngine === core, !Task.isCancelled {
                    let scanned = try await core.scanHeight()
                    guard backgroundEngine === core else { return }
                    state.height = scanned
                    if scanned >= state.target { state.phase = .complete }
                    if state != lockScreenProgress {
                        lockScreenProgress = state
                        await SyncLiveActivity.publish(state, allowCreation: false)
                    }
                    if state.phase == .complete { break }
                    try await Task.sleep(for: .seconds(2))
                }
            } catch { /* A restricted scan may be unavailable after the device locks. */ }
            if backgroundEngine === core { finishBackgroundScan() }
        }
    }

    func finishBackgroundScan() {
        guard let core = backgroundEngine else { return }
        backgroundEngine = nil
        scanTask?.cancel()
        scanTask = nil
        if lockScreenProgress?.phase == .scanning { lockScreenProgress?.phase = .paused }
        stopTransport()
        enqueueClose(core)
        let grant = scanGrant
        scanGrant = nil
        let saving = pendingClose
        let final = lockScreenProgress
        Task {
            if lockScreenProgress == final {
                await SyncLiveActivity.publish(final, allowCreation: false)
            }
            await saving?.value
            grant?.end()
        }
    }

    func close() async {
        takeOffline()
        await pendingClose?.value
    }

    func run() async {
        guard let current = engine else { return }
        await refresh()
        guard engine === current, !Task.isCancelled else { return }
        await connect()
        while !Task.isCancelled, engine === current {
            await refresh()
            if connection.selection == .automatic, !changingNode,
               Self.shouldRetry(connected: data?.syncProgress != nil, synced: data?.synced == true,
                                elapsed: Date().timeIntervalSince(lastProgress)) {
                await connect(retrying: true)
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    nonisolated static func shouldRetry(connected: Bool, synced: Bool, elapsed: TimeInterval) -> Bool {
        if !connected { return elapsed >= 15 }
        return elapsed >= (synced ? 900 : 75)
    }

    func saveConnection(_ prefs: ConnectionSettings) throws {
        try prefs.validate()
        guard let url = connectionURL else { throw WalletEngineError("Unlock the wallet to continue.") }
        let bytes = try JSONEncoder().encode(WalletRoutePreference(connection: prefs))
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        connection = prefs
        needsNetworkChoice = false
    }

    /// Enabling a route from a never-connected wallet needs no file reopen.
    /// Other route changes close the previous native session before reconnecting.
    func chooseInitialConnection(_ prefs: ConnectionSettings) async throws {
        guard connection.selection == .offline, !changingNode else { throw WalletEngineError("Open network settings to change the active route.") }
        let current = try liveEngine()
        try saveConnection(prefs)
        await connect()
        try check(current)
        await refresh()
    }

    func retryConnection() async {
        await connect(retrying: true)
        await refresh()
    }

    func resetPreferences() {
        connection = ConnectionSettings()
        needsNetworkChoice = true
    }

    private func connect(retrying: Bool = false) async {
        guard let current = engine, !changingNode, connection.selection != .offline else { return }
        changingNode = true
        defer { if engine === current { changingNode = false } }
        do {
            let proxy: String?
            if connection.useProxy && !connection.usesExternalTor {
                torProgress = 0
                proxy = try await EmbeddedTor.shared.start { [weak self] percent in
                    if self?.engine === current { self?.torProgress = percent }
                }
            } else { proxy = connection.useProxy ? connection.proxy : nil }
            try check(current)
            probeProxy = proxy
            let candidates = try await connection.candidates(through: proxy)
            try check(current)
            var targets = candidates.filter { !retrying || !attempted.contains($0) }
            if targets.isEmpty && retrying { attempted.removeAll(); targets = candidates }
            if targets.isEmpty { lastProgress = Date(); throw WalletEngineError("No public node responded. Check your connection or choose your own node in Settings.") }
            var latest: Error?
            for node in targets {
                try check(current)
                attempted.insert(node)
                do {
                    relay?.stop()
                    relay = nil
                    if node.scheme == "https" {
                        let next = try NodeRelay(upstream: node, proxy: proxy)
                        relay = next
                        let local = try await next.start()
                        try check(current)
                        try await current.connect(node: local, username: next.username, password: next.password)
                    } else {
                        try await current.connect(node: node, proxy: proxy)
                    }
                    try check(current)
                    torProgress = nil
                    activeNode = node
                    nodeName = node.host
                    lastProgress = Date()
                    problem = nil
                    return
                } catch { latest = error }
            }
            throw latest ?? WalletEngineError("The node is unavailable.")
        } catch {
            guard engine === current else { return }
            torProgress = nil
            activeNode = nil
            nodeName = nil
            problem = WalletL10n.diagnostic(error)
            lastProgress = Date()
        }
    }

    func refresh() async {
        guard let current = engine, let wallet else { return }
        do {
            let snap = try await current.snapshot()
            let coins = try await current.outputs()
            let contacts = try await current.contacts()
            try check(current)
            if snap.height > height || (snap.synchronized && snap.targetHeight > chainHeight) { lastProgress = Date() }
            height = snap.height
            chainHeight = snap.targetHeight
            let status = changingNode ? "Connecting" : snap.connected ? (snap.synchronized ? "Synchronized" : "Synchronizing") : "Offline"
            let addresses = snap.addresses.map { WalletAddressItem(id: $0.id, label: $0.label, address: $0.address) }
            var receipts = [String: UInt64]()
            for address in snap.addresses { receipts[address.address] = address.received }
            var presentation = WalletPresentation(id: wallet.id.uuidString, name: wallet.name, network: "Mainnet")
            presentation.usesProxy = connection.useProxy
            presentation.networkEnabled = connection.selection != .offline
            presentation.scannedHeight = snap.height
            presentation.targetHeight = snap.targetHeight
            presentation.routeDescription = WalletL10n.text(connection.selection.title) + (connection.useProxy ? " · Tor" : "")
            presentation.nodeName = nodeName
            presentation.total = snap.balance
            presentation.available = snap.unlocked
            presentation.syncStatus = status
            presentation.synced = snap.connected && snap.synchronized
            presentation.syncProgress = snap.connected && snap.targetHeight > 0 ? min(1, Double(snap.height) / Double(snap.targetHeight)) : nil
            presentation.viewOnly = snap.watchOnly
            presentation.addresses = addresses
            let receivingAddresses = Dictionary(uniqueKeysWithValues: addresses.map { ($0.id, $0.address) })
            presentation.activity = snap.history.map { WalletActivityItem(transactionHash: $0.id, subaddresses: $0.subaddressIndices.sorted(), incoming: $0.incoming, amount: $0.amount,
                date: $0.date, confirmations: $0.confirmations, pending: $0.pending, failed: $0.failed, fee: $0.fee, note: $0.note,
                recipients: $0.incoming ? $0.subaddressIndices.compactMap { receivingAddresses[$0] } : $0.recipients) }.sorted { $0.date > $1.date }
            presentation.coins = coins.map { WalletCoinItem(id: $0.id, amount: $0.amount, frozen: $0.frozen, unlocked: $0.unlocked, label: $0.label, subaddressIndex: $0.subaddressIndex) }
            presentation.contacts = contacts.map { WalletContactItem(id: $0.id, name: $0.name, address: $0.address) }
            presentation.invoices = invoices.map { item in
                var updated = item
                updated.received = receipts[item.address] ?? 0
                return updated
            }
            data = presentation
            if snap.connected && snap.targetHeight > 0 {
                lockScreenProgress = .init(height: snap.height, target: snap.targetHeight, phase: snap.synchronized ? .complete : .scanning)
            } else { lockScreenProgress = nil }
        } catch {
            if engine === current && !Task.isCancelled { problem = WalletL10n.diagnostic(error) }
        }
    }

    func actions(vault: WalletVault, settings: @escaping () -> Void, wallets: @escaping () -> Void) -> WalletActions {
        let ticket = vault.sessionID
        let owner = engine
        func current() throws -> WalletEngine {
            try vault.requireCurrent(ticket)
            guard vault.phase == .unlocked, let owner else { throw CancellationError() }
            try check(owner)
            return owner
        }
        func remember(_ tx: WalletTransfer, core: WalletEngine) throws -> WalletSendReview {
            _ = try current()
            try self.check(core)
            self.pending = [tx.id.uuidString: tx]
            return WalletSendReview(id: tx.id.uuidString, address: tx.destination, amount: tx.amount, fee: tx.fee,
                                    sourceSubaddressCount: tx.sourceSubaddressCount)
        }
        func broadcast(_ id: String, note: String) async throws {
            let core = try current()
            do { try await vault.authorizeAction(reason: "Confirm and send payment") }
            catch { throw WalletPaymentAuthorizationError(underlying: error) }
            _ = try current()
            guard let tx = self.pending.removeValue(forKey: id) else { throw WalletEngineError("Review the payment again.") }
            let ids = try await core.commit(tx)
            guard (try? current()) != nil else { return }
            if !note.isEmpty {
                do {
                    let hashes = ids.split(separator: ",")
                    guard !hashes.isEmpty else { throw WalletEngineError("Could not save the transaction note.") }
                    for hash in hashes {
                        _ = try current()
                        try await core.setTransactionNote(note, for: String(hash))
                    }
                } catch {
                    if (try? current()) != nil { self.notice = WalletL10n.text("Payment submitted. Add the note again in Activity.") }
                }
            }
            if self.engine === core { await self.refresh() }
        }
        return WalletActions(settings: { if (try? current()) != nil { settings() } },
                             wallets: { if (try? current()) != nil { wallets() } }, refresh: {
            guard (try? current()) != nil else { return }
            if self.activeNode == nil { await self.connect() }
            await self.refresh()
        }, rescan: {
            do {
                let core = try current()
                try await core.rescan()
                try self.check(core)
                await self.refresh()
            } catch {
                if (try? current()) != nil { self.notice = WalletL10n.diagnostic(error) }
            }
        }, validateAddress: { address in
            guard let core = try? current() else { return false }
            return await core.validAddress(address)
        }, newAddress: { label in
            let core = try current()
            let item = try await core.addAddress(label: label)
            try self.check(core)
            await self.refresh()
            return WalletAddressItem(id: item.id, label: item.label, address: item.address)
        }, prepare: { address, amount, priority, inputs in
            let core = try current()
            let tx = try await core.prepare(destination: address, amount: amount, priority: priority, preferredInputs: inputs)
            return try remember(tx, core: core)
        }, prepareMax: { address, priority, inputs in
            let core = try current()
            let tx = try await core.prepareMax(destination: address, priority: priority, preferredInputs: inputs)
            return try remember(tx, core: core)
        }, preparePrivate: { address, amount, priority in
            let core = try current()
            let tx = try await core.preparePrivate(destination: address, amount: amount, priority: priority)
            return try remember(tx, core: core)
        }, submit: { id in
            try await broadcast(id, note: "")
        }, submitWithNote: { id, note in
            try await broadcast(id, note: note)
        }, discard: { id in
            if let core = try? current(), let tx = self.pending.removeValue(forKey: id) { await core.cancel(tx) }
        }, freeze: { key, value in
            let core = try current()
            try await core.setFrozen(value, output: key)
            await self.refresh()
        }, labelOutput: { key, label in
            let core = try current()
            try await core.setLabel(label, output: key)
            await self.refresh()
        }, saveTransactionNote: { hash, note in
            let core = try current()
            try await core.setTransactionNote(note, for: hash)
            try self.check(core)
            await self.refresh()
        }, saveContact: { item in
            let core = try current()
            try await core.addContact(name: item.name, address: item.address)
            await self.refresh()
        }, removeContact: { id in
            let core = try current()
            try await core.removeContact(id: id)
            await self.refresh()
        }, createInvoice: { label, amount in
            guard amount > 0 else { throw WalletEngineError("Enter a positive amount.") }
            let core = try current()
            let address = try await core.addAddress(label: label)
            try self.check(core)
            guard let key = self.metadataKey, let url = self.metadataURL else { throw CancellationError() }
            let invoice = WalletInvoiceItem(label: label, address: address.address, amount: amount)
            let records = [invoice] + self.invoices
            let bytes = try JSONEncoder().encode(records)
            guard let encrypted = try AES.GCM.seal(bytes, using: key).combined else { throw WalletEngineError("Could not protect the invoice.") }
            try encrypted.write(to: url, options: [.atomic, .completeFileProtection])
            self.invoices = records
            await self.refresh()
            return invoice
        }, cold: WalletColdActions(displayPairing: {
            let core = try current()
            guard let wallet = vault.active else { throw CancellationError() }
            _ = try await vault.authorizedLocation(for: wallet, reason: "Share the private view key with your view-only wallet.")
            try self.check(core)
            let pair = try await core.pairing()
            try self.check(core)
            return WalletViewPairing(address: pair.address, viewKey: pair.viewKey)
        }, exportOutputs: {
            try await current().exportOutputs()
        }, importOutputs: { frames in
            try await current().importOutputs(frames)
            await self.refresh()
        }, exportKeyImages: {
            try await current().exportKeyImages()
        }, importKeyImages: { frames, consent in
            guard self.connection.selection == .custom else { throw WalletEngineError("Choose your own node before sharing key images.") }
            try await current().importKeyImages(frames, trustNodeForThisImport: consent)
            await self.refresh()
        }, exportUnsigned: { id in
            let core = try current()
            guard let tx = self.pending.removeValue(forKey: id) else { throw WalletEngineError("Review the transfer again.") }
            return try await core.exportUnsigned(tx)
        }, inspectUnsigned: { frames in
            let review = try await current().inspectUnsigned(frames)
            return WalletOfflineReview(id: review.id, summary: review.summary)
        }, discardUnsigned: { id in
            if let core = try? current() { await core.discardUnsigned(id) }
        }, sign: { review in
            _ = try current()
            try await vault.authorizeAction(reason: "Sign this transaction")
            return try await current().sign(OfflineReview(id: review.id, summary: review.summary))
        }, submitSigned: { frames in
            _ = try current()
            try await vault.authorizeAction(reason: "Confirm and send payment")
            try await current().submitSigned(frames)
            await self.refresh()
        }))
    }
}


/// Holds the iOS execution grant through the native cache write. An expiration
/// handler can release its own grant immediately, even if the close is in flight.
@MainActor
private final class WalletScanGrant {
    private var id: UIBackgroundTaskIdentifier = .invalid
    var active: Bool { id != .invalid }

    func begin(onExpiration: @escaping @MainActor () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: "Finish wallet scan") { [weak self] in
            onExpiration()
            self?.end()
        }
    }

    func end() {
        guard active else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
