import Foundation

enum HotTransfer {
    private enum FixtureError: Error { case unexpectedRescan }
    static func run(stage: String, work: URL, node: URL, rpcPassword: String, walletPassword: String) async throws {
        let wallet = WalletEngine(testnet: true)
        let wallets = work.appendingPathComponent("wallets")
        let hot = wallets.appendingPathComponent("hot")
        do {
            if stage == "hot-fixture" {
                // A real wallet's current birthday is beyond the height of a new
                // private chain. Restore the disposable seed from block zero.
                let phrase = try await wallet.create(at: wallets.appendingPathComponent("seed-source"), password: walletPassword)
                try await wallet.restore(at: hot, password: walletPassword, source: .mnemonic(phrase), height: 0)
                let state = try await wallet.snapshot()
                guard let primary = state.addresses.first?.address else { throw WalletEngineError("Missing primary test address.") }
                let source = try await wallet.addAddress(label: "Private testnet source")
                guard source.id == 1, source.address != primary else { throw WalletEngineError("Missing test subaddress.") }
                let fixture = try JSONEncoder().encode(["primary": primary, "subaddress": source.address])
                try fixture.write(to: work.appendingPathComponent("funding-addresses.json"), options: .atomic)
            } else {
                try await wallet.open(at: hot, password: walletPassword)
                try await wallet.connect(node: node, username: "regtest", password: rpcPassword)
                let deadline = Date().addingTimeInterval(90)
                var state = try await wallet.snapshot()
                while (!state.synchronized || state.addresses.first(where: { $0.id == 1 })?.received != 2_000_000_000_000) && Date() < deadline {
                    try await Task.sleep(for: .seconds(1))
                    state = try await wallet.snapshot()
                }
                guard state.connected, state.synchronized, state.height == state.targetHeight, state.unlocked == 5_000_000_000_000,
                      state.addresses.first(where: { $0.id == 0 })?.received == 3_000_000_000_000,
                      state.addresses.first(where: { $0.id == 1 })?.received == 2_000_000_000_000 else {
                    throw WalletEngineError("The production wallet did not synchronize both funded addresses.")
                }
                let coins = try await wallet.outputs().filter { $0.subaddressIndex == 1 && $0.unlocked && !$0.frozen }
                guard !coins.isEmpty else { throw WalletEngineError("No spendable output from the selected subaddress.") }
                let first = coins[0]
                try await wallet.setFrozen(true, output: first.id)
                do {
                    try await wallet.rescan()
                    throw FixtureError.unexpectedRescan
                } catch is WalletEngineError {}
                try await wallet.setFrozen(false, output: first.id)
                try await wallet.rescan()
                // Wait for the native rescan, then verify both independent funding amounts.
                try await Task.sleep(for: .seconds(2))
                var rescanned = try await wallet.snapshot()
                while (!rescanned.synchronized || rescanned.unlocked != state.unlocked) && Date() < deadline {
                    try await Task.sleep(for: .seconds(1))
                    rescanned = try await wallet.snapshot()
                }
                guard rescanned.unlocked == state.unlocked, rescanned.addresses.map(\.received) == state.addresses.map(\.received) else {
                    throw WalletEngineError("The rescan did not recover the original funding amounts.")
                }
                let destination = try String(contentsOf: work.appendingPathComponent("destination"), encoding: .utf8)
                let maximum = try await wallet.prepareMax(destination: destination, priority: 1)
                guard maximum.amount > 0, maximum.fee > 0, maximum.amount + maximum.fee == state.unlocked,
                      maximum.sourceSubaddressCount == 2 else { throw WalletEngineError("Full sweep skipped funded outputs or misreported its fee.") }
                await wallet.cancel(maximum)
                let selectedMax = try await wallet.prepareMax(destination: destination, priority: 1, preferredInputs: coins.map(\.id))
                guard selectedMax.amount > 0, selectedMax.fee > 0, selectedMax.amount + selectedMax.fee == 2_000_000_000_000,
                      selectedMax.sourceSubaddressCount == 1 else { throw WalletEngineError("Selected sweep included funds outside its source.") }
                await wallet.cancel(selectedMax)
                let isolated = try await wallet.preparePrivate(destination: destination, amount: 1_999_999_999_999, priority: 1)
                guard isolated.sourceSubaddressCount == 1 else { throw WalletEngineError("The payment could have used one source.") }
                await wallet.cancel(isolated)
                let pooled = try await wallet.preparePrivate(destination: destination, amount: 3_500_000_000_000, priority: 1)
                guard pooled.sourceSubaddressCount == 2 else { throw WalletEngineError("The fallback did not report both funding addresses.") }
                await wallet.cancel(pooled)
                print("Prepared full and manually selected sweeps net of fee; verified single-address and pooled payment construction.")
                let payment = try await wallet.prepare(destination: destination, amount: 250_000_000_000,
                                                       priority: 1, preferredInputs: coins.map(\.id))
                guard payment.fee > 0 else { throw WalletEngineError("Expected a nonzero private-testnet fee.") }
                let txid = try await wallet.commit(payment)
                try txid.write(to: work.appendingPathComponent("hot-txid"), atomically: true, encoding: .utf8)
                print("Hot send synchronized at height \(state.height), selected subaddress 1 and committed 250000000000 atomic units with a \(payment.fee)-unit fee.")
            }
            try await wallet.close()
        } catch {
            try? await wallet.close()
            throw error
        }
    }
}
