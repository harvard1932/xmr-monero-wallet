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
    var minutes: Int {
        switch self { case .day: 5; case .week: 60; case .month: 240; case .quarter: 1440 }
    }
    var title: LocalizedStringKey {
        switch self { case .day: "1 day"; case .week: "7 days"; case .month: "30 days"; case .quarter: "90 days" }
    }

    func request(at date: Date) -> URL {
        var url = URLComponents(string: "https://api.kraken.com/0/public/OHLC")!
        url.queryItems = [
            .init(name: "pair", value: "XMRUSD"), .init(name: "interval", value: String(minutes)),
            .init(name: "since", value: String(Int(date.timeIntervalSince1970) - rawValue * 86_400))
        ]
        return url.url!
    }
}

struct MarketChart: View {
    let allowsConnection: Bool
    @State private var closes: [PriceClose] = []
    @State private var window = PriceWindow.day
    @State private var enabled = false
    @State private var revision = 0
    @State private var lastUpdated: Date?
    @State private var loading = false
    @State private var error: String?
    @Environment(\.scenePhase) private var phase

    private var fetchID: String { "\(enabled)-\(allowsConnection)-\(window.rawValue)-\(revision)-\(phase == .active)" }

    var body: some View {
        WalletSheet(title: "XMR price") {
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
                Text("Live prices refresh every 30 seconds while this chart is open. Kraken receives a request for XMR/USD and can see your IP address.")
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
                    let bytes = try await PublicJSON.read(window.request(at: Date()), limit: 512 * 1024, timeout: 12)
                    try Task.checkCancellation()
                    closes = try Self.prices(from: bytes)
                    lastUpdated = Date()
                    error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = WalletL10n.text("Kraken could not return XMR/USD prices. Try again later.")
                }
                loading = false
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    static func prices(from bytes: Data) throws -> [PriceClose] {
        guard let data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let errors = data["error"] as? [String], errors.isEmpty, let results = data["result"] as? [String: Any],
              let candles = results["XXMRZUSD"] as? [[Any]] else { throw URLError(.cannotParseResponse) }
        let values = candles.compactMap { row -> PriceClose? in
            guard row.count >= 5, let timestamp = row[0] as? Double, let raw = row[4] as? String,
                  let price = Double(raw), price.isFinite, price > 0 else { return nil }
            return PriceClose(date: Date(timeIntervalSince1970: timestamp), usd: price)
        }
        guard values.count > 1 else { throw URLError(.cannotParseResponse) }
        return values.sorted { $0.date < $1.date }
    }
}
