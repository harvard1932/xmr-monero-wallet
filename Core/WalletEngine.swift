import Foundation

/// All handles belong to this actor. wallet2's refresh thread is started only
/// after a user selects a node; it is stopped and joined before switching wallets.
actor WalletEngine {
    private typealias Handle = UnsafeMutableRawPointer
    private let network: Int32
    private var wallet: Handle?
    private var hasNode = false
    private var usedNetwork = false
    private var pending: (id: UUID, handle: Handle)?
    private var unsigned: (id: UUID, handle: Handle)?
    private let birthHeightKey = "xmrwallet.scan-start.v1"
    private let seedKindKey = "xmrwallet.seed-kind.v1"

    init(testnet: Bool = false) { network = testnet ? 1 : 0 }

    private func current() throws -> Handle {
        guard let wallet else { throw WalletEngineError("Unlock a wallet first.") }
        return wallet
    }

    private func manager() throws -> Handle {
        MONERO_WalletManagerFactory_setLogLevel(MONERO_LogLevel_Silent)
        guard let value = MONERO_WalletManagerFactory_getWalletManager() else {
            throw WalletEngineError("The Monero wallet engine could not start.")
        }
        return value
    }

    private func string(_ pointer: UnsafePointer<CChar>?, sensitive: Bool = false) -> String {
        guard let pointer else { return "" }
        defer {
            let buffer = UnsafeMutablePointer(mutating: pointer)
            if sensitive { _ = memset_s(buffer, strlen(pointer), 0, strlen(pointer)) }
            MONERO_free(buffer)
        }
        return String(cString: pointer)
    }

    private func failure(_ handle: Handle, _ fallback: String) -> WalletEngineError {
        let detail = string(MONERO_Wallet_errorString(handle))
        return WalletEngineError(detail.isEmpty ? fallback : detail)
    }

    private func adopt(_ candidate: Handle?, manager: Handle) throws {
        guard let candidate else { throw WalletEngineError("Could not open the wallet.") }
        guard MONERO_Wallet_status(candidate) == 0 else {
            let error = failure(candidate, "The wallet could not be opened.")
            _ = MONERO_WalletManager_closeWallet(manager, candidate, false)
            throw error
        }
        wallet = candidate
        if let history = MONERO_Wallet_history(candidate) { MONERO_TransactionHistory_refresh(history) }
    }

    private func save(_ handle: Handle) throws {
        guard MONERO_Wallet_store(handle, "") else { throw failure(handle, "Could not save the wallet.") }
    }

    @discardableResult
    func create(at url: URL, password: String) throws -> String {
        try close()
        let manager = try manager()
        try adopt(MONERO_WalletManager_createWallet(manager, url.path, password, "English", network), manager: manager)
        let wallet = try current()
        let dateHeight = MONERO_Wallet_approximateBlockChainHeight(wallet)
        // Keep a margin for clock drift and for blocks mined before first connection.
        try rememberScanStart(dateHeight > 21_600 ? dateHeight - 21_600 : 0, kind: "classic", wallet: wallet)
        return try seed()
    }

    func open(at url: URL, password: String) throws {
        try close()
        let manager = try manager()
        try adopt(MONERO_WalletManager_openWallet(manager, url.path, password, network), manager: manager)
    }

    func restore(at url: URL, password: String, source: WalletRestoreSource, height: UInt64) throws {
        try close()
        let manager = try manager()
        var candidate: Handle?
        var kind = "classic"
        switch source {
        case .mnemonic(let input):
            let words = input.split(whereSeparator: \.isWhitespace)
            let mnemonic = words.joined(separator: " ")
            guard !mnemonic.utf8.contains(0) else { throw WalletEngineError("Invalid recovery phrase.") }
            if words.count == 16 {
                kind = "polyseed"
                candidate = MONERO_WalletManager_createWalletFromPolyseed(manager, url.path, password, network, mnemonic, "", false, height, 1)
            } else {
                guard words.count == 25 else { throw WalletEngineError("Enter a 25-word Monero seed or 16-word Polyseed.") }
                candidate = MONERO_WalletManager_recoveryWallet(manager, url.path, password, mnemonic, network, height, 1, "")
            }
        case let .keys(address, view, spend):
            guard validAddress(address), validKey(view), spend.map(validKey) ?? true else {
                throw WalletEngineError("Check the Monero address and 64-character hexadecimal private keys.")
            }
            kind = "keys"
            candidate = MONERO_WalletManager_createWalletFromKeys(manager, url.path, password, "English", network, height, address, view, spend ?? "", 1)
        }
        try adopt(candidate, manager: manager)
        let wallet = try current()
        let nativeHeight = MONERO_Wallet_getRefreshFromBlockHeight(wallet)
        let start = kind == "polyseed" && height == 0 ? nativeHeight : height
        try rememberScanStart(start, kind: kind, wallet: wallet)
    }

    private func rememberScanStart(_ height: UInt64, kind: String, wallet: Handle) throws {
        guard MONERO_Wallet_setCacheAttribute(wallet, birthHeightKey, String(height)),
              MONERO_Wallet_setCacheAttribute(wallet, seedKindKey, kind) else {
            throw failure(wallet, "Could not record the wallet restore settings.")
        }
        MONERO_Wallet_setRefreshFromBlockHeight(wallet, height)
        try save(wallet)
    }

    func seed() throws -> String {
        let wallet = try current()
        let kind = string(MONERO_Wallet_getCacheAttribute(wallet, seedKindKey))
        guard !MONERO_Wallet_watchOnly(wallet), kind != "keys" else {
            throw WalletEngineError("This wallet was restored from keys. Keep the original key backup.")
        }
        let phrase = kind == "polyseed" ? string(MONERO_Wallet_getPolyseed(wallet, ""), sensitive: true)
            : string(MONERO_Wallet_seed(wallet, ""), sensitive: true)
        guard !phrase.isEmpty else { throw failure(wallet, "Could not read the recovery phrase.") }
        return phrase
    }

    func close() throws {
        guard let wallet else { return }
        let manager = try manager()
        discardTransactions(wallet)
        MONERO_Wallet_pauseRefresh(wallet)
        MONERO_Wallet_stop(wallet)
        hasNode = false
        if !MONERO_WalletManager_closeWallet(manager, wallet, true) {
            let error = failure(wallet, "Could not save the wallet before locking.")
            if MONERO_WalletManager_closeWallet(manager, wallet, false) { self.wallet = nil }
            throw error
        }
        self.wallet = nil
        usedNetwork = false
    }

    private func discardTransactions(_ wallet: Handle) {
        if let pending { XMRDisposePending(wallet, pending.handle) }
        if let unsigned { XMRDisposeUnsigned(unsigned.handle) }
        pending = nil
        unsigned = nil
    }

    func connect(node: URL, proxy: String? = nil, username: String = "", password: String = "") throws {
        let wallet = try current()
        guard let host = node.host, !host.isEmpty, let scheme = node.scheme?.lowercased(), ["http", "https"].contains(scheme),
              node.user == nil, node.password == nil, node.query == nil, node.fragment == nil,
              ["", "/"].contains(node.path) else { throw WalletEngineError("Use the HTTP or HTTPS base URL of a Monero node.") }
        guard !host.lowercased().hasSuffix(".onion") || !(proxy ?? "").isEmpty else {
            throw WalletEngineError("An onion node requires a SOCKS proxy.")
        }
        if let proxy {
            let pieces = proxy.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[0].isEmpty, !pieces[0].contains(where: \.isWhitespace),
                  let port = UInt16(pieces[1]), port > 0 else { throw WalletEngineError("Use host:port for the SOCKS proxy.") }
        }
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
        let onionName = host.lowercased().split(separator: ".")
        let onion = onionName.count == 2 && onionName[1] == "onion" && onionName[0].utf8.count == 56
            && onionName[0].utf8.allSatisfy { (97...122).contains($0) || (50...55).contains($0) }
        guard scheme == "http", (loopback && proxy == nil) || (onion && proxy != nil) else {
            throw WalletEngineError("The native engine requires a local secure transport or a Tor v3 onion node through a proxy.")
        }
        discardTransactions(wallet)
        usedNetwork = true
        hasNode = false
        MONERO_Wallet_pauseRefresh(wallet)
        let scanStart = UInt64(string(MONERO_Wallet_getCacheAttribute(wallet, birthHeightKey))) ?? 0
        guard MONERO_Wallet_init(wallet, node.absoluteString, 0, username, password, scheme == "https", false, proxy ?? "") else {
            throw failure(wallet, "Could not configure the node.")
        }
        MONERO_Wallet_setTrustedDaemon(wallet, false)
        MONERO_Wallet_setRefreshFromBlockHeight(wallet, scanStart)
        guard MONERO_Wallet_connectToDaemon(wallet),
              MONERO_Wallet_connected(wallet) == MONERO_WalletConnectionStatus_Connected else {
            throw failure(wallet, "The node could not be reached. Check the URL and proxy.")
        }
        hasNode = true
        MONERO_Wallet_startRefresh(wallet)
    }

    func validAddress(_ address: String) -> Bool {
        [95, 106].contains(address.utf8.count) && !address.utf8.contains(0) && MONERO_Wallet_addressValid(address, network)
    }

    private func validKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    func snapshot() throws -> WalletSnapshot {
        let wallet = try current()
        let history = payments(wallet)
        var received: [Int: UInt64] = [:]
        for payment in history where payment.incoming && !payment.pending && !payment.failed && payment.confirmations > 0 {
            if payment.subaddressIndices.count == 1, let index = payment.subaddressIndices.first {
                let total = received[index, default: 0].addingReportingOverflow(payment.amount)
                guard !total.overflow else { throw WalletEngineError("The total received by this address exceeds the supported amount.") }
                received[index] = total.partialValue
            }
        }
        let addresses = (0..<MONERO_Wallet_numSubaddresses(wallet, 0)).map { index in
            WalletAddress(id: index, address: string(MONERO_Wallet_address(wallet, 0, UInt64(index))),
                          label: string(MONERO_Wallet_getSubaddressLabel(wallet, 0, UInt32(index))), received: received[index] ?? 0)
        }
        let connected = hasNode && MONERO_Wallet_connected(wallet) == MONERO_WalletConnectionStatus_Connected
        let target = connected ? MONERO_Wallet_daemonBlockChainHeight(wallet) : 0
        let height = MONERO_Wallet_blockChainHeight(wallet)
        return WalletSnapshot(balance: MONERO_Wallet_balance(wallet, 0), unlocked: MONERO_Wallet_unlockedBalance(wallet, 0),
                              height: height, targetHeight: target, synchronized: connected && target > 0 && height >= target && MONERO_Wallet_synchronized(wallet),
                              connected: connected, watchOnly: MONERO_Wallet_watchOnly(wallet), addresses: addresses, history: history)
    }

    private func payments(_ wallet: Handle) -> [WalletPayment] {
        guard let history = MONERO_Wallet_history(wallet) else { return [] }
        // An empty history is initialized by the engine's refresh thread. Once
        // populated the API delegates subsequent refreshes to the caller.
        if !hasNode || MONERO_TransactionHistory_count(history) > 0 { MONERO_TransactionHistory_refresh(history) }
        return (0..<MONERO_TransactionHistory_count(history)).compactMap { index in
            guard let row = MONERO_TransactionHistory_transaction(history, index),
                  MONERO_TransactionInfo_subaddrAccount(row) == 0 else { return nil }
            let indices = string(MONERO_TransactionInfo_subaddrIndex(row, ",")).split(separator: ",").compactMap { Int($0) }
            return WalletPayment(id: string(MONERO_TransactionInfo_hash(row)), amount: MONERO_TransactionInfo_amount(row),
                                 fee: MONERO_TransactionInfo_fee(row), date: Date(timeIntervalSince1970: Double(MONERO_TransactionInfo_timestamp(row))),
                                 incoming: MONERO_TransactionInfo_direction(row) == MONERO_TransactionInfoDirection_In,
                                 confirmations: MONERO_TransactionInfo_confirmations(row), pending: MONERO_TransactionInfo_isPending(row),
                                 failed: MONERO_TransactionInfo_isFailed(row), subaddressIndices: indices)
        }.sorted { $0.date > $1.date }
    }

    func addAddress(label: String) throws -> WalletAddress {
        let wallet = try current()
        let index = MONERO_Wallet_numSubaddresses(wallet, 0)
        MONERO_Wallet_addSubaddress(wallet, 0, label)
        guard MONERO_Wallet_numSubaddresses(wallet, 0) == index + 1 else { throw failure(wallet, "Could not create a subaddress.") }
        try save(wallet)
        return WalletAddress(id: index, address: string(MONERO_Wallet_address(wallet, 0, UInt64(index))), label: label, received: 0)
    }

    func prepare(destination: String, amount: UInt64, priority: Int, preferredInputs: [String] = []) throws -> WalletTransfer {
        let wallet = try current()
        discardTransactions(wallet)
        guard validAddress(destination) else { throw WalletEngineError("The destination is not a valid Monero address on this network.") }
        guard amount > 0, (0...3).contains(priority) else { throw WalletEngineError("Enter a positive amount and a supported fee priority.") }
        guard hasNode, MONERO_Wallet_connected(wallet) == MONERO_WalletConnectionStatus_Connected, MONERO_Wallet_synchronized(wallet) else {
            throw WalletEngineError("Connect to a node and finish syncing before sending.")
        }
        let target = MONERO_Wallet_daemonBlockChainHeight(wallet)
        guard target > 0, MONERO_Wallet_blockChainHeight(wallet) >= target else { throw WalletEngineError("Wait until the wallet is synchronized.") }
        guard amount <= MONERO_Wallet_unlockedBalance(wallet, 0) else { throw WalletEngineError("The amount exceeds the available balance.") }
        let inputs = try selectedInputs(preferredInputs, wallet: wallet)
        let candidate: Handle?
        if inputs.images.isEmpty {
            candidate = MONERO_Wallet_createTransaction(wallet, destination, "", amount, 0, Int32(priority), 0, "", ",")
        } else {
            candidate = inputs.subaddresses.withUnsafeBufferPointer {
                XMRCreateSelectedTransaction(wallet, destination, amount, Int32(priority), $0.baseAddress, $0.count, inputs.images.joined(separator: ","))
            }
        }
        guard let tx = candidate else {
            throw failure(wallet, "Could not prepare the transaction.")
        }
        guard MONERO_PendingTransaction_status(tx) == 0, MONERO_PendingTransaction_amount(tx) == amount else {
            let detail = string(MONERO_PendingTransaction_errorString(tx))
            XMRDisposePending(wallet, tx)
            throw WalletEngineError(detail.isEmpty ? "The wallet could not prepare the requested amount." : detail)
        }
        let result = WalletTransfer(id: UUID(), destination: destination, amount: amount, fee: MONERO_PendingTransaction_fee(tx))
        pending = (result.id, tx)
        return result
    }

    func commit(_ transfer: WalletTransfer) throws -> String {
        let wallet = try current()
        guard !MONERO_Wallet_watchOnly(wallet) else { throw WalletEngineError("A view-only wallet requires an offline signature.") }
        guard let pending, pending.id == transfer.id else { throw WalletEngineError("Review a new transaction before sending.") }
        self.pending = nil
        defer { XMRDisposePending(wallet, pending.handle) }
        let ids = string(MONERO_PendingTransaction_txid(pending.handle, ","))
        guard MONERO_PendingTransaction_commit(pending.handle, "", false) else {
            let detail = string(MONERO_PendingTransaction_errorString(pending.handle))
            throw WalletEngineError("Broadcast was not confirmed. Check history before retrying. " + detail)
        }
        // Broadcasting is irreversible. A subsequent cache-write failure must
        // never be reported as a failed send that invites a duplicate payment.
        _ = MONERO_Wallet_store(wallet, "")
        return ids
    }

    func cancel(_ transfer: WalletTransfer) {
        if let wallet, let pending, pending.id == transfer.id {
            XMRDisposePending(wallet, pending.handle)
            self.pending = nil
        }
    }

    private func coinRows(_ wallet: Handle) -> [Handle] {
        guard let coins = MONERO_Wallet_coins(wallet) else { return [] }
        MONERO_Coins_refresh(coins)
        return (0..<MONERO_Coins_count(coins)).compactMap { MONERO_Coins_coin(coins, $0) }.filter {
            !MONERO_CoinsInfo_spent($0) && MONERO_CoinsInfo_subaddrAccount($0) == 0
        }
    }

    private func selectedInputs(_ publicKeys: [String], wallet: Handle) throws -> (images: [String], subaddresses: [UInt32]) {
        guard !publicKeys.isEmpty else { return ([], []) }
        let keys = Set(publicKeys)
        let result = coinRows(wallet).filter {
            keys.contains(string(MONERO_CoinsInfo_pubKey($0))) && MONERO_CoinsInfo_keyImageKnown($0)
                && MONERO_CoinsInfo_unlocked($0) && !MONERO_CoinsInfo_frozen($0)
        }
        guard result.count == keys.count else { throw WalletEngineError("A selected output is no longer spendable.") }
        return (result.map { string(MONERO_CoinsInfo_keyImage($0)) }, Array(Set(result.map { MONERO_CoinsInfo_subaddrIndex($0) })))
    }

    func outputs() throws -> [WalletOutput] {
        let wallet = try current()
        return coinRows(wallet).map { coin in
            let key = string(MONERO_CoinsInfo_pubKey(coin))
            return WalletOutput(id: key, amount: MONERO_CoinsInfo_amount(coin),
                                label: string(MONERO_Wallet_getCacheAttribute(wallet, "output-label." + key)),
                                frozen: MONERO_CoinsInfo_frozen(coin), unlocked: MONERO_CoinsInfo_unlocked(coin),
                                subaddressIndex: Int(MONERO_CoinsInfo_subaddrIndex(coin)))
        }
    }

    func setFrozen(_ frozen: Bool, output: String) throws {
        let wallet = try current()
        guard let coins = MONERO_Wallet_coins(wallet), try outputs().contains(where: { $0.id == output }) else {
            throw WalletEngineError("That wallet output is unavailable.")
        }
        discardTransactions(wallet)
        if frozen { MONERO_Coins_setFrozenByPublicKey(coins, output) }
        else { MONERO_Coins_thawByPublicKey(coins, output) }
        guard try outputs().contains(where: { $0.id == output && $0.frozen == frozen }) else {
            throw WalletEngineError("Could not update the output.")
        }
        try save(wallet)
    }

    func setLabel(_ label: String, output: String) throws {
        let wallet = try current()
        guard try outputs().contains(where: { $0.id == output }), !label.utf8.contains(0),
              MONERO_Wallet_setCacheAttribute(wallet, "output-label." + output, label) else {
            throw WalletEngineError("Could not label the wallet output.")
        }
        try save(wallet)
    }

    func contacts() throws -> [WalletContact] {
        let wallet = try current()
        guard let book = MONERO_Wallet_addressBook(wallet) else { throw failure(wallet, "Could not read contacts.") }
        MONERO_AddressBook_refresh(book)
        return (0..<MONERO_AddressBook_getAll_size(book)).compactMap { index in
            guard let row = MONERO_AddressBook_getAll_byIndex(book, index) else { return nil }
            return WalletContact(id: MONERO_AddressBookRow_getRowId(row), name: string(MONERO_AddressBookRow_getDescription(row)),
                                 address: string(MONERO_AddressBookRow_getAddress(row)))
        }
    }

    func addContact(name: String, address: String) throws {
        let wallet = try current()
        guard validAddress(address), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.utf8.contains(0) else {
            throw WalletEngineError("Enter a name and a valid Monero address.")
        }
        guard let book = MONERO_Wallet_addressBook(wallet), MONERO_AddressBook_addRow(book, address, "", name) else {
            throw failure(wallet, "Could not save the contact.")
        }
        try save(wallet)
    }

    func removeContact(id: Int) throws {
        let wallet = try current()
        guard id >= 0, try contacts().contains(where: { $0.id == id }),
              let book = MONERO_Wallet_addressBook(wallet), MONERO_AddressBook_deleteRow(book, id) else {
            throw WalletEngineError("Could not remove the contact.")
        }
        try save(wallet)
    }

    /// wallet2 uses newline-delimited Uniform Resources (UR) for air-gapped transfers.
    private func importPayload(_ frames: [String], type: String) throws -> String {
        guard !frames.isEmpty, frames.count <= 10_000 else { throw WalletEngineError("Invalid number of QR frames.") }
        var size = 0
        var parts = [String]()
        for item in frames {
            let frame = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            size += frame.utf8.count
            guard size <= 4 * 1024 * 1024, frame.utf8.count <= 4096, frame.hasPrefix("ur:" + type + "/"),
                  frame.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 47, 58].contains($0) }) else {
                throw WalletEngineError("Invalid or oversized " + type + " payload.")
            }
            parts.append(frame)
        }
        return parts.joined(separator: "\n")
    }

    private func exportFrames(_ data: String, type: String, wallet: Handle) throws -> [String] {
        let frames = data.split(whereSeparator: \.isNewline).map(String.init)
        guard !frames.isEmpty else { throw failure(wallet, "No QR data was produced.") }
        _ = try importPayload(frames, type: type)
        return frames
    }

    private func offlineSigner() throws -> Handle {
        let wallet = try current()
        guard !usedNetwork, !MONERO_Wallet_watchOnly(wallet) else {
            throw WalletEngineError("Use an unlocked spending wallet in offline mode on the signing device.")
        }
        return wallet
    }

    private func onlineViewer() throws -> Handle {
        let wallet = try current()
        guard MONERO_Wallet_watchOnly(wallet) else { throw WalletEngineError("Use a view-only wallet on the networked device.") }
        return wallet
    }

    func pairing() throws -> (address: String, viewKey: String) {
        let wallet = try offlineSigner()
        return (string(MONERO_Wallet_address(wallet, 0, 0)), string(MONERO_Wallet_secretViewKey(wallet), sensitive: true))
    }

    func exportOutputs() throws -> [String] {
        let wallet = try onlineViewer()
        return try exportFrames(string(MONERO_Wallet_exportOutputsUR(wallet, 160, true)), type: "xmr-output", wallet: wallet)
    }

    func importOutputs(_ frames: [String]) throws {
        let wallet = try offlineSigner()
        let payload = try importPayload(frames, type: "xmr-output")
        guard MONERO_Wallet_importOutputsUR(wallet, payload) else { throw failure(wallet, "Could not import the wallet outputs.") }
        try save(wallet)
    }

    func exportKeyImages() throws -> [String] {
        let wallet = try offlineSigner()
        return try exportFrames(string(MONERO_Wallet_exportKeyImagesUR(wallet, 160, true)), type: "xmr-keyimage", wallet: wallet)
    }

    func importKeyImages(_ frames: [String], trustNodeForThisImport: Bool) throws {
        let wallet = try onlineViewer()
        guard trustNodeForThisImport, hasNode else { throw WalletEngineError("Import requires permission to check spent key images with your node.") }
        let payload = try importPayload(frames, type: "xmr-keyimage")
        MONERO_Wallet_setTrustedDaemon(wallet, true)
        defer { MONERO_Wallet_setTrustedDaemon(wallet, false) }
        guard MONERO_Wallet_importKeyImagesUR(wallet, payload) else { throw failure(wallet, "Could not import the signed key images.") }
        try save(wallet)
    }

    func exportUnsigned(_ transfer: WalletTransfer) throws -> [String] {
        let wallet = try onlineViewer()
        guard let pending, pending.id == transfer.id else { throw WalletEngineError("Review a new unsigned payment first.") }
        defer { self.pending = nil; XMRDisposePending(wallet, pending.handle) }
        return try exportFrames(string(MONERO_PendingTransaction_commitUR(pending.handle, 160)), type: "xmr-txunsigned", wallet: wallet)
    }

    func inspectUnsigned(_ frames: [String]) throws -> OfflineReview {
        let wallet = try offlineSigner()
        discardTransactions(wallet)
        let payload = try importPayload(frames, type: "xmr-txunsigned")
        guard let tx = XMRReadUnsigned(wallet, payload) else { throw WalletEngineError("Invalid unsigned transaction data.") }
        let summary = string(MONERO_UnsignedTransaction_confirmationMessage(tx))
        guard MONERO_UnsignedTransaction_status(tx) == 0, MONERO_UnsignedTransaction_txCount(tx) > 0, !summary.isEmpty else {
            let detail = string(MONERO_UnsignedTransaction_errorString(tx))
            XMRDisposeUnsigned(tx)
            throw WalletEngineError(detail.isEmpty ? "Could not inspect this unsigned transaction." : detail)
        }
        let review = OfflineReview(id: UUID(), summary: summary)
        unsigned = (review.id, tx)
        return review
    }

    func sign(_ review: OfflineReview) throws -> [String] {
        let wallet = try offlineSigner()
        guard let unsigned, unsigned.id == review.id else { throw WalletEngineError("Review this transaction again before signing.") }
        self.unsigned = nil
        defer { XMRDisposeUnsigned(unsigned.handle) }
        let frames = try exportFrames(string(MONERO_UnsignedTransaction_signUR(unsigned.handle, 160)), type: "xmr-txsigned", wallet: wallet)
        try save(wallet)
        return frames
    }

    func submitSigned(_ frames: [String]) throws {
        let wallet = try onlineViewer()
        guard hasNode else { throw WalletEngineError("Connect the view-only wallet to a node to broadcast.") }
        let payload = try importPayload(frames, type: "xmr-txsigned")
        guard XMRSubmitSigned(wallet, payload) else { throw failure(wallet, "Broadcast was not confirmed. Check history before retrying.") }
        _ = MONERO_Wallet_store(wallet, "")
    }
}
