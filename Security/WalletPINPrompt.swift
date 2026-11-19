import CryptoKit
import LocalAuthentication
import SwiftUI
import UIKit

@MainActor
enum WalletPINPrompt {
    private static weak var host: UIViewController?
    private static var promptID: UUID?
    private static var generation = UUID()
    private static var complete: ((Result<SymmetricKey, Error>) -> Void)?

    static func request(reason: String, existingCiphertexts: Bool, manage: Bool = false) async throws -> SymmetricKey {
        guard complete == nil else { throw PINFailure("Finish the current authentication request first.") }
        let initialGeneration = generation
        let state = try await WalletPINStore.shared.state()
        try Task.checkCancellation()
        let presenter = try await readyPresenter(generation: initialGeneration)
        guard complete == nil, generation == initialGeneration else { throw CancellationError() }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let language = UserDefaults.standard.string(forKey: "wallet.interface.language") ?? ""
            let appearance = WalletAppearance(rawValue: UserDefaults.standard.string(forKey: WalletAppearance.preference) ?? "") ?? .dark
            let form = WalletPINForm(reason: reason, manage: manage, existingCiphertexts: existingCiphertexts,
                initial: state, finish: { result in finish(id: id, result) })
                .environment(\.locale, language.isEmpty ? .autoupdatingCurrent : Locale(identifier: language))
                .environment(\.layoutDirection, (language.isEmpty ? Locale.current.language.characterDirection == .rightToLeft : language == "ar") ? .rightToLeft : .leftToRight)
                .preferredColorScheme(appearance.scheme)
            let controller = UIHostingController(rootView: form)
            controller.modalPresentationStyle = .overFullScreen
            controller.isModalInPresentation = true
            host = controller
            promptID = id
            complete = { continuation.resume(with: $0) }
            presenter.present(controller, animated: true)
            if controller.presentingViewController == nil { finish(id: id, .failure(CancellationError())) }
        }
    }

    // A destructive confirmation alert may still be animating away when its
    // handler asks for a PIN. Presenting on that alert would lose the request.
    private static func readyPresenter(generation expected: UUID) async throws -> UIViewController {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == expected, complete == nil,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                  var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { throw CancellationError() }
            while let shown = top.presentedViewController, !shown.isBeingDismissed { top = shown }
            if top.viewIfLoaded?.window != nil, !top.isBeingDismissed, top.presentedViewController == nil,
               top.transitionCoordinator == nil, !(top is UIAlertController) { return top }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PINFailure("Wait for the current dialog to close, then try again.")
    }

    static func cancel() {
        generation = UUID()
        if let id = promptID { finish(id: id, .failure(CancellationError())) }
    }

    private static func finish(id: UUID, _ result: Result<SymmetricKey, Error>) {
        guard id == promptID, let continuation = complete else { return }
        complete = nil
        promptID = nil
        let controller = host
        host = nil
        // Dismiss before a caller attempts to present a system/device prompt.
        if let controller, controller.presentingViewController != nil {
            controller.dismiss(animated: false) { continuation(result) }
        } else { continuation(result) }
    }
}

private enum PINScreen { case unlock, enroll, reset, preferences, change }

private struct WalletPINForm: View {
    let reason: String
    let manage: Bool
    let existingCiphertexts: Bool
    let finish: (Result<SymmetricKey, Error>) -> Void
    @State private var screen: PINScreen
    @State private var useBiometricsOnSetup = false
    @State private var biometric: Bool
    @State private var pin = ""
    @State private var repeatPIN = ""
    @State private var key: SymmetricKey?
    @State private var notice: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?

