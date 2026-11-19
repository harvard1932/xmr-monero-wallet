import Foundation

enum ProtectedSeed {
    static func source(words: String, passphrase: String, nativePolyseedOffset: Bool = false) throws -> WalletRestoreSource {
        guard !words.utf8.contains(0), !passphrase.utf8.contains(0) else { throw PINFailure("Invalid recovery input.") }
        guard words.split(separator: " ").count == 16 else {
            return passphrase.isEmpty ? .mnemonic(words) : .protectedMnemonic(words, passphrase: passphrase)
        }
        var output = [CChar](repeating: 0, count: 576)
        defer { _ = output.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        if nativePolyseedOffset && passphrase.isEmpty { throw PINFailure("Enter the original Monero seed offset.") }
        let status = XMRPreparePolyseed(words, nativePolyseedOffset ? "" : passphrase, &output, output.count)
        switch status {
        case 0:
            let clear = String(cString: output)
            if nativePolyseedOffset { return .polyseedWithMoneroOffset(clear, offset: passphrase) }
            return passphrase.isEmpty ? .mnemonic(clear) : .decryptedPolyseed(clear)
        case 1: throw PINFailure("This encrypted Polyseed requires its original passphrase.")
        case 2: throw PINFailure("This Polyseed is unencrypted. Leave its passphrase empty.")
        default: throw PINFailure("Check the Polyseed words, language and checksum.")
        }
    }
}
