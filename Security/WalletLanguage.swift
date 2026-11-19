import SwiftUI

private enum WalletLanguages {
    static let preference = "wallet.interface.language"
    static let supported = ["en", "ar", "bn", "de", "es", "fr", "hi", "id", "it", "ja", "ko",
                            "ms", "nl", "pl", "pt", "ru", "sv", "sw", "th", "tr", "vi", "zh-Hans", "zh-Hant"]

    static func autonym(_ id: String) -> String {
        Locale(identifier: id).localizedString(forIdentifier: id) ?? id
    }
}

/// Lookup for app-authored strings used outside SwiftUI's localized text APIs.
/// Wallet addresses, labels, seeds and free-form diagnostics never leave the device.
enum WalletL10n {
    static var language: String {
        let override = UserDefaults.standard.string(forKey: WalletLanguages.preference) ?? ""
        if WalletLanguages.supported.contains(override) { return override }
        return Bundle.preferredLocalizations(from: WalletLanguages.supported, forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    static var locale: Locale { Locale(identifier: language) }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let code = language
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        let format = bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: code), arguments: arguments)
    }

    static func diagnostic(_ error: Error) -> String {
        let raw = error.localizedDescription
        let localized = message(raw)
        guard error is WalletEngineError, localized == raw,
              let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let english = Bundle(path: path) else { return localized }
        let missing = "__wallet_translation_key_missing__"
        guard english.localizedString(forKey: raw, value: missing, table: nil) == missing else { return localized }
        return text("Wallet diagnostic: %@", raw)
    }

    /// Native engine and operating-system diagnostics are passed through verbatim.
    /// Provide localized context around a native diagnostic when the engine appended it.
    static func message(_ value: String) -> String {
        let broadcast = "Broadcast was not confirmed. Check history before retrying."
        if value.hasPrefix(broadcast + " ") {
            return text(broadcast) + " " + String(value.dropFirst(broadcast.count + 1))
        }
        let prefix = "Invalid or oversized "
        let suffix = " payload."
        if value.hasPrefix(prefix), value.hasSuffix(suffix) {
            let payload = String(value.dropFirst(prefix.count).dropLast(suffix.count))
            return text("Invalid or oversized %@ payload.", payload)
        }
        return text(value)
    }
}

struct WalletLanguageEnvironment: ViewModifier {
    @AppStorage(WalletLanguages.preference) private var selected = ""
    @Environment(\.locale) private var systemLocale
    @Environment(\.layoutDirection) private var systemDirection

    func body(content: Content) -> some View {
        let selection = WalletLanguages.supported.contains(selected) ? selected : ""
        content.environment(\.locale, selection.isEmpty ? systemLocale : Locale(identifier: selection))
            .environment(\.layoutDirection, selection.isEmpty ? systemDirection : (selection == "ar" ? .rightToLeft : .leftToRight))
    }
}

struct WalletLanguagePicker: View {
    var compact = false
    @AppStorage(WalletLanguages.preference) private var selected = ""

    var body: some View {
        if compact {
            Menu {
                picker
            } label: {
                Image(systemName: "globe").font(.body.weight(.medium))
                    .foregroundStyle(WalletStyle.apricot).frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Language")
        } else { picker }
    }

    private var picker: some View {
        Picker("Language", selection: $selected) {
            Text("Use device language").tag("")
            ForEach(WalletLanguages.supported, id: \.self) { code in
                Text(verbatim: WalletLanguages.autonym(code)).tag(code)
            }
        }.pickerStyle(.menu)
    }
}
