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
        if let stage = CommandLine.arguments.last, ["hot-fixture", "hot-send"].contains(stage) {
            try await HotTransfer.run(stage: stage, work: work, node: node,
                                      rpcPassword: rpcPassword, walletPassword: password)
            return
        }
        let wallets = work.appendingPathComponent("wallets")
        let signer = WalletEngine(), viewer = WalletEngine()
        let recipient = wallets.appendingPathComponent("receiver")
        let offline = wallets.appendingPathComponent("offline-signer")
        let online = wallets.appendingPathComponent("viewer")
        switch CommandLine.arguments.last {
        case "invoice-address":
            try await viewer.open(at: recipient, password: password)
            let invoiceAddress = try await viewer.addAddress(label: "Invoice A")
            guard invoiceAddress.id == 1 else { throw WalletEngineError("Expected a fresh dedicated subaddress.") }
            try invoiceAddress.address.write(to: work.appendingPathComponent("destination"), atomically: true, encoding: .utf8)
            try await viewer.close()
            return
        case "pair-outputs":
            try await signer.open(at: offline, password: password)
            try await viewer.open(at: online, password: password)
            let pairing = try await signer.pairing()
            let target = try await viewer.snapshot()
            guard target.watchOnly, target.addresses.first?.address == pairing.address else {
                throw WalletEngineError("The view-only wallet did not match the offline signer.")
            }
            let outputs = try await viewer.exportOutputs()
            try await signer.importOutputs(outputs)
            let images = try await signer.exportKeyImages()
            try await viewer.connect(node: node, username: "regtest", password: rpcPassword)
            try await viewer.importKeyImages(images, trustNodeForThisImport: true)
            try await signer.close()
            try await viewer.close()
            print("Paired the wallets and exchanged \(outputs.count) output frames and \(images.count) signed key-image frames.")
            return
        case "receipt":
            try await viewer.open(at: recipient, password: password)
            let receipt = try await viewer.snapshot()
            guard receipt.balance == 1_250_000_000_000, receipt.unlocked == receipt.balance,
                  receipt.addresses.first?.received == 0,
                  receipt.addresses.contains(where: { $0.id == 1 && $0.received == receipt.balance && $0.label == "Invoice A" }),
                  receipt.history.contains(where: { $0.incoming && $0.amount == receipt.balance && $0.confirmations >= 10 }) else {
                throw WalletEngineError("The app's confirmed invoice receipt differs from the test payment.")
            }
            guard let coin = try await viewer.outputs().first(where: { $0.subaddressIndex == 1 && $0.unlocked }) else {
                throw WalletEngineError("The app did not find the invoice output.")
            }
            try await viewer.setLabel("Invoice A", output: coin.id)
            try await viewer.setFrozen(true, output: coin.id)
            try await viewer.close()
            try await viewer.open(at: recipient, password: password)
            guard try await viewer.outputs().contains(where: { $0.id == coin.id && $0.frozen && $0.label == "Invoice A" }) else {
                throw WalletEngineError("The frozen output or its label did not survive a wallet restart.")
            }
            try await viewer.setFrozen(false, output: coin.id)
            guard try await viewer.outputs().contains(where: { $0.id == coin.id && !$0.frozen }) else {
                throw WalletEngineError("The thawed output is still frozen.")
            }
            try await viewer.close()
            print("Verified the confirmed invoice subaddress receipt, output label, freeze, restart and thaw.")
            return
        case "sign": break
        default: throw WalletEngineError("Unknown regression test command.")
        }
        try await signer.open(at: offline, password: password)
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
