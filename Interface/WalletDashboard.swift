import SwiftUI

private enum DashboardTab: String, CaseIterable {
    case wallet = "Wallet", activity = "Activity", tools = "Tools"

    var icon: String {
        switch self {
        case .wallet: "wallet.bifold"
        case .activity: "clock.arrow.circlepath"
        case .tools: "square.grid.2x2"
        }
    }
}

private enum WalletRoute: String, Identifiable {
    case send, scan, receive, contacts, invoices, coins, price, cold
    var id: Self { self }
}

struct WalletDashboard: View {
    var data: WalletPresentation
    var actions: WalletActions
    var showNetwork: (() -> Void)?
    var showPulse: (() -> Void)?
    var privacyScore: Int?
    var walletCount = 1
    @Environment(\.scenePhase) private var phase
    @Environment(\.locale) private var locale
    @State private var livePrices = false
    @State private var marketQuote: WalletMarketQuote?
    @State private var confirmRescan = false
    private var directPrices: Bool { data.networkEnabled && !data.usesProxy }
    private var showPrices: Bool { livePrices && directPrices && phase == .active }
    @State private var tab: DashboardTab = .wallet
    @State private var sheet: WalletRoute?
    @State private var detail: WalletActivityItem?
    @State private var concealed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch tab {
                    case .wallet: overview
                    case .activity:
                        sectionTitle("Activity")
                        ActivityHistory(items: data.activity, contacts: data.contacts, selected: { detail = $0 })
                    case .tools:
                        sectionTitle("Wallet tools")
                        toolList
                    }
                }
                .padding(.horizontal, 20).padding(.top, 13).padding(.bottom, 28)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .refreshable { await actions.refresh() }
            tabBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WalletStyle.ink.ignoresSafeArea())
        .foregroundStyle(WalletStyle.text)
        .tint(WalletStyle.apricot)
        .sheet(item: $sheet) { route in
            switch route {
            case .send: SendView(data: data, actions: actions)
            case .scan: SendView(data: data, actions: actions, scanOnOpen: true)
            case .receive: ReceiveView(data: data, actions: actions)
            case .invoices: InvoiceList(data: data, actions: actions)
            case .coins: CoinList(data: data, actions: actions)
            case .cold:
                if let actions = actions.cold { ColdSigningTools(data: data, actions: actions) }
            case .price: MarketChart(allowsConnection: directPrices, enabled: $livePrices)
            case .contacts:
                ContactList(data: data, actions: actions)
            }
        }
        .sheet(item: $detail) { item in
            ActivityDetail(item: data.activity.first { $0.id == item.id } ?? item, saveNote: actions.saveTransactionNote)
        }
        .environment(\.walletMarketQuote, showPrices ? marketQuote : nil)
        .task(id: showPrices) {
            marketQuote = nil
            guard showPrices else { return }
            while !Task.isCancelled {
                do {
                    let bytes = try await PublicJSON.read(WalletMarketQuote.url, limit: 8192, timeout: 12)
                    try Task.checkCancellation()
                    marketQuote = try WalletMarketQuote.read(bytes)
                } catch {
                    guard !Task.isCancelled else { return }
                    marketQuote = nil
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .confirmationDialog("Rescan blockchain?", isPresented: $confirmRescan) {
            Button("Rescan blockchain") { Task { await actions.rescan?() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scan again from the restore height. Balances may change during sync. View-only wallets must import signed key images again.")
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                MoneroMark().foregroundStyle(WalletStyle.apricot).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monero Wallet").font(.headline.weight(.bold)).tracking(-0.5)
                    if walletCount > 1 {
                        Button(action: actions.wallets) { Label(String(walletCount), systemImage: "wallet.bifold") }
                            .font(.caption).accessibilityLabel(Text("Your wallets"))
                    }
                }
            }
            Spacer()
            Button(action: showNetwork ?? actions.settings) {
                Label {
                    Text(data.nodeName ?? WalletL10n.text(data.syncStatus))
                        .lineLimit(1).truncationMode(.middle).font(.caption)
                } icon: { Image(systemName: data.usesProxy ? "shield.lefthalf.filled" : "network") }
                    .frame(maxWidth: 155, minHeight: 44, alignment: .trailing)
            }.accessibilityLabel("Node and sync settings")
            Button(action: actions.settings) {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(WalletStyle.dusk, in: Circle())
                    .overlay(Circle().stroke(WalletStyle.stroke))
            }.accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20).padding(.vertical, 8).frame(maxWidth: 640)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 35, weight: .semibold)).tracking(-1.7)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var overview: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 8) {
                sectionTitle("Overview")
                Spacer()
                Button(action: actions.wallets) {
                    HStack(spacing: 6) {
                        Image(systemName: "wallet.bifold").font(.caption)
                        Text(data.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(WalletStyle.panel, in: Capsule())
                }.accessibilityLabel("Switch wallet, \(data.name)")
            }
            balanceCard
            HStack(spacing: 10) {
                Button { sheet = .send } label: {
                    Label("Send", systemImage: "arrow.up.right")
                }.buttonStyle(WalletPrimaryButton(muted: true)).disabled(data.viewOnly && actions.cold == nil)
                Button { sheet = .receive } label: {
                    Label("Receive", systemImage: "arrow.down.left")
                }.buttonStyle(WalletPrimaryButton(muted: true))
                Button { sheet = .scan } label: {
                    Image(systemName: "qrcode.viewfinder").font(.title3).frame(width: 48, height: 52)
                        .background(WalletStyle.panel, in: RoundedRectangle(cornerRadius: 15))
                }.accessibilityLabel("Scan payment QR")
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent activity").font(.title3.weight(.semibold)).tracking(-0.6)
                if !data.activity.isEmpty { Text(data.activity.count, format: .number).font(.caption).foregroundStyle(WalletStyle.muted) }
                Spacer()
                Button("View all") { tab = .activity }
                    .font(.caption.weight(.semibold)).foregroundStyle(WalletStyle.apricot)
            }
            ActivityList(items: Array(data.activity.prefix(3)), selected: { detail = $0 })
        }
        Group {
            Button(action: showNetwork ?? actions.settings) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title3).foregroundStyle(WalletStyle.apricot)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WalletL10n.text(data.syncStatus)).font(.subheadline.weight(.semibold))
                        if data.targetHeight > 0 {
                            Text("\(data.scannedHeight) / \(data.targetHeight)").monospacedDigit().font(.caption)
                        }
                        Text(data.routeDescription).font(.caption).foregroundStyle(WalletStyle.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(WalletStyle.muted)
                }.padding(.horizontal, 2)
            }
        }
        HStack {
            if data.networkEnabled, actions.rescan != nil {
                Button("Rescan blockchain") { confirmRescan = true }
            }
            Spacer()
            if let showPulse, let privacyScore {
                Button { showPulse() } label: { Label("Privacy Pulse · \(privacyScore)/100", systemImage: "shield") }
            }
        }.font(.subheadline)

    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Total balance").font(.subheadline.weight(.semibold))
                Button { concealed.toggle() } label: {
                    Image(systemName: concealed ? "eye.slash" : "eye")
                        .font(.footnote).padding(6)
                }.accessibilityLabel(concealed ? "Show balances" : "Hide balances")
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(WalletStyle.plum).frame(width: 5, height: 5)
                    Text(WalletL10n.text(data.network).uppercased(with: WalletL10n.locale)).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(0.6)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(WalletStyle.cardAccent.opacity(0.8), in: Capsule())
                .overlay(Capsule().strokeBorder(WalletStyle.cardInk.opacity(0.25)))
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(concealed ? "••••" : XMRAmount.format(data.total, minFraction: 2))
                    .font(.system(size: 46, weight: .medium)).tracking(-2.1).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.36)
                Text("XMR").font(.callout.weight(.semibold))
            }
            .padding(.vertical, 13)
            .accessibilityElement(children: .combine)
            if !concealed {
                Button { sheet = .price } label: {
                    if showPrices, let quote = marketQuote {
                        HStack {
                            Text(verbatim: quote.fiat(data.total, locale: locale))
                            Text(quote.change24h, format: .percent.precision(.fractionLength(2)).sign(strategy: .always()))
                            Text("24h")
                        }
                    } else { Label("XMR / USD", systemImage: "chart.line.uptrend.xyaxis") }
                }.font(.subheadline).padding(.bottom, 8)
            }
            if !concealed, data.available < data.total {
                Text("Most incoming XMR becomes spendable after 10 confirmations.").font(.caption).padding(.bottom, 6)
            }
            Rectangle().fill(WalletStyle.cardInk.opacity(0.22)).frame(height: 1).padding(.top, 2)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 26) { breakdown }
                VStack(alignment: .leading, spacing: 6) { breakdown }
            }.padding(.top, 13)
            if let progress = data.syncProgress, !data.synced {
                ProgressView(value: max(0, min(1, progress))).tint(WalletStyle.cardInk).padding(.top, 12)
                    .accessibilityLabel("Sync progress")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(19)
        .foregroundStyle(WalletStyle.cardInk)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.60), WalletStyle.cardAccent], startPoint: .topLeading, endPoint: .bottomTrailing)
                    LedgerArt().foregroundStyle(WalletStyle.plum.opacity(0.50))
                        .frame(width: geo.size.width * 0.67, height: geo.size.height * 1.48)
                        .mask(LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .leading, endPoint: .trailing))
                        .offset(x: geo.size.width * 0.15, y: -geo.size.height * 0.15)
                }.frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder private var breakdown: some View {
        detailBalance("Available", data.available)
        detailBalance("Locked", data.total >= data.available ? data.total - data.available : 0)
    }

    private func detailBalance(_ key: LocalizedStringKey, _ amount: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).font(.caption)
            Text(concealed ? "••••" : XMRAmount.format(amount) + " XMR").font(.caption.weight(.semibold)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    private var toolList: some View {
        VStack(spacing: 0) {
            Button(action: showPulse ?? actions.settings) {
                Label("Privacy Pulse", systemImage: "shield.lefthalf.filled")
                    .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            Divider().overlay(WalletStyle.stroke)
            toolRow("Payment requests", "Invoices and payment status", "qrcode", .invoices)
            Divider().overlay(WalletStyle.stroke)
            toolRow("Contacts", "Saved Monero addresses", "person.crop.rectangle.stack", .contacts)
            Divider().overlay(WalletStyle.stroke)
            toolRow("Coin control", "Inspect and freeze outputs", "slider.horizontal.3", .coins)
            Divider().overlay(WalletStyle.stroke)
            if actions.cold != nil {
                toolRow("Cold signing", "Transfer wallet data over QR", "viewfinder", .cold)
                Divider().overlay(WalletStyle.stroke)
            }
            toolRow("XMR price", "Market chart in US dollars", "chart.xyaxis.line", .price)
        }
        .background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 17))
    }

    private func toolRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ symbol: String, _ route: WalletRoute) -> some View {
        Button { sheet = route } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).foregroundStyle(WalletStyle.apricot).frame(width: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(WalletStyle.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(WalletStyle.muted)
            }.padding(15).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var tabBar: some View {
        HStack {
            ForEach(DashboardTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon).font(.system(size: 18, weight: .semibold))
                            .frame(width: 52, height: 27)
                            .background(tab == item ? WalletStyle.apricot.opacity(0.11) : .clear, in: Capsule())
                        Text(LocalizedStringKey(item.rawValue)).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(tab == item ? WalletStyle.apricot : WalletStyle.muted)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, 15).padding(.top, 9).padding(.bottom, 3)
        .background(WalletStyle.dusk.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(WalletStyle.stroke).frame(height: 1) }
    }
}

