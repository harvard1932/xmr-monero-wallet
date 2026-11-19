import SwiftUI

struct VaultGate: View {
    @ObservedObject var vault: WalletVault
    let create: (VaultLocation) async throws -> String
    let restore: (VaultLocation, VaultRestore) async throws -> Void
    let open: (VaultLocation) async throws -> Void
    let close: () async -> Void
    let readSeed: () async throws -> String
    let onSource: () -> Void
    let primaryAddress: () async throws -> String

    var body: some View {
        VaultEntry(vault: vault, create: create, restore: restore, open: open, close: close,
                   readSeed: readSeed, onSource: onSource, primaryAddress: primaryAddress)
            .id(vault.sessionID)
    }
}

private enum GateStep { case welcome, create, restore, backup, verify }
private enum RestoreMethod: String, CaseIterable {
    case phrase = "Phrase", keys = "Private keys", watch = "View-only"
}

private struct VaultEntry: View {
    @ObservedObject var vault: WalletVault
    let create: (VaultLocation) async throws -> String
    let restore: (VaultLocation, VaultRestore) async throws -> Void
    let open: (VaultLocation) async throws -> Void
    let close: () async -> Void
    let readSeed: () async throws -> String
    let onSource: () -> Void
    let primaryAddress: () async throws -> String

