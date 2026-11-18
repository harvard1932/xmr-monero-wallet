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

    private(set) var engine: WalletEngine?
    private var generation = UUID()
    private var pendingClose: Task<Void, Never>?
    private var wallet: VaultWallet?
    private var metadataURL: URL?
    private var metadataKey: SymmetricKey?
    private var invoices = [WalletInvoiceItem]()
    private var pending = [String: WalletTransfer]()
    private var lastProgress = Date()
    private var attempted = Set<URL>()
    private var activeNode: URL?
    private var relay: NodeRelay?

    init() {
        if let saved = UserDefaults.standard.data(forKey: "connection"),
           let prefs = try? JSONDecoder().decode(ConnectionSettings.self, from: saved) { connection = prefs }
    }

    private func begin(_ location: VaultLocation) async throws -> WalletEngine {
        takeOffline()
        let reservation = generation
        await pendingClose?.value
        guard reservation == generation else { throw CancellationError() }
        try Task.checkCancellation()
        let next = WalletEngine()
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
        try check(next)
        return phrase
    }

    func restore(_ location: VaultLocation, _ request: VaultRestore) async throws {
        let next = try await begin(location)
        try await next.restore(at: location.fileURL, password: location.password, source: request.source, height: request.height)
        try check(next)
    }

    func open(_ location: VaultLocation) async throws {
        let next = try await begin(location)
        try await next.open(at: location.fileURL, password: location.password)
        try check(next)
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

    /// Synchronously drops the presentation and any authority to use the old session.
    func takeOffline() {
        generation = UUID()
        let old = engine
        engine = nil
        wallet = nil
        data = nil
        notice = nil
        metadataKey = nil
        metadataURL = nil
        invoices = []
        pending.removeAll()
        nodeName = nil
        activeNode = nil
        relay?.stop()
        relay = nil
        height = 0
        chainHeight = 0
        problem = nil
        changingNode = false
        attempted.removeAll()
        if let old {
            let prior = pendingClose
            pendingClose = Task {
                await prior?.value
                do { try await old.close() }
                catch { self.notice = "Wallet files could not be saved. Unlock and check your wallet before continuing." }
            }
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
               data?.synced != true, Date().timeIntervalSince(lastProgress) > 75 {
                await connect(retrying: true)
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func saveConnection(_ prefs: ConnectionSettings) throws {
        try prefs.validate()
        let bytes = try JSONEncoder().encode(prefs)
        UserDefaults.standard.set(bytes, forKey: "connection")
        connection = prefs
    }

    private func connect(retrying: Bool = false) async {
        guard let current = engine, !changingNode, connection.selection != .offline else { return }
        changingNode = true
        defer { if engine === current { changingNode = false } }
        do {
            let candidates = try await connection.candidates()
            try check(current)
            var targets = candidates.filter { !retrying || !attempted.contains($0) }
            if targets.isEmpty && retrying { attempted.removeAll(); targets = candidates }
            if targets.isEmpty { lastProgress = Date(); throw WalletEngineError("No public node responded. Check your connection or choose your own node in Settings.") }
            var latest: Error?
            for node in targets {
                try check(current)
                attempted.insert(node)
                do {
                    let proxy = connection.useProxy ? connection.proxy : nil
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
            problem = error.localizedDescription
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
            if snap.height != height { lastProgress = Date() }
            height = snap.height
            chainHeight = snap.targetHeight
            let status = changingNode ? "Connecting" : snap.connected ? (snap.synchronized ? "Synchronized" : "Synchronizing") : "Offline"
            let addresses = snap.addresses.map { WalletAddressItem(id: $0.id, label: $0.label, address: $0.address) }
            var receipts = [String: UInt64]()
            for address in snap.addresses { receipts[address.address] = address.received }
            var presentation = WalletPresentation(id: wallet.id.uuidString, name: wallet.name, network: "Mainnet")
            presentation.usesProxy = connection.useProxy
            presentation.networkEnabled = connection.selection != .offline
            presentation.total = snap.balance
            presentation.available = snap.unlocked
            presentation.syncStatus = status
            presentation.synced = snap.connected && snap.synchronized
            presentation.syncProgress = snap.connected && snap.targetHeight > 0 ? min(1, Double(snap.height) / Double(snap.targetHeight)) : nil
            presentation.viewOnly = snap.watchOnly
            presentation.addresses = addresses
            presentation.activity = snap.history.map { WalletActivityItem(transactionHash: $0.id, subaddresses: $0.subaddressIndices.sorted(), incoming: $0.incoming, amount: $0.amount,
                date: $0.date, confirmations: $0.confirmations, pending: $0.pending, failed: $0.failed, fee: $0.fee) }.sorted { $0.date > $1.date }
            presentation.coins = coins.map { WalletCoinItem(id: $0.id, amount: $0.amount, frozen: $0.frozen, unlocked: $0.unlocked, label: $0.label, subaddressIndex: $0.subaddressIndex) }
            presentation.contacts = contacts.map { WalletContactItem(id: $0.id, name: $0.name, address: $0.address) }
            presentation.invoices = invoices.map { item in
                var updated = item
                updated.received = receipts[item.address] ?? 0
                return updated
            }
            data = presentation
        } catch {
            if engine === current && !Task.isCancelled { problem = error.localizedDescription }
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
        return WalletActions(settings: { if (try? current()) != nil { settings() } },
                             wallets: { if (try? current()) != nil { wallets() } }, refresh: {
            guard (try? current()) != nil else { return }
            if self.activeNode == nil { await self.connect() }
            await self.refresh()
        }, newAddress: { label in
            let core = try current()
            let item = try await core.addAddress(label: label)
            try self.check(core)
            await self.refresh()
            return WalletAddressItem(id: item.id, label: item.label, address: item.address)
        }, prepare: { address, amount, priority, inputs in
            let core = try current()
            let tx = try await core.prepare(destination: address, amount: amount, priority: priority, preferredInputs: inputs)
            try self.check(core)
            self.pending[tx.id.uuidString] = tx
            return WalletSendReview(id: tx.id.uuidString, address: tx.destination, amount: tx.amount, fee: tx.fee)
        }, submit: { id in
            let core = try current()
            guard let tx = self.pending.removeValue(forKey: id) else { throw WalletEngineError("Review the payment again.") }
            _ = try await core.commit(tx)
            if self.engine === core { await self.refresh() }
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
        }, sign: { review in
            try await current().sign(OfflineReview(id: review.id, summary: review.summary))
        }, submitSigned: { frames in
            try await current().submitSigned(frames)
            await self.refresh()
        }))
    }
}
