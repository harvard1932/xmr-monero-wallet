import SwiftUI

private enum WalletLanguages {
    static let preference = "wallet.interface.language"
    static let supported = ["en", "ar", "bn", "de", "es", "fr", "hi", "id", "it", "ja", "ko",
                            "ms", "nl", "pl", "pt", "ru", "sw", "th", "tr", "vi", "zh-Hans", "zh-Hant"]

    static func autonym(_ id: String) -> String {
        Locale(identifier: id).localizedString(forIdentifier: id) ?? id
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
