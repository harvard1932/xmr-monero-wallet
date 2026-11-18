import Foundation
import JavaScriptCore

enum VaultSeedFormat: String, CaseIterable {
    case classic = "Monero / Polyseed"
    case myMonero = "MyMonero (13 English words)"
    case bip39 = "Exodus / Cake BIP39 (English)"
}

enum LegacySeedRecovery {
    /// Each import receives a fresh JavaScriptCore context with no network, file,
    /// or native callbacks. All executable code comes from the signed app bundle.
    static func source(format: VaultSeedFormat, phrase: String, passphrase: String) async throws -> WalletRestoreSource {
        if format == .classic { return .mnemonic(phrase) }
        try Task.checkCancellation()
        guard let url = Bundle.main.url(forResource: "legacy-recovery", withExtension: "js"),
              let context = JSContext() else {
            throw WalletEngineError("The legacy recovery module is missing from this build.")
        }
        context.isInspectable = false
        context.exceptionHandler = { ctx, exception in ctx?.exception = exception }
        defer {
            context.exception = nil
            context.exceptionHandler = nil
        }
        let script = try String(contentsOf: url, encoding: .utf8)
        context.evaluateScript(script)
        guard context.exception == nil, let adapter = context.objectForKeyedSubscript("LegacyRecovery"),
              !adapter.isUndefined else { throw WalletEngineError("The legacy recovery module could not start.") }
        switch format {
        case .classic: return .mnemonic(phrase)
        case .myMonero:
            guard let value = adapter.invokeMethod("myMonero", withArguments: [phrase]),
                  context.exception == nil, let fields = value.toDictionary() as? [String: String],
                  let address = fields["address"], let view = fields["view"], let spend = fields["spend"] else {
                throw WalletEngineError("Check the 13 English MyMonero words, including the checksum word.")
            }
            return .keys(address: address, view: view, spend: spend)
        case .bip39:
            guard let value = adapter.invokeMethod("exodus", withArguments: [phrase, passphrase]),
                  context.exception == nil, value.isString, let classic = value.toString(),
                  classic.split(separator: " ").count == 25 else {
                throw WalletEngineError("Check the English BIP39 phrase and its checksum.")
            }
            return .mnemonic(classic)
        }
    }
}
