import SwiftUI

enum WalletStyle {
    static let ink = Color(red: 0.082, green: 0.071, blue: 0.091)
    static let dusk = Color(red: 0.128, green: 0.111, blue: 0.139)
    static let panel = Color(red: 0.157, green: 0.137, blue: 0.168)
    static let stroke = Color.white.opacity(0.115)
    static let text = Color(red: 0.979, green: 0.954, blue: 0.937)
    static let muted = Color(red: 0.731, green: 0.691, blue: 0.727)
    static let apricot = Color(red: 1.0, green: 0.659, blue: 0.45)
    static let mint = Color(red: 0.67, green: 0.849, blue: 0.757)
    static let plum = Color(red: 0.245, green: 0.155, blue: 0.193)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.subheadline.bold()) }
                        .accessibilityLabel("Close").disabled(!canDismiss)
                }
            }
        }
        .interactiveDismissDisabled(!canDismiss)
        .tint(WalletStyle.apricot)
        .foregroundStyle(WalletStyle.text)
        .preferredColorScheme(.dark)
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
        Label(text, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(WalletStyle.apricot).accessibilityLabel(text)
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
