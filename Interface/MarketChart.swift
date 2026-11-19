import Charts
import SwiftUI

struct PriceClose: Identifiable {
    let date: Date
    let usd: Double
    var id: Date { date }
}

enum PriceWindow: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, month = 30, quarter = 90
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self { case .day: "1 day"; case .week: "7 days"; case .month: "30 days"; case .quarter: "90 days" }
    }

    var request: URL {
        var url = URLComponents(string: "https://api.coingecko.com/api/v3/coins/monero/market_chart")!
        url.queryItems = [.init(name: "vs_currency", value: "usd"), .init(name: "days", value: String(rawValue))]
        return url.url!
    }
}

struct WalletMarketQuote {
    let usd: Double
    let change24h: Double
    let updated: Date

    static let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=monero&vs_currencies=usd&include_24hr_change=true&include_last_updated_at=true")!

    static func read(_ data: Data, now: Date = Date()) throws -> Self {
        struct Quote: Decodable { let usd, usd_24h_change, last_updated_at: Double }
        let quote = try JSONDecoder().decode([String: Quote].self, from: data)["monero"]
        guard let quote, quote.usd.isFinite, quote.usd > 0, quote.usd_24h_change.isFinite else {
            throw URLError(.cannotParseResponse)
        }
        let updated = Date(timeIntervalSince1970: quote.last_updated_at)
        guard (-300...3600).contains(now.timeIntervalSince(updated)) else { throw URLError(.cannotParseResponse) }
        return .init(usd: quote.usd, change24h: quote.usd_24h_change / 100, updated: updated)
    }

    func fiat(_ atomic: UInt64, locale: Locale) -> String {
        (Double(atomic) / Double(XMRAmount.scale) * usd).formatted(.currency(code: "USD").locale(locale))
    }
}

private struct WalletMarketQuoteKey: EnvironmentKey {
    static let defaultValue: WalletMarketQuote? = nil
}
extension EnvironmentValues {
    var walletMarketQuote: WalletMarketQuote? {
        get { self[WalletMarketQuoteKey.self] }
        set { self[WalletMarketQuoteKey.self] = newValue }
    }
}

struct MarketChart: View {
    let allowsConnection: Bool
    @State private var closes: [PriceClose] = []
    @State private var window = PriceWindow.day
    @Binding var enabled: Bool
    @State private var revision = 0
    @State private var lastUpdated: Date?
    @State private var loading = false
    @State private var error: String?
    @Environment(\.scenePhase) private var phase

    private var fetchID: String { "\(enabled)-\(allowsConnection)-\(window.rawValue)-\(revision)-\(phase == .active)" }

    var body: some View {
        WalletSheet(title: "Market", showsCloseButton: false) {
            Text("XMR / USD").font(.subheadline.weight(.semibold)).foregroundStyle(WalletStyle.muted)
            if let latest = closes.last, let first = closes.first {
                Text(latest.usd, format: .currency(code: "USD")).font(.largeTitle.bold()).monospacedDigit()
                let change = (latest.usd - first.usd) / first.usd
                Text(change, format: .percent.precision(.fractionLength(2)).sign(strategy: .always()))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(change < 0 ? WalletStyle.apricot : WalletStyle.mint)
                Chart(closes) { sample in
                    LineMark(x: .value("Date", sample.date), y: .value("USD", sample.usd))
                        .foregroundStyle(WalletStyle.apricot)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .frame(height: 184)
                if let lastUpdated { Text("Updated \(lastUpdated, style: .time)").font(.caption).foregroundStyle(.secondary) }
            }
            Picker("Time range", selection: $window) {
                ForEach(PriceWindow.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if allowsConnection {
                Text("Enable USD values for this wallet session. CoinGecko receives price requests and can see your IP address.")
                    .font(.footnote).foregroundStyle(.secondary)
                if enabled {
                    HStack {
                        Button("Pause live prices") { enabled = false }
                        Spacer()
                        Button("Refresh prices") { revision += 1 }.disabled(loading)
                    }
                } else {
                    Button("Start live prices") { enabled = true }.buttonStyle(WalletPrimaryButton())
                }
            } else {
                Text("Direct price lookups are disabled while the wallet is offline or using a proxy.").font(.footnote).foregroundStyle(.secondary)
            }
            if loading { ProgressView() }
            if let error { WalletNotice(text: error) }
        }
        .onChange(of: window) { _, _ in closes = []; lastUpdated = nil }
        .task(id: fetchID) {
            guard enabled, allowsConnection, phase == .active else { loading = false; return }
            while !Task.isCancelled {
                loading = true
                do {
                    let bytes = try await PublicJSON.read(window.request, limit: 512 * 1024, timeout: 12)
                    try Task.checkCancellation()
                    closes = try Self.prices(from: bytes)
                    lastUpdated = Date()
                    error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = WalletL10n.text("CoinGecko could not return XMR/USD prices. Try again later.")
                }
                loading = false
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    static func prices(from bytes: Data) throws -> [PriceClose] {
        struct History: Decodable { var prices: [[Double]] }
        let rows = try JSONDecoder().decode(History.self, from: bytes).prices
        let values = rows.compactMap { row -> PriceClose? in
            guard row.count == 2, row[0].isFinite, row[0] > 0, row[1].isFinite, row[1] > 0 else { return nil }
            return PriceClose(date: Date(timeIntervalSince1970: row[0] / 1000), usd: row[1])
        }
        guard values.count > 1 else { throw URLError(.cannotParseResponse) }
        return values.sorted { $0.date < $1.date }
    }
}
