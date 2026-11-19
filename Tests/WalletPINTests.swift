import CryptoKit
import XCTest
@testable import XMRMoneroWallet

final class WalletPINTests: XCTestCase {
    func testBiometricBindingSurvivesPINRotationAndLegacyRecordsRemainPINReadable() throws {
        let key = SymmetricKey(size: .bits256)
        var envelope = try PINEnvelope.seal(key: key, pin: "651947")
        envelope.biometrics = true
        // Previous records had this opt-in flag but no recorded Apple enrollment.
        let legacy = try JSONDecoder().decode(PINEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertNil(legacy.biometricEnrollment)
        XCTAssertEqual(try legacy.open(pin: "651947"), key)
        envelope.biometricEnrollment = BiometricEnrollment(id: UUID(), domainState: Data([1, 3, 5]))
        let rotated = try envelope.replacingPIN("894612", key: key)
        let restored = try JSONDecoder().decode(PINEnvelope.self, from: JSONEncoder().encode(rotated))
        XCTAssertTrue(restored.biometrics)
        XCTAssertEqual(restored.biometricEnrollment, envelope.biometricEnrollment)
        XCTAssertEqual(try restored.open(pin: "894612"), key)
    }

    func testPINEnvelopeAuthenticatesAndRejectsAlteration() throws {
        let secret = SymmetricKey(size: .bits256)
        let envelope = try PINEnvelope.seal(key: secret, pin: "672591")
        XCTAssertEqual(try envelope.open(pin: "672591"), secret)
        XCTAssertThrowsError(try envelope.open(pin: "672592"))
        var changed = envelope.wrappedKey
        changed[changed.startIndex] ^= 1
        let tampered = PINEnvelope(version: 1, salt: envelope.salt, wrappedKey: changed,
                                   failures: 0, retryAt: .distantPast, biometrics: false)
        XCTAssertThrowsError(try tampered.open(pin: "672591"))
        XCTAssertFalse(PINEnvelope.validPIN("12345"))
        XCTAssertFalse(PINEnvelope.validPIN("12１２34"))
    }

    func testThrottlePersistsAcrossRestartAndCapsAttempts() throws {
        let now = Date()
        var envelope = PINEnvelope(version: 1, salt: Data(), wrappedKey: Data(), failures: 0, retryAt: .distantPast, biometrics: false)
        for _ in 0..<5 { try envelope.reserveAttempt(now: now) }
        var restored = try JSONDecoder().decode(PINEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertThrowsError(try restored.reserveAttempt(now: now.addingTimeInterval(59)))
        for step in 1...5 { try restored.reserveAttempt(now: now.addingTimeInterval(TimeInterval(step*61))) }
        XCTAssertThrowsError(try restored.reserveAttempt(now: .distantFuture))
    }

    func testWalletSealsBindCredentialAndBackupToWalletAndPurpose() throws {
        let first = UUID(), second = UUID()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = directory.appending(path: "credential.sealed")
        let backup = directory.appending(path: "original-backup.sealed")
        let key = SymmetricKey(size: .bits256)
        let example = Data("dummy migration fixture".utf8)
        try WalletSealedFile.write(example, to: credential, walletID: first, key: key)
        XCTAssertEqual(try WalletSealedFile.read(credential, walletID: first, key: key), example)
        XCTAssertThrowsError(try WalletSealedFile.read(credential, walletID: second, key: key))
        try FileManager.default.copyItem(at: credential, to: backup)
        XCTAssertThrowsError(try WalletSealedFile.read(backup, walletID: first, key: key))
    }

    @MainActor
    func testMigrationRetriesAfterCleanupFailureWithoutLosingWalletPassword() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "credential.sealed"), id = UUID()
        let key = SymmetricKey(size: .bits256)
        let password = UUID().uuidString
        do {
            _ = try await WalletCredentialMigration.open(at: file, walletID: id, key: key,
                legacy: { password }, checkSession: {}, retireLegacy: { throw CancellationError() })
            XCTFail("Retirement failure must reach the caller.")
        } catch is CancellationError {}
        var retired = false
        let recovered = try await WalletCredentialMigration.open(at: file, walletID: id, key: key,
            legacy: { XCTFail("The sealed copy is already committed."); throw CancellationError() },
            checkSession: {}, retireLegacy: { retired = true })
        XCTAssertEqual(recovered, password)
        XCTAssertTrue(retired)
    }

    func testPolyseedEncryptedFormatAndNativeOffsetAreDistinct() async throws {
        // v3.0.2 upstream g_phrase_en1, encrypted by libpolyseed's polyseed_crypt
        // with the public test passphrase below. No wallet funds or secrets are used.
        let clear = "raven tail swear infant grief assist regular lamp duck valid someone little harsh puppy airport language"
        let encrypted = "open sniff erode tenant pave resource battle wisdom drastic novel invite ski cactus craft cash father"
        let recovered = try ProtectedSeed.source(words: encrypted, passphrase: "public test password")
        guard case .decryptedPolyseed(let decoded) = recovered else {
            return XCTFail("Expected canonical plaintext Polyseed.")
        }
        XCTAssertEqual(decoded, clear)
        XCTAssertThrowsError(try ProtectedSeed.source(words: encrypted, passphrase: ""))
        XCTAssertThrowsError(try ProtectedSeed.source(words: clear, passphrase: "public test password"))
        XCTAssertThrowsError(try ProtectedSeed.source(words: encrypted, passphrase: "pass", nativePolyseedOffset: true))
        guard case let .polyseedWithMoneroOffset(words, offset) = try ProtectedSeed.source(words: clear, passphrase: "pass", nativePolyseedOffset: true) else {
            return XCTFail("Expected explicit Monero offset.")
        }
        XCTAssertEqual(words, clear)
        XCTAssertEqual(offset, "pass")

        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = WalletEngine(testnet: true)
        let password = UUID().uuidString
        do {
            try await engine.restore(at: directory.appending(path: "plain"), password: password, source: .mnemonic(clear), height: 0)
            let plain = try await engine.snapshot()
            let expected = try XCTUnwrap(plain.addresses.first?.address)
            try await engine.restore(at: directory.appending(path: "encrypted"), password: password, source: recovered, height: 0)
            let protected = try await engine.snapshot()
            XCTAssertEqual(protected.addresses.first?.address, expected)
            do {
                _ = try await engine.seed()
                XCTFail("An encrypted restore should direct the user to the original backup.")
            } catch is WalletEngineError {}
            try await engine.close()
        } catch {
            try? await engine.close()
            throw error
        }
    }

    @MainActor
    func testIncompleteEraseResumesAllCleanupBeforeDroppingJournal() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appending(path: "unregistered-draft")
        try Data("disposable".utf8).write(to: fixture)
        let first = WalletEraseJournal(root: root)
        try first.begin()
        var credentials = 0, network = 0, preferences = 0
        do {
            try await first.finish(retireCredentials: { credentials += 1 }, eraseNetworkState: {
                network += 1; throw CancellationError()
            }, clearPreferences: { preferences += 1 })
            XCTFail("Incomplete erase should leave a journal.")
        } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertEqual(preferences, 0)
        let nextLaunch = WalletEraseJournal(root: root)
        try await nextLaunch.finish(retireCredentials: { credentials += 1 }, eraseNetworkState: { network += 1 },
                                    clearPreferences: { preferences += 1 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.marker.path))
        XCTAssertEqual(credentials, 2); XCTAssertEqual(network, 2); XCTAssertEqual(preferences, 1)
    }
}
