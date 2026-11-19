import SwiftUI

enum WalletAppearance: String, CaseIterable {
    case dark, light, system
    static let preference = "wallet.appearance"

    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Use device appearance"
        }
    }
}

enum WalletStyle {
    private static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: alpha)
        })
    }

    static let ink = adaptive(light: 0xFCF9F5, dark: 0x151217)
    static let dusk = adaptive(light: 0xF3EDE7, dark: 0x211C23)
    static let panel = adaptive(light: 0xEBE3DD, dark: 0x28232B)
    static let stroke = adaptive(light: 0x30252F, dark: 0xFFFFFF, alpha: 0.15)
    static let text = adaptive(light: 0x241C22, dark: 0xFAF3EF)
    static let muted = adaptive(light: 0x605560, dark: 0xBAB0B9)
    static let apricot = adaptive(light: 0x963E15, dark: 0xFFA873)
    static let mint = adaptive(light: 0x286047, dark: 0xABD9C1)
    static let plum = Color(red: 0.245, green: 0.155, blue: 0.193)
    static let cardAccent = Color(red: 1.0, green: 0.659, blue: 0.45)
    static let cardInk = Color(red: 0.082, green: 0.071, blue: 0.091)
}

/// Geometric Monero monogram drawn at any resolution.
struct MoneroMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 32
            context.translateBy(x: (size.width - 32 * scale) / 2, y: (size.height - 32 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 21))
            path.addLine(to: CGPoint(x: 5, y: 21))
            path.addLine(to: CGPoint(x: 5, y: 5))
            path.addLine(to: CGPoint(x: 16, y: 16))
            path.addLine(to: CGPoint(x: 27, y: 5))
            path.addLine(to: CGPoint(x: 27, y: 21))
            path.addLine(to: CGPoint(x: 32, y: 21))
            path.addLine(to: CGPoint(x: 32, y: 26))
            path.addLine(to: CGPoint(x: 22, y: 26))
            path.addLine(to: CGPoint(x: 22, y: 17))
            path.addLine(to: CGPoint(x: 16, y: 23))
            path.addLine(to: CGPoint(x: 10, y: 17))
            path.addLine(to: CGPoint(x: 10, y: 26))
            path.addLine(to: CGPoint(x: 0, y: 26))
            path.closeSubpath()
            context.fill(path, with: .foreground)
        }
        .accessibilityHidden(true)
    }
}

/// An engraved, offset rosette for the balance card and welcome screen.
struct LedgerArt: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.65, y: size.height * 0.53)
            let maxRadius = max(size.width, size.height) * 0.63
            for band in 0..<34 {
                var path = Path()
                let radius = maxRadius * (0.21 + Double(band) * 0.025)
                for sample in 0...300 {
                    let angle = Double(sample) / 300 * .pi * 2
                    let wave = 1 + 0.094 * cos(8 * angle + Double(band) * 0.1) + 0.04 * sin(4 * angle)
                    let x = center.x + radius * cos(angle) * wave
                    let y = center.y + radius * sin(angle) * wave * 0.90
                    let point = CGPoint(x: x, y: y)
                    if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                context.stroke(path, with: .foreground, lineWidth: band.isMultiple(of: 5) ? 0.9 : 0.6)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct WalletPrimaryButton: ButtonStyle {
    var muted = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(muted ? WalletStyle.text : WalletStyle.ink)
            .background(muted ? WalletStyle.panel : WalletStyle.apricot, in: RoundedRectangle(cornerRadius: 15))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.42)
    }
}

struct WalletSheet<Content: View>: View {
    let title: LocalizedStringKey
    var canDismiss = true
    var showsCloseButton = true
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content }
                    .padding(22).frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
            }
            .background(WalletStyle.ink)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.subheadline.bold()) }
                            .accessibilityLabel("Close").disabled(!canDismiss)
                    }
                }
            }
        }
        .interactiveDismissDisabled(!canDismiss)
        .tint(WalletStyle.apricot)
        .foregroundStyle(WalletStyle.text)
    }
}

struct WalletField<Content: View>: View {
    var label: LocalizedStringKey
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(WalletStyle.muted)
            content.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(WalletStyle.stroke))
        }
    }
}

struct WalletNotice: View {
    let text: String
    var body: some View {
        Label(WalletL10n.message(text), systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(WalletStyle.apricot).accessibilityLabel(WalletL10n.message(text))
    }
}

struct WalletLine: View {
    let label: LocalizedStringKey
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(WalletStyle.muted)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }
        .font(.subheadline).padding(.vertical, 3)
    }
}

func abbreviatedAddress(_ address: String) -> String {
    address.count > 23 ? String(address.prefix(10)) + "…" + String(address.suffix(8)) : address
}
