import Foundation

/// Runs the production Swift actor and matching arm64 Darwin slice of the iOS engine release.
@main
struct ColdTransfer {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["REGTEST_WALLET_PASSWORD"], let port = env["REGTEST_PORT"],
              let rpcPassword = env["REGTEST_NODE_PASSWORD"], UInt16(port) != nil,
              let node = URL(string: "http://127.0.0.1:" + port) else {
            throw WalletEngineError("Missing disposable regtest session.")
        }
        let work = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let wallets = work.appendingPathComponent("wallets")
        let signer = WalletEngine(), viewer = WalletEngine()
        if CommandLine.arguments.last == "receipt" {
            try await viewer.open(at: wallets.appendingPathComponent("receiver"), password: password)
            let receipt = try await viewer.snapshot()
            guard receipt.balance == 1_250_000_000_000, receipt.unlocked == receipt.balance,
                  receipt.addresses.first?.received == receipt.balance,
                  receipt.history.contains(where: { $0.incoming && $0.amount == receipt.balance && $0.confirmations >= 10 }) else {
                throw WalletEngineError("The app's confirmed receipt differs from the test payment.")
            }
            try await viewer.close()
            return
        }
        try await signer.open(at: wallets.appendingPathComponent("sender"), password: password)
        let address = try String(contentsOf: work.appendingPathComponent("destination"), encoding: .utf8)
        let frames = try String(contentsOf: work.appendingPathComponent("unsigned.ur"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        let review = try await signer.inspectUnsigned(frames)
        guard review.summary.contains(address), review.summary.contains("1.250") else {
            throw WalletEngineError("The offline review did not show the expected recipient and amount.")
        }
        let signed = try await signer.sign(review)
        do {
            _ = try await signer.sign(review)
            throw WalletEngineError("A review was accepted twice.")
        } catch let error as WalletEngineError where error.message.contains("Review this transaction again") {
            // Expected single-use review.
        }
        try await signer.close()
        try await viewer.open(at: wallets.appendingPathComponent("viewer"), password: password)
        try await viewer.connect(node: node, username: "regtest", password: rpcPassword)
        try await viewer.submitSigned(signed)
        try await viewer.close()
        print("Verified offline review, signed the transaction, and submitted \(signed.count) UR frames.")
    }
}
