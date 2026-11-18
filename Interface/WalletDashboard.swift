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
    case send, receive, contacts, invoices, coins, price, cold
    var id: Self { self }
}

struct WalletDashboard: View {
    var data: WalletPresentation
    var actions: WalletActions
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
                        ActivityList(items: data.activity, selected: { detail = $0 })
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
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { route in
            switch route {
            case .send: SendView(data: data, actions: actions)
            case .receive: ReceiveView(data: data, actions: actions)
            case .invoices: InvoiceList(data: data, actions: actions)
            case .coins: CoinList(data: data, actions: actions)
            case .cold:
                if let actions = actions.cold { ColdSigningTools(data: data, actions: actions) }
            case .price: MarketChart(allowsConnection: data.networkEnabled && !data.usesProxy)
            case .contacts:
                ContactList(data: data, actions: actions)
            }
        }
        .sheet(item: $detail) { ActivityDetail(item: $0) }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                MoneroMark().foregroundStyle(WalletStyle.apricot).frame(width: 28, height: 28)
                Text("Monero Wallet").font(.headline.weight(.bold)).tracking(-0.5)
            }
            Spacer()
            Button(action: actions.settings) {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .medium))
                    .frame(width: 43, height: 43)
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
                }.accessibilityLabel("Switch wallet, " + data.name)
            }
            balanceCard
            HStack(spacing: 10) {
                Button { sheet = .send } label: {
                    Label("Send", systemImage: "arrow.up.right")
                }.buttonStyle(WalletPrimaryButton(muted: true)).disabled(data.viewOnly && actions.cold == nil)
                Button { sheet = .receive } label: {
                    Label("Receive", systemImage: "arrow.down.left")
                }.buttonStyle(WalletPrimaryButton(muted: true))
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent activity").font(.title3.weight(.semibold)).tracking(-0.6)
                Spacer()
                Button("View all") { tab = .activity }
                    .font(.caption.weight(.semibold)).foregroundStyle(WalletStyle.apricot)
            }
            ActivityList(items: Array(data.activity.prefix(3)), selected: { detail = $0 })
        }
        if !data.synced {
            Button(action: actions.settings) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title3).foregroundStyle(WalletStyle.apricot)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(data.syncStatus).font(.subheadline.weight(.semibold))
                        Text("Node and sync settings").font(.caption).foregroundStyle(WalletStyle.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(WalletStyle.muted)
                }.padding(.horizontal, 2)
            }
        }
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
                    Text(data.network.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(0.6)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(WalletStyle.apricot.opacity(0.8), in: Capsule())
                .overlay(Capsule().strokeBorder(WalletStyle.ink.opacity(0.25)))
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(concealed ? "••••" : XMRAmount.format(data.total, minFraction: 2))
                    .font(.system(size: 46, weight: .medium)).tracking(-2.1).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.36)
                Text("XMR").font(.callout.weight(.semibold))
            }
            .padding(.vertical, 13)
            .accessibilityElement(children: .combine)
            Rectangle().fill(WalletStyle.ink.opacity(0.22)).frame(height: 1).padding(.top, 2)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 26) { breakdown }
                VStack(alignment: .leading, spacing: 6) { breakdown }
            }.padding(.top, 13)
            if let progress = data.syncProgress, !data.synced {
                ProgressView(value: max(0, min(1, progress))).tint(WalletStyle.ink).padding(.top, 12)
                    .accessibilityLabel("Sync progress")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(19)
        .foregroundStyle(WalletStyle.ink)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.60), WalletStyle.apricot], startPoint: .topLeading, endPoint: .bottomTrailing)
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

struct ActivityList: View {
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
                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(WalletStyle.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text((item.incoming ? "+" : "−") + XMRAmount.format(item.amount) + " XMR")
                                    .font(.caption.weight(.semibold)).monospacedDigit()
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
    var item: WalletActivityItem
    var body: some View {
        WalletSheet(title: "Transaction") {
            Text(XMRAmount.format(item.amount) + " XMR").font(.title.bold()).monospacedDigit()
            VStack(spacing: 10) {
                WalletLine(label: "Direction", value: item.incoming ? "Received" : "Sent")
                WalletLine(label: "Status", value: item.failed ? "Failed" : item.pending ? "Pending" : "Confirmed")
                WalletLine(label: "Confirmations", value: String(item.confirmations))
                WalletLine(label: "Date", value: item.date.formatted())
                if !item.incoming { WalletLine(label: "Network fee", value: XMRAmount.format(item.fee) + " XMR") }
            }
            WalletField(label: "Transaction ID") {
                Text(item.transactionHash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}
