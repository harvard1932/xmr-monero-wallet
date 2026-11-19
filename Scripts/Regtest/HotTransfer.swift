import Foundation

enum HotTransfer {
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
                let destination = try String(contentsOf: work.appendingPathComponent("destination"), encoding: .utf8)
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
