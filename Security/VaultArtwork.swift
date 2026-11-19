import SwiftUI

/// A guilloché print with an offset Monero medallion. All artwork is local.
struct VaultArtwork: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let field = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 21)
            ctx.clip(to: field)
            ctx.fill(field, with: .linearGradient(
                Gradient(colors: [Color(red: 0.27, green: 0.15, blue: 0.23),
                                  Color(red: 0.42, green: 0.23, blue: 0.28),
                                  Color(red: 0.73, green: 0.42, blue: 0.39)]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
            let center = CGPoint(x: w * 0.59, y: h * 0.49)
            let radius = min(h * 0.35, w * 0.225)
            // Concentric engraving is intentionally clipped at the paper edges.
            for band in 0..<65 {
                var wave = Path()
                let r = radius * (0.68 + CGFloat(band) * 0.053)
                for point in 0...300 {
                    let a = Double(point) * 2 * .pi / 300
                    let ripple = 1 + 0.08 * cos(11 * a + Double(band) * 0.065) + 0.025 * sin(6 * a)
                    let p = CGPoint(x: center.x + cos(a) * r * ripple * 1.21,
                                    y: center.y + sin(a) * r * ripple * 0.92)
                    if point == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
                }
                ctx.stroke(wave, with: .color(WalletStyle.cardAccent.opacity(band.isMultiple(of: 5) ? 0.50 : 0.31)), lineWidth: 0.65)
            }
            let dark = Color(red: 0.22, green: 0.12, blue: 0.19)
            func rim(_ r: CGFloat, _ c: CGPoint) -> Path {
                Path(ellipseIn: CGRect(x: c.x-r, y: c.y-r, width: 2*r, height: 2*r))
            }
            ctx.fill(rim(radius + 4, CGPoint(x: center.x + 2, y: center.y + 5)), with: .color(dark))
            ctx.fill(rim(radius, center), with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.80, blue: 0.62), WalletStyle.cardAccent,
                                  Color(red: 0.78, green: 0.42, blue: 0.34)]),
                startPoint: CGPoint(x: center.x-radius, y: center.y-radius),
                endPoint: CGPoint(x: center.x+radius, y: center.y+radius)))
            for pct in [0.95, 0.88, 0.85] {
                ctx.stroke(rim(radius * pct, center), with: .color(dark.opacity(0.68)), lineWidth: pct == 0.85 ? 1.1 : 0.65)
            }
            for tick in 0..<96 {
                let a = Double(tick) * 2 * .pi / 96
                let inner = radius * (tick.isMultiple(of: 4) ? 0.90 : 0.918)
                var line = Path()
                line.move(to: CGPoint(x: center.x + inner * cos(a), y: center.y + inner * sin(a)))
                line.addLine(to: CGPoint(x: center.x + radius * 0.942 * cos(a), y: center.y + radius * 0.942 * sin(a)))
                ctx.stroke(line, with: .color(dark.opacity(0.8)), lineWidth: 0.65)
            }
            let mark = ctx.resolveSymbol(id: 1)
            if let mark { ctx.draw(mark, in: CGRect(x: center.x-radius*0.66, y: center.y-radius*0.62,
                                                    width: radius*1.32, height: radius*1.32)) }
            var guide = Path()
            for x in [CGFloat(17), w-17] {
                for y in [CGFloat(17), h-17] {
                    guide.move(to: CGPoint(x: x-3.5, y: y)); guide.addLine(to: CGPoint(x: x+3.5, y: y))
                    guide.move(to: CGPoint(x: x, y: y-3.5)); guide.addLine(to: CGPoint(x: x, y: y+3.5))
                }
            }
            ctx.stroke(guide, with: .color(WalletStyle.cardAccent.opacity(0.75)), lineWidth: 0.8)
            ctx.stroke(field, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
        } symbols: {
            MoneroMark().foregroundStyle(Color(red: 0.25, green: 0.15, blue: 0.20)).frame(width: 100, height: 100).tag(1)
        }.accessibilityHidden(true)
    }
}