enum ActivityDirection: String, CaseIterable {
    case all = "All", received = "Received", sent = "Sent"
}

struct ActivityHistory: View {
    var items: [WalletActivityItem]
    var contacts: [WalletContactItem]
    var selected: (WalletActivityItem) -> Void
    @State private var direction = ActivityDirection.all
    @State private var query = ""
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    static func matches(_ item: WalletActivityItem, direction: ActivityDirection, query: String,
                        contacts: [WalletContactItem]) -> Bool {
        guard direction == .all || (direction == .received) == item.incoming else { return false }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty { return true }
        if ([item.transactionHash, item.note] + item.recipients).contains(where: { $0.localizedCaseInsensitiveContains(term) }) {
            return true
        }
        return contacts.contains { item.recipients.contains($0.address) && $0.name.localizedCaseInsensitiveContains(term) }
    }

    // Lifetime turnover can exceed the UInt64 atomic-unit limit even when each transfer fits.
    static func total(_ items: [WalletActivityItem], incoming: Bool) -> Decimal {
        items.reduce(Decimal.zero) { sum, item in
            item.incoming == incoming && !item.failed ? sum + Decimal(item.amount) : sum
        } / Decimal(XMRAmount.scale)
    }

    var body: some View {
        let filtered = items.filter { Self.matches($0, direction: direction, query: query, contacts: contacts) }
        let byDay = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                summary("Received", Self.total(items, incoming: true).formatted(.number.locale(locale).precision(.fractionLength(0...12))) + " XMR")
                summary("Sent", Self.total(items, incoming: false).formatted(.number.locale(locale).precision(.fractionLength(0...12))) + " XMR")
                summary("Transfers", items.count.formatted(.number.locale(locale)))
            }
            .padding().background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 15))
            TextField("Search hash, note or recipient", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Picker("Direction", selection: $direction) {
                ForEach(ActivityDirection.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            if items.isEmpty {
                ActivityList(items: [], selected: selected)
            } else if byDay.isEmpty {
                Text("No matching transfers").foregroundStyle(WalletStyle.muted).padding(.vertical)
            } else {
                ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                    Text(day.formatted(.dateTime.locale(locale).weekday(.wide).day().month().year()))
                        .font(.subheadline.bold()).foregroundStyle(WalletStyle.muted).accessibilityAddTraits(.isHeader)
                    ActivityList(items: byDay[day] ?? [], selected: selected)
                }
            }
        }
    }

    private func summary(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(WalletStyle.muted)
            Text(verbatim: value).font(.caption.weight(.semibold)).monospacedDigit().textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActivityList: View {
    @Environment(\.walletMarketQuote) private var quote
    @Environment(\.locale) private var locale
    let items: [WalletActivityItem]
    let selected: (WalletActivityItem) -> Void
    var body: some View {
        if items.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "tray").font(.system(size: 23, weight: .light)).foregroundStyle(WalletStyle.apricot)
                    .frame(width: 45, height: 45).background(WalletStyle.panel, in: Circle())
                Text("No transactions yet").font(.subheadline.weight(.semibold))
                Text("Payments appear here after your wallet syncs.")
                    .font(.caption).foregroundStyle(WalletStyle.muted).multilineTextAlignment(.center)
            }.padding(18).frame(maxWidth: .infinity)
                .background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(WalletStyle.stroke))
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button { selected(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.incoming ? "arrow.down.left" : "arrow.up.right")
                                .foregroundStyle(item.incoming ? WalletStyle.mint : WalletStyle.apricot)
                                .frame(width: 35, height: 35).background(WalletStyle.panel, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.incoming ? "Received" : "Sent").font(.subheadline.weight(.semibold))
                                if !item.note.isEmpty { Text(verbatim: item.note).font(.caption).lineLimit(1) }
                                Text(item.date.formatted(.dateTime.locale(WalletL10n.locale).month(.abbreviated).day().hour().minute()))
                                    .font(.caption2).foregroundStyle(WalletStyle.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text((item.incoming ? "+" : "−") + XMRAmount.format(item.amount) + " XMR")
                                    .font(.caption.weight(.semibold)).monospacedDigit()
                                if let fiat = quote?.fiat(item.amount, locale: locale) {
                                    Text(verbatim: fiat).font(.caption2).foregroundStyle(WalletStyle.muted)
                                }
                                Text(item.failed ? "Failed" : item.pending ? "Pending" : "\(item.confirmations) confirmations")
                                    .font(.caption2).foregroundStyle(WalletStyle.muted)
                            }
                        }.padding(13).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if item.id != items.last?.id { Divider().overlay(WalletStyle.stroke) }
                }
            }.background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 17))
        }
    }
}

