import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct PINFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { WalletL10n.text(message) }
}

struct BiometricEnrollment: Codable, Equatable {
    let id: UUID
    let domainState: Data?

    static func domainState(for context: LAContext) -> Data? {
        let hash: Data?
        if #available(iOS 18.0, *) {
            hash = context.domainState.biometry.stateHash
        } else {
            hash = context.evaluatedPolicyDomainState
        }
        return hash.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct PINEnvelope: Codable {
    let version: Int
    let salt: Data
    let wrappedKey: Data
    var failures: Int
    var retryAt: Date
    var biometrics: Bool
    var biometricEnrollment: BiometricEnrollment?
    static let rounds: UInt32 = 600_000

    static func validPIN(_ pin: String) -> Bool {
        (6...12).contains(pin.utf8.count) && pin.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func derive(_ pin: String, salt: Data) throws -> SymmetricKey {
        guard validPIN(pin), salt.count == 32 else { throw PINFailure("Enter a PIN with 6 to 12 digits.") }
        var result = Data(count: 32)
        let status = result.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                pin.withCString { pass in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, pin.utf8.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                         out.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw PINFailure("The iPhone could not protect the PIN.") }
        defer { result.resetBytes(in: 0..<result.count) }
        return SymmetricKey(data: result)
    }

    static func seal(key: SymmetricKey, pin: String) throws -> Self {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let wrapper = try derive(pin, salt: salt)
        let sealed = try key.withUnsafeBytes { try AES.GCM.seal(Data($0), using: wrapper,
            authenticating: Data("xmr-wallet-pin-envelope-v1".utf8)) }
        guard let combined = sealed.combined else { throw PINFailure("The iPhone could not protect the PIN.") }
        return .init(version: 1, salt: salt, wrappedKey: combined, failures: 0, retryAt: .distantPast,
                     biometrics: false)
    }

    func replacingPIN(_ pin: String, key: SymmetricKey) throws -> Self {
        var fresh = try Self.seal(key: key, pin: pin)
        fresh.biometrics = biometrics
        fresh.biometricEnrollment = biometricEnrollment
        return fresh
    }

    func open(pin: String) throws -> SymmetricKey {
        guard version == 1 else { throw PINFailure("This PIN format requires a newer app.") }
        let key = try Self.derive(pin, salt: salt)
        let box = try AES.GCM.SealedBox(combined: wrappedKey)
        var raw: Data
        do { raw = try AES.GCM.open(box, using: key, authenticating: Data("xmr-wallet-pin-envelope-v1".utf8)) }
        catch { throw PINFailure("Incorrect PIN.") }
        defer { raw.resetBytes(in: 0..<raw.count) }
        guard raw.count == 32 else { throw PINFailure("The wallet unlock key could not be read.") }
        return SymmetricKey(data: raw)
    }

    mutating func reserveAttempt(now: Date) throws {
        guard failures < 10 else { throw PINFailure("PIN attempts are locked. Reset your PIN with the iPhone passcode.") }
        guard now >= retryAt else { throw PINFailure("Too many PIN attempts. Wait a minute or reset your PIN with the iPhone passcode.") }
        failures += 1
        if failures >= 5 { retryAt = now.addingTimeInterval(60) }
    }
}

private enum PINItem { static let envelope = "envelope"; static let recovery = "recovery"; static let biometry = "biometry" }

private enum DevicePINItems {
    static var service: String { (Bundle.main.bundleIdentifier ?? "XMRMoneroWallet") + ".pin-v1" }
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    static func read(_ name: String, reason: String? = nil) throws -> Data? {
        let context = LAContext()
        defer { context.invalidate() }
        if let reason { context.localizedReason = WalletL10n.text(reason) }
        return try read(name, context: context)
    }

    static func read(_ name: String, context: LAContext) throws -> Data? {
        var q = query(name)
        q[kSecUseAuthenticationContext as String] = context
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw failure(status) }
        return data
    }

    static func add(_ name: String, data: Data, policy: SecAccessControlCreateFlags? = nil) throws {
        var q = query(name)
        if let policy {
            var err: Unmanaged<CFError>?
            guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, policy, &err) else {
                if let err { throw err.takeRetainedValue() as Error }
                throw PINFailure("A device passcode is required.")
            }
            q[kSecAttrAccessControl as String] = acl
        } else { q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
        q[kSecValueData as String] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    static func save(_ envelope: PINEnvelope, new: Bool = false) throws {
        let data = try JSONEncoder().encode(envelope)
        if new { try add(PINItem.envelope, data: data); return }
        let status = SecItemUpdate(query(PINItem.envelope) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw failure(status) }
    }

    static func remove(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    static func failure(_ status: OSStatus) -> Error {
        if status == errSecUserCanceled { return CancellationError() }
        if status == errSecInteractionNotAllowed { return PINFailure("Unlock the iPhone and try again.") }
        if status == errSecAuthFailed { return PINFailure("Device authentication failed. Try again with the iPhone unlocked.") }
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

actor WalletPINStore {
    static let shared = WalletPINStore()

    func state() throws -> PINEnvelope? {
        guard let bytes = try DevicePINItems.read(PINItem.envelope) else { return nil }
        let state = try JSONDecoder().decode(PINEnvelope.self, from: bytes)
        guard state.version == 1, state.salt.count == 32, state.wrappedKey.count == 60, (0...10).contains(state.failures) else {
            throw PINFailure("The saved PIN settings could not be read.")
        }
        return state
    }

    func unlock(pin: String) throws -> SymmetricKey {
        guard var envelope = try state() else { throw PINFailure("Set an app PIN first.") }
        guard PINEnvelope.validPIN(pin) else { throw PINFailure("Enter a PIN with 6 to 12 digits.") }
        // Save the charge first. Terminating the app during a guess cannot erase it.
        try envelope.reserveAttempt(now: Date())
        try DevicePINItems.save(envelope)
        let key = try envelope.open(pin: pin)
        envelope.failures = 0; envelope.retryAt = .distantPast
        try DevicePINItems.save(envelope)
        return key
    }

    func enroll(pin: String, existingCiphertexts: Bool) async throws -> SymmetricKey {
        guard try state() == nil else { throw PINFailure("Unlock with the existing app PIN.") }
        let availability = LAContext()
        var policyError: NSError?
        if !availability.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError),
           policyError?.code == LAError.passcodeNotSet.rawValue {
            throw PINFailure("Set a device passcode in iPhone Settings to protect this wallet.")
        }
        // A biometric availability failure cannot decide passcode enrollment.
        // The passcode-only Keychain ACL below is the actual enforced check.
        try Task.checkCancellation()
        // If first enrollment was interrupted after writing the recovery key, reuse
        // that same passcode-protected key so encrypted wallet material stays usable.
        let key: SymmetricKey
        if let data = try DevicePINItems.read(PINItem.recovery, reason: "Enter the iPhone passcode to finish PIN setup.") {
            guard data.count == 32 else { throw PINFailure("The wallet unlock key could not be read.") }
            key = SymmetricKey(data: data)
        } else {
            guard !existingCiphertexts else { throw PINFailure("This iPhone no longer holds the wallet unlock key. Verify your recovery backups, erase the local wallets, then restore them.") }
            key = SymmetricKey(size: .bits256)
            let generated = key.withUnsafeBytes { Data($0) }
            try DevicePINItems.add(PINItem.recovery, data: generated, policy: .devicePasscode)
            // Explicitly require the device passcode for enrollment. Biometry is
            // never requested on a new installation unless separately enabled.
            guard try DevicePINItems.read(PINItem.recovery, reason: "Enter the iPhone passcode to protect your app PIN.") == generated else {
                throw PINFailure("The reset key could not be verified.")
            }
        }
        try Task.checkCancellation()
        try DevicePINItems.save(PINEnvelope.seal(key: key, pin: pin), new: true)
        return key
    }

    private func evaluateBiometrics(_ context: LAContext, reason: String) async throws {
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                   localizedReason: WalletL10n.text(reason)) else {
                throw CancellationError()
            }
        } onCancel: { context.invalidate() }
        try Task.checkCancellation()
    }

    private func invalidateEnrollment(_ prior: PINEnvelope) throws -> Never {
        guard var current = try state(), current.salt == prior.salt, current.biometrics,
              current.biometricEnrollment == prior.biometricEnrollment else { throw CancellationError() }
        current.biometrics = false
        current.biometricEnrollment = nil
        try DevicePINItems.save(current)
        try DevicePINItems.remove(PINItem.biometry)
        throw PINFailure("Use your app PIN, then enable biometric unlock again.")
    }

    func unlockWithBiometrics() async throws -> SymmetricKey {
        guard let prior = try state(), prior.biometrics else { throw PINFailure("Biometric unlock is disabled.") }
        // An older opt-in has no recorded enrollment. Authorize a new one from PIN settings.
        guard let enrollment = prior.biometricEnrollment else { try invalidateEnrollment(prior) }
        let context = LAContext()
        defer { context.invalidate() }
        do {
            try await evaluateBiometrics(context, reason: "Unlock the wallet with Face ID or Touch ID.")
        } catch let error as LAError where error.code == .biometryNotEnrolled {
            try invalidateEnrollment(prior)
        }
        guard let current = try state(), current.salt == prior.salt, current.biometrics,
              current.biometricEnrollment == enrollment else { throw CancellationError() }
        guard BiometricEnrollment.domainState(for: context) == enrollment.domainState else {
            try invalidateEnrollment(prior)
        }
        // Use the same successful challenge for the protected Keychain item.
        // If the OS cannot honor it, fail instead of presenting a second prompt.
        context.interactionNotAllowed = true
        guard let bytes = try DevicePINItems.read(PINItem.biometry, context: context), bytes.count == 32 else {
            try invalidateEnrollment(prior)
        }
        try Task.checkCancellation()
        return SymmetricKey(data: bytes)
    }

    func setBiometrics(_ enabled: Bool, key: SymmetricKey) async throws {
        guard var envelope = try state() else { throw PINFailure("Set an app PIN first.") }
        if enabled {
            let ctx = LAContext()
            defer { ctx.invalidate() }
            try await evaluateBiometrics(ctx, reason: "Enable biometric unlock for this wallet.")
            guard let current = try state(), current.salt == envelope.salt, current.biometrics == envelope.biometrics,
                  current.biometricEnrollment == envelope.biometricEnrollment else { throw CancellationError() }
            envelope = current
            try DevicePINItems.remove(PINItem.biometry)
            try DevicePINItems.add(PINItem.biometry, data: key.withUnsafeBytes { Data($0) }, policy: .biometryCurrentSet)
            envelope.biometrics = true
            envelope.biometricEnrollment = BiometricEnrollment(id: UUID(), domainState: BiometricEnrollment.domainState(for: ctx))
            try DevicePINItems.save(envelope)
        } else {
            envelope.biometrics = false
            envelope.biometricEnrollment = nil
            try DevicePINItems.save(envelope)
            try DevicePINItems.remove(PINItem.biometry)
        }
    }

    func reset(pin: String) throws -> SymmetricKey {
        guard let envelope = try state(), let bytes = try DevicePINItems.read(PINItem.recovery,
            reason: "Enter the iPhone passcode to reset your wallet PIN."), bytes.count == 32 else {
            throw PINFailure("The reset key is unavailable. Restore your wallet from its recovery backup.")
        }
        try Task.checkCancellation()
        let key = SymmetricKey(data: bytes)
        try DevicePINItems.save(envelope.replacingPIN(pin, key: key))
        return key
    }

    func change(pin: String, key: SymmetricKey) throws {
        guard let envelope = try state() else { throw PINFailure("Set an app PIN first.") }
        try DevicePINItems.save(envelope.replacingPIN(pin, key: key))
    }

    func authorizeEmergencyErase() throws {
        // A distinct passcode-only challenge stays usable even when the wallet
        // envelopes went missing after the old device passcode was removed.
        let account = "emergency-erase-challenge"
        try DevicePINItems.remove(account)
        let challenge = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try DevicePINItems.add(account, data: challenge, policy: .devicePasscode)
        defer { try? DevicePINItems.remove(account) }
        guard try DevicePINItems.read(account, reason: "Enter the iPhone passcode to permanently erase all local wallet data.") == challenge else {
            throw PINFailure("Authentication was canceled.")
        }
    }

    func eraseAll() throws {
        for name in [PINItem.envelope, PINItem.biometry, PINItem.recovery, "emergency-erase-challenge"] { try DevicePINItems.remove(name) }
    }
}
