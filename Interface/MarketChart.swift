import Charts
import SwiftUI

private struct PriceClose: Identifiable {
    let date: Date
    let usd: Double
    var id: Date { date }
}

private struct KrakenPriceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct MarketChart: View {
    let allowsConnection: Bool
    @State private var closes: [PriceClose] = []
    @State private var days = 30
    @State private var loading = false
    @State private var error: String?
    private var visible: ArraySlice<PriceClose> { closes.suffix(days) }

    var body: some View {
        WalletSheet(title: "XMR price") {
            if let latest = visible.last, let first = visible.first {
                Text("XMR / USD").font(.subheadline.weight(.semibold)).foregroundStyle(WalletStyle.muted)
                Text(latest.usd, format: .currency(code: "USD")).font(.largeTitle.bold()).monospacedDigit()
                let change = (latest.usd - first.usd) / first.usd
                Text(change, format: .percent.precision(.fractionLength(2)).sign(strategy: .always()))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(change < 0 ? WalletStyle.apricot : WalletStyle.mint)
                Picker("Time range", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }.pickerStyle(.segmented)
                Chart(visible) { sample in
                    LineMark(x: .value("Date", sample.date), y: .value("USD", sample.usd))
                        .foregroundStyle(WalletStyle.apricot)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .frame(height: 184)
                .accessibilityLabel("Monero price in US dollars over \(days) days")
                .accessibilityValue("Latest price " + latest.usd.formatted(.currency(code: "USD")))
                Text("Daily closes from Kraken through " + latest.date.formatted(date: .abbreviated, time: .omitted) + ". The current day updates while trading continues.")
                    .font(.footnote).foregroundStyle(WalletStyle.muted)
            } else {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 40)).foregroundStyle(WalletStyle.apricot)
                Text("Monero in US dollars").font(.title2.bold())
            }
            Text(allowsConnection ? "Loading prices connects directly to Kraken. Kraken sees your IP address and a request for XMR/USD prices." : "Direct price lookups are disabled while the wallet is offline or using a proxy.")
                .font(.footnote).foregroundStyle(WalletStyle.muted)
            if let error { WalletNotice(text: error) }
            Button(loading ? "Loading…" : closes.isEmpty ? "Load Kraken prices" : "Refresh prices") {
                Task { await load() }
            }.buttonStyle(WalletPrimaryButton()).disabled(loading || !allowsConnection)
        }
    }

    private func load() async {
        guard allowsConnection, !loading else { return }
        loading = true
        defer { loading = false }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "api.kraken.com"
            components.path = "/0/public/OHLC"
            components.queryItems = [
                .init(name: "pair", value: "XMRUSD"), .init(name: "interval", value: "1440"),
                .init(name: "since", value: String(Int(Date().addingTimeInterval(-91 * 86400).timeIntervalSince1970)))
            ]
            guard let url = components.url else { throw URLError(.badURL) }
            let (bytes, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let errors = data["error"] as? [String], errors.isEmpty,
                  let results = data["result"] as? [String: Any], let candles = results["XXMRZUSD"] as? [[Any]]
            else { throw KrakenPriceError("Kraken could not return XMR/USD prices. Try again later.") }
            let loaded = candles.compactMap { row -> PriceClose? in
                guard row.count >= 5, let timestamp = row[0] as? Double, let raw = row[4] as? String,
                      let price = Double(raw), price.isFinite, price > 0 else { return nil }
                return PriceClose(date: Date(timeIntervalSince1970: timestamp), usd: price)
            }
            guard loaded.count > 1 else { throw KrakenPriceError("Kraken returned too few prices to draw the chart.") }
            closes = loaded.sorted { $0.date < $1.date }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