struct ActivityDetail: View {
    @Environment(\.walletMarketQuote) private var quote
    @Environment(\.locale) private var locale
    var item: WalletActivityItem
    let saveNote: (String, String) async throws -> Void
    @State private var note: String
    @State private var saving = false
    @State private var error: String?

    init(item: WalletActivityItem, saveNote: @escaping (String, String) async throws -> Void) {
        self.item = item
        self.saveNote = saveNote
        _note = State(initialValue: item.note)
    }

    var body: some View {
        WalletSheet(title: "Transaction", canDismiss: !saving) {
            Text(XMRAmount.format(item.amount) + " XMR").font(.title.bold()).monospacedDigit()
            if let fiat = quote?.fiat(item.amount, locale: locale) {
                Text(verbatim: fiat).foregroundStyle(WalletStyle.muted)
            }
            VStack(spacing: 10) {
                WalletLine(label: "Direction", value: WalletL10n.text(item.incoming ? "Received" : "Sent"))
                WalletLine(label: "Status", value: WalletL10n.text(item.failed ? "Failed" : item.pending ? "Pending" : "Confirmed"))
                WalletLine(label: "Confirmations", value: String(item.confirmations))
                WalletLine(label: "Date", value: item.date.formatted(.dateTime.locale(WalletL10n.locale).year().month().day().hour().minute()))
                if !item.incoming { WalletLine(label: "Network fee", value: XMRAmount.format(item.fee) + " XMR") }
            }
            ForEach(Array(item.recipients.enumerated()), id: \.offset) { _, address in
                WalletField(label: "Recipient") {
                    Text(verbatim: address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            WalletField(label: "Transaction note") {
                TextField("Transaction note", text: $note, axis: .vertical)
                    .lineLimit(2...8).disabled(saving)
            }
            Button("Save") {
                saving = true
                Task {
                    defer { saving = false }
                    do { try await saveNote(item.transactionHash, note); error = nil }
                    catch { self.error = WalletL10n.diagnostic(error) }
                }
            }.buttonStyle(WalletPrimaryButton()).disabled(saving || note == item.note)
            if let error { WalletNotice(text: error) }
            WalletField(label: "Transaction ID") {
                Text(item.transactionHash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}