    init(reason: String, manage: Bool, existingCiphertexts: Bool, initial: PINEnvelope?,
         finish: @escaping (Result<SymmetricKey, Error>) -> Void) {
        self.reason = reason; self.manage = manage; self.existingCiphertexts = existingCiphertexts; self.finish = finish
        _screen = State(initialValue: initial == nil ? .enroll : .unlock)
        _biometric = State(initialValue: initial?.biometrics ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "lock.shield").font(.title).foregroundStyle(WalletStyle.apricot)
                    Spacer()
                    Button("Cancel") { finish(.failure(CancellationError())) }.disabled(busy)
                }
                Text(title).font(.largeTitle.bold())
                if screen == .unlock { Text(LocalizedStringKey(reason)).foregroundStyle(WalletStyle.muted) }
                if screen == .enroll || screen == .change || screen == .reset {
                    Text("Choose 6 to 12 digits. Your iPhone passcode can reset this PIN.")
                        .foregroundStyle(WalletStyle.muted)
                    field("New app PIN", $pin)
                    field("Confirm new PIN", $repeatPIN)
                    if screen == .enroll, LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                        Toggle("Enable Face ID or Touch ID", isOn: $useBiometricsOnSetup)
                    }
                } else if screen == .unlock { field("App PIN", $pin) }
                if screen == .preferences, let key {
                    Button("Change app PIN") { move(.change) }.buttonStyle(WalletPrimaryButton())
                    Button {
                        run {
                            try await WalletPINStore.shared.setBiometrics(!biometric, key: key)
                            biometric.toggle()
                        }
                    } label: { Text(LocalizedStringKey(biometric ? "Disable biometric unlock" : "Enable Face ID or Touch ID")) }
                    .buttonStyle(WalletPrimaryButton(muted: true))
                    Button("Done") { finish(.success(key)) }.buttonStyle(WalletPrimaryButton(muted: true))
                } else {
                    Button(action: submit) {
                        Text(LocalizedStringKey(screen == .unlock ? "Unlock" : "Save app PIN"))
                    }.buttonStyle(WalletPrimaryButton())
                    .disabled(!PINEnvelope.validPIN(pin) || (screen != .unlock && repeatPIN.isEmpty))
                    if screen == .unlock {
                        if biometric {
                            Button("Use Face ID or Touch ID") {
                                run { try Task.checkCancellation(); accept(try await WalletPINStore.shared.unlockWithBiometrics()) }
                            }.buttonStyle(WalletPrimaryButton(muted: true))
                        }
                        Button("Forgot app PIN?") { move(.reset) }.frame(minHeight: 44)
                    } else if screen == .reset {
                        Text("Enter a new app PIN, then authenticate with the iPhone passcode.")
                            .font(.footnote).foregroundStyle(WalletStyle.muted)
                        Button("Back") { move(.unlock) }
                    }
                }
                if busy { ProgressView("Authenticating…") }
                if let notice { WalletNotice(text: notice) }
            }
            .disabled(busy).frame(maxWidth: 480).padding(25).frame(maxWidth: .infinity)
        }
        .background(WalletStyle.ink.ignoresSafeArea())
        .foregroundStyle(WalletStyle.text).tint(WalletStyle.apricot)
        .onDisappear { operation?.cancel(); operation = nil; pin = ""; repeatPIN = ""; key = nil }
    }

    private var title: LocalizedStringKey {
        switch screen {
        case .unlock: return "Unlock with app PIN"
        case .enroll: return "Set an app PIN"
        case .reset: return "Reset app PIN"
        case .preferences: return "App PIN and biometrics"
        case .change: return "Change app PIN"
        }
    }

    private func field(_ label: LocalizedStringKey, _ value: Binding<String>) -> some View {
        WalletField(label: label) {
            SecureField(label, text: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.walletASCIIDigits }))
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
        }
    }

    private func move(_ next: PINScreen) { pin = ""; repeatPIN = ""; notice = nil; screen = next }

    private func accept(_ unlocked: SymmetricKey) {
        guard !Task.isCancelled else { return }
        if manage { key = unlocked; move(.preferences) } else { finish(.success(unlocked)) }
    }

    private func run(_ block: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; notice = nil
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do { try await block() }
            catch is CancellationError { pin = ""; repeatPIN = ""; notice = WalletL10n.text("Authentication was canceled.") }
            catch { pin = ""; repeatPIN = ""; notice = WalletL10n.diagnostic(error) }
        }
    }

    private func submit() {
        if screen != .unlock, pin != repeatPIN {
            notice = WalletL10n.text("The PIN entries do not match."); repeatPIN = ""; return
        }
        run {
            switch screen {
            case .unlock: accept(try await WalletPINStore.shared.unlock(pin: pin))
            case .enroll:
                let enrolled = try await WalletPINStore.shared.enroll(pin: pin, existingCiphertexts: existingCiphertexts)
                if useBiometricsOnSetup {
                    move(.unlock)
                    try await WalletPINStore.shared.setBiometrics(true, key: enrolled)
                    biometric = true
                }
                accept(enrolled)
            case .reset: accept(try await WalletPINStore.shared.reset(pin: pin))
            case .change:
                guard let key else { throw CancellationError() }
                try await WalletPINStore.shared.change(pin: pin, key: key)
                move(.preferences)
            case .preferences: break
            }
        }
    }
}

struct WalletPINSettingsButton: View {
    @ObservedObject var vault: WalletVault
    @State private var error: String?
    var body: some View {
        Button("App PIN and biometrics") {
            Task {
                do { try await vault.managePIN() }
                catch is CancellationError {}
                catch { self.error = WalletL10n.diagnostic(error) }
            }
        }
        if let error { WalletNotice(text: error) }
    }
}