    @State private var step = GateStep.welcome
    @State private var name = ""
    @State private var phrase = ""
    @State private var method = RestoreMethod.phrase
    @State private var seedFormat = VaultSeedFormat.classic
    @State private var passphrase = ""
    @State private var polyseedOffset = false
    @State private var address = ""
    @State private var viewKey = ""
    @State private var spendKey = ""
    @State private var height = ""
    @State private var answerA = ""
    @State private var answerB = ""
    @State private var challengeIndices: [Int] = []
    @State private var notice: String?
    @State private var creatingBackup: VaultWallet?
    @State private var confirmAddress = false
    @State private var reviewAddress = ""
    @State private var expectedAddress = ""
    @State private var reviewCompletion: CheckedContinuation<Bool, Never>?
    @State private var confirmWipe = false
    @State private var eraseConfirmation = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    topBar
                    switch vault.phase {
                    case .loading:
                        if let error = vault.loadError {
                            heading("Wallet storage", subtitle: error)
                            Button("Read again") { vault.reconcile() }.buttonStyle(WalletPrimaryButton())
                            Button("Erase all wallet data", role: .destructive) { eraseConfirmation = ""; confirmWipe = true }.disabled(vault.working)
                        } else {
                            ProgressView("Opening wallet storage")
                        }
                    case .needsWallet, .locked, .opening, .unlocked:
                        if step == .backup { backup }
                        else if step == .verify { verify }
                        else if vault.phase == .locked { locked }
                        else if step == .create || step == .restore { setup }
                        else { welcome }
                    }
                    if let notice {
                        WalletNotice(text: notice)
                            .accessibilityIdentifier("vault.notice")
                    }
                    if vault.working { ProgressView("Working…").font(.footnote) }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 30)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(WalletStyle.ink.ignoresSafeArea())
        .foregroundStyle(WalletStyle.text)
        .tint(WalletStyle.apricot)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $confirmAddress, onDismiss: { finishReview(false) }) {
            WalletSheet(title: "Confirm restored address") {
                Text("Compare this primary address with your original wallet before finishing. A different passphrase or derivation can open a different wallet.")
                Text(verbatim: reviewAddress).font(.body.monospaced()).textSelection(.enabled)
                Button("I recognize this address") { finishReview(true) }.buttonStyle(WalletPrimaryButton())
                Button("Return to restore") { finishReview(false) }.buttonStyle(WalletPrimaryButton(muted: true))
            }
        }
        .onDisappear { finishReview(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, vault.phase == .loading, vault.loadError != nil { vault.reconcile() }
        }
        .sheet(isPresented: $confirmWipe, onDismiss: { eraseConfirmation = "" }) {
            WalletSheet(title: "Erase all app data") {
                Text("This deletes local wallets, the app PIN and settings. You will need your recovery backups.")
                TextField("Type DELETE", text: $eraseConfirmation)
                    .keyboardType(.asciiCapable).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Erase with iPhone passcode", role: .destructive) {
                    guard eraseConfirmation == "DELETE" else { return }
                    eraseConfirmation = ""
                    confirmWipe = false
                    Task {
                        do { await close(); try await vault.eraseAllFromLock() }
                        catch is CancellationError {}
                        catch { notice = WalletL10n.diagnostic(error) }
                    }
                }.disabled(eraseConfirmation != "DELETE" || vault.working)
            }
        }
    }

    private func finishReview(_ accepted: Bool) {
        let completion = reviewCompletion
        reviewCompletion = nil
        confirmAddress = false
        completion?.resume(returning: accepted)
    }

    private func verifyRestoredAddress(_ address: String) async throws {
        guard !address.isEmpty else { throw InputError("Unable to read the restored address.") }
        let expected = expectedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expected.isEmpty || expected == address else {
            throw InputError("The restored address differs from the original address. Check your phrase, passphrase and recovery method.")
        }
        reviewAddress = address
        let accepted = await withCheckedContinuation { continuation in
            reviewCompletion = continuation
            confirmAddress = true
        }
        guard accepted else { throw CancellationError() }
    }

    private var topBar: some View {
        HStack(spacing: 11) {
            MoneroMark().foregroundStyle(WalletStyle.apricot)
                .frame(width: 26, height: 26)
                .padding(7).background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 12))
            Text("XMR Wallet").font(.headline.weight(.bold))
            Spacer(minLength: 2)
            WalletLanguagePicker(compact: true)
            Button(action: onSource) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("Source")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13).frame(minHeight: 44)
                .foregroundStyle(WalletStyle.apricot)
            }
            .accessibilityLabel("View the open source code")
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            VaultArtwork().frame(height: 240).padding(.top, 4)
            heading("XMR Monero\nWallet",
                    subtitle: "Free and open source. Create a wallet on this iPhone or restore one from a backup.")
            VStack(spacing: 12) {
                Button {
                    name = vault.wallets.isEmpty ? "Personal wallet" : ""
                    step = .create
                    notice = nil
                } label: { actionLabel("Create a wallet", symbol: "plus") }
                .buttonStyle(WalletPrimaryButton()).accessibilityIdentifier("vault.create")
                Button {
                    name = vault.wallets.isEmpty ? "Restored wallet" : ""
                    step = .restore
                    notice = nil
                } label: { actionLabel("Restore a wallet", symbol: "arrow.counterclockwise") }
                .buttonStyle(WalletPrimaryButton(muted: true)).accessibilityIdentifier("vault.restore")
                Text("Developer preview. Independent security review is pending.")
                    .font(.footnote).foregroundStyle(WalletStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                if !vault.wallets.isEmpty {
                    Button("Back to my wallets") { vault.lock() }.padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder private var locked: some View {
        if let wallet = vault.active {
            VStack(alignment: .leading, spacing: 22) {
                VaultArtwork().frame(height: 196).padding(.top, 4)
                heading("Wallet locked", subtitle: "Use your app PIN or enabled biometrics to unlock.")
                if vault.wallets.count > 1 {
                    Menu {
                        ForEach(vault.wallets) { row in Button(row.name) { vault.select(row) } }
                    } label: {
                        HStack { Label(wallet.name, systemImage: "wallet.bifold"); Spacer(); Image(systemName: "chevron.up.chevron.down") }
                            .padding().background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .accessibilityLabel("Select wallet, currently \(wallet.name)")
                } else {
                    Label(wallet.name, systemImage: "wallet.bifold").foregroundStyle(WalletStyle.muted)
                }
                Button { unlock(wallet) } label: { actionLabel("Unlock wallet", symbol: "lock.open") }
                    .buttonStyle(WalletPrimaryButton()).disabled(vault.working)
                Button("Create or restore another wallet") { step = .welcome; notice = nil; vault.beginAdding() }
                    .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44).disabled(vault.working)
                Button("Erase all wallet data", role: .destructive) { eraseConfirmation = ""; confirmWipe = true }
                    .font(.footnote).frame(maxWidth: .infinity, minHeight: 44).disabled(vault.working)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { notice = nil; wipeInputs(); step = .welcome } label: { Label("Back", systemImage: "chevron.left") }
                .font(.subheadline).disabled(vault.working)
            heading(step == .restore ? "Restore wallet" : "Create a wallet",
                    subtitle: step == .restore ? "Choose a recovery method. Your recovery details stay on this iPhone." :
                        "Give your wallet a name. You’ll then write down its recovery phrase.")
            WalletField(label: "Wallet name") {
                TextField("Personal wallet", text: $name).textInputAutocapitalization(.words)
                    .accessibilityLabel("Wallet name")
            }
            if step == .restore {
                Picker("Recovery method", selection: $method) {
                    ForEach(RestoreMethod.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented)
                if method == .phrase {
                    Picker("Seed format", selection: $seedFormat) {
                        ForEach(VaultSeedFormat.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                    WalletField(label: "Recovery phrase") {
                        secureInput("Enter the words in order", $phrase)
                    }
                    if seedFormat == .bip39 {
                        WalletField(label: "BIP39 passphrase (if originally set)") {
                            secureInput("Leave empty for no passphrase", $passphrase)
                        }
                        Text("Uses Exodus / Cake account 0, m/44′/128′/0′/0/0. Each passphrase opens a different address. Compare your original address after recovery.")
                            .font(.footnote).foregroundStyle(WalletStyle.muted)
                    } else if seedFormat == .myMonero {
                        Text("Keep your original MyMonero phrase. This import restores its two private keys.")
                            .font(.footnote).foregroundStyle(WalletStyle.muted)
                    } else {
                        WalletField(label: "Seed offset or Polyseed passphrase (optional)") {
                            secureInput("Leave empty if unused", $passphrase)
                        }
                        if seedWords.count == 16 {
                            Toggle("Original wallet used a Monero seed offset", isOn: $polyseedOffset)
                            if polyseedOffset {
                                Text("Use this option for unencrypted Polyseed words with a Monero wallet seed offset.")
                                    .font(.footnote).foregroundStyle(WalletStyle.muted)
                            }
                        }
                        Text("Use a 25-word classic Monero seed or 16-word Polyseed.")
                            .font(.footnote).foregroundStyle(WalletStyle.muted)
                    }
                } else {
                    if method == .watch {
                        PairingQRImportButton { pairing in
                            address = pairing.address
                            viewKey = pairing.viewKey
                            spendKey = ""
                        }
                    }
                    WalletField(label: "Primary wallet address") {
                        TextField("Monero address", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    WalletField(label: "Private view key") { secureInput("64 hexadecimal characters", $viewKey) }
                    if method == .keys {
                        WalletField(label: "Private spend key") { secureInput("64 hexadecimal characters", $spendKey) }
                    }
                }
                if method == .phrase {
                    WalletField(label: "Original primary address (optional)") {
                        TextField("Compare against this address", text: $expectedAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                WalletField(label: "Restore height (optional)") {
                    TextField("0", text: $height).keyboardType(.numberPad).accessibilityLabel("Restore height")
                }
                Text("Leave blank to scan from the beginning. An earlier height includes older payments.")
                    .font(.footnote).foregroundStyle(WalletStyle.muted)
            }
            Button { startSetup() } label: {
                actionLabel(step == .restore ? "Restore wallet" : "Create wallet", symbol: "arrow.right")
            }.buttonStyle(WalletPrimaryButton()).disabled(vault.working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.disabled(vault.working)
    }

    private func secureInput(_ placeholder: String, _ value: Binding<String>) -> some View {
        SecureField(LocalizedStringKey(placeholder), text: value).textInputAutocapitalization(.never).autocorrectionDisabled()
            .privacySensitive()
    }

    private var backup: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Write it down.", subtitle: "Keep these words in order on paper. Anyone with this phrase can spend your Monero.")
            VaultSeedWords(phrase: phrase)
            Button {
                let words = seedWords
                guard words.count >= 2 else { notice = "The wallet returned an incomplete recovery phrase."; return }
                challengeIndices = Array(words.indices.shuffled().prefix(2)).sorted()
                answerA = ""; answerB = ""; notice = nil; step = .verify
            } label: { actionLabel("I wrote down my phrase", symbol: "checkmark") }.buttonStyle(WalletPrimaryButton())
        }
    }

    private var verify: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Check your backup.", subtitle: "Look at your written copy and enter the two words requested below.")
            if challengeIndices.count == 2 {
                WalletField(label: "Word \(challengeIndices[0] + 1)") { secureInput("Enter the word", $answerA) }
                WalletField(label: "Word \(challengeIndices[1] + 1)") { secureInput("Enter the word", $answerB) }
            }
            Button {
                guard let wallet = creatingBackup, challengeIndices.count == 2 else { return }
                let answers = [answerA, answerB].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let words = seedWords
                guard zip(challengeIndices, answers).allSatisfy({ i, answer in
                    words.indices.contains(i) && answer == words[i].lowercased()
                }) else { notice = "Those words didn’t match. Check their positions on your written backup."; return }
                do {
                    try vault.markBackupVerified(for: wallet)
                    wipeInputs()
                    vault.enter(wallet)
                } catch { notice = WalletL10n.diagnostic(error) }
            } label: { actionLabel("Open wallet", symbol: "arrow.right") }
            .buttonStyle(WalletPrimaryButton()).disabled(answerA.isEmpty || answerB.isEmpty)
            Button("View phrase again") { answerA = ""; answerB = ""; notice = nil; step = .backup }
                .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(.system(.largeTitle, design: .serif).weight(.semibold))
                .tracking(-1.0).fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringKey(subtitle)).font(.body).foregroundStyle(WalletStyle.muted).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .contain)
    }

    private func actionLabel(_ label: String, symbol: String) -> some View {
        HStack { Text(LocalizedStringKey(label)); Spacer(); Image(systemName: symbol).font(.body.weight(.semibold)) }
            .padding(.horizontal, 19)
    }

    private var seedWords: [String] { phrase.split(whereSeparator: \.isWhitespace).map(String.init) }

    private func wipeInputs() {
        phrase = ""; address = ""; viewKey = ""; spendKey = ""; answerA = ""; answerB = ""; height = ""
        challengeIndices = []; method = .phrase; seedFormat = .classic; passphrase = ""; creatingBackup = nil; expectedAddress = ""; reviewAddress = ""; polyseedOffset = false
    }

    private func restoreRequest() async throws -> VaultRestore {
        let block = height.walletASCIIDigits.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = block.isEmpty ? 0 : UInt64(block) else { throw InputError("Enter a whole block height.") }
        let source: WalletRestoreSource
        switch method {
        case .phrase:
            let cleaned = seedWords.joined(separator: " ")
            guard !cleaned.isEmpty else { throw InputError("Enter your recovery phrase.") }
            if seedFormat == .classic { source = try ProtectedSeed.source(words: cleaned, passphrase: passphrase, nativePolyseedOffset: polyseedOffset) }
            else { source = try await LegacySeedRecovery.source(format: seedFormat, phrase: cleaned, passphrase: passphrase) }
        case .keys, .watch:
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let view = viewKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let spend = spendKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            func keyIsValid(_ s: String) -> Bool { s.utf8.count == 64 && s.unicodeScalars.allSatisfy(hex.contains) }
            guard !trimmed.isEmpty, keyIsValid(view), method == .watch || keyIsValid(spend) else {
                throw InputError("Enter the primary address and complete 64-character keys.")
            }
            source = .keys(address: trimmed, view: view, spend: method == .watch ? nil : spend)
        }
        return VaultRestore(source: source, height: value)
    }

    private func startSetup() {
        guard let session = vault.beginOperation() else { return }
        notice = nil
        let restoring = step == .restore
        Task { @MainActor in
            defer { vault.endOperation(session) }
            var draft: VaultLocation?
            do {
                let request = restoring ? try await restoreRequest() : nil
                try vault.requireCurrent(session)
                let location = try await vault.draft(name: name, restored: restoring, session: session)
                draft = location
                // Other wallets can be added from the lock screen.
                await close()
                try vault.requireCurrent(session)
                let words: String
                if let request {
                    try await restore(location, request)
                    try vault.requireCurrent(session)
                    let restoredAddress = try await primaryAddress()
                    try vault.requireCurrent(session)
                    try await verifyRestoredAddress(restoredAddress)
                    try vault.requireCurrent(session)
                    let backup: VaultBackup
                    if method == .phrase {
                        backup = .init(format: (seedFormat == .classic && seedWords.count == 16 && polyseedOffset) ? "Polyseed with Monero seed offset" : seedFormat.rawValue, phrase: seedWords.joined(separator: " "), address: restoredAddress,
                                       view: nil, spend: nil, requiresPassphrase: seedFormat != .myMonero && !passphrase.isEmpty)
                    } else {
                        backup = .init(format: method.rawValue, phrase: nil, address: restoredAddress,
                                       view: viewKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                       spend: method == .keys ? spendKey.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                                       requiresPassphrase: false)
                    }
                    try vault.saveOriginal(backup, for: location.wallet)
                    words = ""
                } else {
                    words = try await create(location)
                    guard words.split(whereSeparator: \.isWhitespace).count >= 2 else {
                        throw InputError("The wallet could not produce a recovery phrase.")
                    }
                }
                try vault.requireCurrent(session)
                try vault.register(location)
                draft = nil
                wipeInputs()
                if restoring {
                    vault.enter(location.wallet)
                } else {
                    creatingBackup = location.wallet
                    phrase = words
                    step = .backup
                }
            } catch {
                if let draft {
                    await close()
                    do { try vault.discardDraft(draft) }
                    catch { if vault.sessionID == session { notice = WalletL10n.diagnostic(error); return } }
                }
                if vault.sessionID == session, !(error is CancellationError) { notice = WalletL10n.diagnostic(error) }
            }
        }
    }

    private func unlock(_ wallet: VaultWallet) {
        guard let session = vault.beginOperation() else { return }
        notice = nil
        Task { @MainActor in
            defer { vault.endOperation(session) }
            var openingCore = false
            do {
                let location = try await vault.authorizedLocation(for: wallet, reason: "Unlock your Monero wallet.")
                try vault.requireCurrent(session)
                await close()
                try vault.requireCurrent(session)
                openingCore = true
                try await open(location)
                try vault.requireCurrent(session)
                if wallet.backupVerified {
                    vault.enter(wallet)
                } else {
                    let words = try await readSeed()
                    try vault.requireCurrent(session)
                    guard words.split(whereSeparator: \.isWhitespace).count >= 2 else {
                        throw InputError("The wallet could not read its recovery phrase.")
                    }
                    phrase = words
                    creatingBackup = wallet
                    step = .backup
                }
            } catch {
                if openingCore { await close() }
                if vault.sessionID == session, !(error is CancellationError) { notice = WalletL10n.diagnostic(error) }
            }
        }
    }

    private struct InputError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { WalletL10n.text(message) }
    }
}

struct VaultSeedWords: View {
    let phrase: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                 count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 12) {
            ForEach(words.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit()).foregroundStyle(WalletStyle.apricot)
                    Text(words[index]).font(.body.monospaced()).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
        }.padding(16).background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 16))
            .privacySensitive()
    }
}
