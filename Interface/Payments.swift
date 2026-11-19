import SwiftUI
import CoreImage.CIFilterBuiltins
import VisionKit
import AVFoundation

struct MoneroPaymentTarget {
    let address: String
    let amount: UInt64?

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("monero:") else {
            guard !text.contains(":"), !text.isEmpty else { throw PaymentInputError.address }
            address = text
            amount = nil
            return
        }
        guard let components = URLComponents(string: text), components.host == nil,
              components.fragment == nil, !components.path.isEmpty else { throw PaymentInputError.address }
        var requested: UInt64?
        for item in components.queryItems ?? [] {
            switch item.name {
            case "tx_amount":
                guard requested == nil, let value = item.value, let parsed = XMRAmount.parse(value),
                      parsed > 0 else { throw PaymentInputError.amount }
                requested = parsed
            case "tx_description", "recipient_name": continue
            default: throw PaymentInputError.parameter(item.name)
            }
        }
        address = components.path
        amount = requested
    }
}

private enum PaymentInputError: LocalizedError {
    case address, amount, parameter(String)
    var errorDescription: String? {
        switch self {
        case .address: "Enter a Monero address or a monero: payment request."
        case .amount: "Enter a positive XMR amount with up to 12 decimal places."
        case .parameter(let name): WalletL10n.text("This payment request includes an unsupported field (%@). Ask the recipient for a compatible address.", name)
        }
    }
}

struct WalletPaymentAuthorizationError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { WalletL10n.diagnostic(underlying) }
}

struct SendView: View {
    var data: WalletPresentation
    var actions: WalletActions
    @State private var wantsInitialScan: Bool
    @State private var destination: String
    @State private var amount = ""
    @State private var priority = 0
    @State private var preferred: Set<String> = []
    @State private var showInputs = false
    @State private var scan = false
    @State private var error: String?
    @State private var review: WalletSendReview?
    @State private var busy = false
    @State private var visible = true
    @State private var sent = false
    @State private var broadcastIssue: String?
    @State private var unsignedFrames: [String] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    init(data: WalletPresentation, actions: WalletActions, initialAddress: String = "", scanOnOpen: Bool = false) {
        _wantsInitialScan = State(initialValue: scanOnOpen)
        self.data = data
        self.actions = actions
        _destination = State(initialValue: initialAddress)
    }

    var body: some View {
        WalletSheet(title: !unsignedFrames.isEmpty ? "Unsigned transaction" : sent ? "Payment sent" : broadcastIssue != nil ? "Payment status" : review == nil ? "Send XMR" : "Review payment", canDismiss: !busy) {
            if !unsignedFrames.isEmpty {
                URFrameDisplay(frames: unsignedFrames, instructions: "On your offline signer, open Cold signing and scan the unsigned transaction.")
            } else if let broadcastIssue {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(WalletStyle.apricot)
                Text("Check your activity").font(.title.bold())
                WalletNotice(text: broadcastIssue)
                Text("Check the wallet history before preparing another payment.").foregroundStyle(WalletStyle.muted)
                Button("Back to wallet") { dismiss() }.buttonStyle(WalletPrimaryButton())
            } else if sent {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(WalletStyle.mint)
                Text("Payment submitted").font(.title.bold())
                Text("Follow confirmations in Activity.").foregroundStyle(WalletStyle.muted)
                Button("Done") { dismiss() }.buttonStyle(WalletPrimaryButton())
            } else if let review {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sending").font(.subheadline).foregroundStyle(WalletStyle.muted)
                    Text(XMRAmount.format(review.amount) + " XMR").font(.largeTitle.bold()).monospacedDigit()
                }
                WalletField(label: "Recipient address") {
                    Text(verbatim: review.address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                }
                VStack(spacing: 10) {
                    WalletLine(label: "Wallet", value: data.name)
                    WalletLine(label: "Network", value: WalletL10n.text(data.network))
                    WalletLine(label: "Network fee", value: XMRAmount.format(review.fee) + " XMR")
                    Divider()
                    let total = review.amount.addingReportingOverflow(review.fee)
                    WalletLine(label: "Total", value: total.overflow ? WalletL10n.text("Out of range") : XMRAmount.format(total.partialValue) + " XMR")
                }
                if let error { WalletNotice(text: error) }
                if data.viewOnly, let cold = actions.cold {
                    Button(busy ? "Exporting…" : "Export unsigned transaction") {
                        guard !busy else { return }
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                unsignedFrames = try await cold.exportUnsigned(review.id)
                                self.review = nil
                                error = nil
                            } catch {
                                await actions.discard(review.id)
                                self.review = nil
                                self.error = WalletL10n.diagnostic(error)
                            }
                        }
                    }.buttonStyle(WalletPrimaryButton()).disabled(busy)
                } else {
                    SwipeToSend(busy: busy) { submit(review) }
                        .disabled(busy || review.amount.addingReportingOverflow(review.fee).overflow || data.viewOnly)
                }
                Button("Edit payment") {
                    busy = true
                    Task {
                        await actions.discard(review.id)
                        self.review = nil
                        busy = false
                        error = nil
                    }
                }.frame(maxWidth: .infinity).disabled(busy)
            } else {
                WalletField(label: "Recipient") {
                    TextField("Address or payment request", text: $destination, axis: .vertical)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(2...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                }
                HStack(spacing: 20) {
                    Button { openScanner() } label: { Label("Scan QR", systemImage: "qrcode.viewfinder") }
                    if !data.contacts.isEmpty {
                        Menu {
                            ForEach(data.contacts) { contact in
                                Button(contact.name) { destination = contact.address }
                            }
                        } label: { Label("Contacts", systemImage: "person.crop.circle") }
                    }
                }.font(.subheadline)
                WalletField(label: "Amount in XMR") {
                    TextField("0.00", text: $amount).keyboardType(.decimalPad).font(.title2.monospacedDigit())
                }
                WalletLine(label: "Available", value: XMRAmount.format(data.available) + " XMR")
                HStack {
                    Text("Fee priority")
                    Spacer()
                    Picker("Fee priority", selection: $priority) {
                        Text("Automatic").tag(0)
                        Text("Low").tag(1)
                        Text("Normal").tag(2)
                        Text("High").tag(3)
                    }.labelsHidden()
                }
                if !data.coins.isEmpty {
                    DisclosureGroup(isExpanded: $showInputs) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Leave all outputs unselected to let the wallet choose.").font(.caption).foregroundStyle(WalletStyle.muted)
                            Menu {
                                Button("Automatic inputs") { preferred = [] }
                                ForEach(data.addresses.filter { address in
                                    spendableCoins.contains { $0.subaddressIndex == address.id }
                                }) { address in
                                    Button(address.label.isEmpty ? WalletL10n.text("Subaddress %lld", Int64(address.id)) : address.label) {
                                        preferred = Set(spendableCoins.filter { $0.subaddressIndex == address.id }.map(\.id))
                                    }
                                }
                            } label: { Label("Prefer outputs from a subaddress", systemImage: "rectangle.stack") }
                            ForEach(spendableCoins) { coin in
                                Button {
                                    if preferred.contains(coin.id) { preferred.remove(coin.id) } else { preferred.insert(coin.id) }
                                } label: {
                                    HStack {
                                        Image(systemName: preferred.contains(coin.id) ? "checkmark.circle.fill" : "circle")
                                        VStack(alignment: .leading) {
                                            Text(XMRAmount.format(coin.amount) + " XMR")
                                            Text(coin.label.isEmpty ? abbreviatedAddress(coin.id) : coin.label)
                                                .font(.caption).foregroundStyle(WalletStyle.muted)
                                        }
                                        Spacer()
                                    }.padding(.vertical, 5)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.top, 10)
                    } label: { Text("Preferred inputs").foregroundStyle(WalletStyle.text) }
                }
                if let error { WalletNotice(text: error) }
                Button(busy ? "Preparing…" : "Review payment") { prepare() }
                    .buttonStyle(WalletPrimaryButton())
                    .disabled(busy || destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (data.viewOnly && actions.cold == nil))
            }
        }
        .sheet(isPresented: $scan) {
            ZStack(alignment: .topTrailing) {
                WalletQRScanner { result in
                    scan = false
                    switch result {
                    case .success(let payload):
                        do {
                            let target = try MoneroPaymentTarget(payload)
                            destination = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let invoiceAmount = target.amount { amount = XMRAmount.format(invoiceAmount) }
                            error = nil
                        } catch { self.error = WalletL10n.diagnostic(error) }
                    case .failure(let failure): error = WalletL10n.diagnostic(failure)
                    }
                    return true
                }
                Button("Close") { scan = false }.buttonStyle(.borderedProminent).padding()
            }.preferredColorScheme(.dark)
        }
        .onAppear {
            visible = true
            if wantsInitialScan { wantsInitialScan = false; openScanner() }
        }
        .onDisappear {
            visible = false
            if let review, !busy { Task { await actions.discard(review.id) } }
        }
    }

    private var spendableCoins: [WalletCoinItem] {
        data.coins.filter { $0.unlocked && !$0.frozen }
    }

    private func openScanner() {
        Task {
            guard DataScannerViewController.isSupported, await AVCaptureDevice.requestAccess(for: .video),
                  DataScannerViewController.isAvailable else {
                error = "QR scanning needs camera access on a supported iPhone. You can also paste the address."
                return
            }
            scan = true
        }
    }

    private func prepare() {
        guard !busy else { return }
        error = nil
        do {
            let target = try MoneroPaymentTarget(destination)
            let entered = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = entered.isEmpty ? target.amount : XMRAmount.parseInput(entered, locale: locale)
            guard let parsed, parsed > 0 else { throw PaymentInputError.amount }
            if let invoiceAmount = target.amount, invoiceAmount != parsed {
                error = "The amount differs from the payment request. Check the request before continuing."
                return
            }
            busy = true
            Task {
                defer { busy = false }
                do {
                    let prepared = try await actions.prepare(target.address, parsed, priority, preferred.sorted())
                    if visible { review = prepared } else { await actions.discard(prepared.id) }
                } catch { self.error = WalletL10n.diagnostic(error) }
            }
        } catch { self.error = WalletL10n.diagnostic(error) }
    }

    private func submit(_ prepared: WalletSendReview) {
        guard visible, !busy, review?.id == prepared.id, broadcastIssue == nil, !sent else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await actions.submit(prepared.id)
                review = nil
                sent = true
            } catch let failure as WalletPaymentAuthorizationError {
                // Authentication happens before broadcasting. The same reviewed
                // payment remains available if its owner cancels the PIN prompt.
                if !(failure.underlying is CancellationError) { error = failure.localizedDescription }
            } catch {
                await actions.discard(prepared.id)
                review = nil
                destination = ""
                amount = ""
                broadcastIssue = WalletL10n.diagnostic(error)
            }
        }
    }
}

private struct SwipeToSend: View {
    var busy: Bool
    var action: () -> Void
    @State private var offset: CGFloat = 0
    @Environment(\.layoutDirection) private var layoutDirection
    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.width - 57)
            let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
            ZStack(alignment: .leading) {
                Capsule().fill(WalletStyle.apricot.opacity(0.13))
                Text(busy ? "Sending…" : "Slide to send").font(.headline)
                    .foregroundStyle(WalletStyle.apricot).frame(maxWidth: .infinity).opacity(1 - 0.8 * offset / travel)
                Image(systemName: "arrow.forward").font(.headline)
                    .foregroundStyle(WalletStyle.ink).frame(width: 46, height: 46)
                    .background(WalletStyle.apricot, in: Circle()).padding(5).offset(x: direction * offset)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { offset = min(travel, max(0, direction * $0.translation.width)) }
                        .onEnded { _ in
                            if offset >= travel * 0.92 { action() }
                            withAnimation(.easeOut(duration: 0.15)) { offset = 0 }
                        })
            }
        }
        .frame(height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confirm and send payment").accessibilityAddTraits(.isButton).accessibilityAction { action() }
    }
}

struct PaymentQR: View {
    var payload: String
    private static let context = CIContext()
    var body: some View {
        Group {
            if let qrImage {
                Image(decorative: qrImage, scale: 1).interpolation(.none).resizable().scaledToFit()
                    .padding(16).background(.white).clipShape(RoundedRectangle(cornerRadius: 11))
            } else { WalletNotice(text: "QR code unavailable. Use the address below.") }
        }.frame(maxWidth: 230).frame(maxWidth: .infinity).accessibilityLabel("Monero payment QR code")
    }

    private var qrImage: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        return Self.context.createCGImage(image, from: image.extent)
    }
}

struct ReceiveView: View {
    var data: WalletPresentation
    var actions: WalletActions
    @State private var selectedID: Int?
    @State private var creating = false
    @State private var label = ""
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    private var selected: WalletAddressItem? {
        data.addresses.first(where: { $0.id == selectedID }) ?? data.addresses.first
    }
    var body: some View {
        WalletSheet(title: "Receive XMR") {
            if let selected {
                if data.addresses.count > 1 {
                    Picker("Receive address", selection: Binding(get: { selected.id }, set: { selectedID = $0; copied = false })) {
                        ForEach(data.addresses) { entry in Text(name(entry)).tag(entry.id) }
                    }.pickerStyle(.menu)
                } else { Text(name(selected)).font(.headline) }
                PaymentQR(payload: selected.address)
                WalletField(label: "Address · \(WalletL10n.text(data.network))") {
                    Text(verbatim: selected.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                }
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": selected.address]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(WalletPrimaryButton(muted: true))
                    ShareLink(item: selected.address) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(WalletPrimaryButton(muted: true))
                }
            }
            if creating {
                WalletField(label: "New subaddress label") {
                    TextField("e.g. Personal", text: $label)
                }
                Button(busy ? "Creating…" : "Create subaddress") {
                    guard !busy else { return }
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let item = try await actions.newAddress(label.trimmingCharacters(in: .whitespacesAndNewlines))
                            selectedID = item.id
                            copied = false
                            label = ""
                            creating = false
                            error = nil
                        } catch { self.error = WalletL10n.diagnostic(error) }
                    }
                }.buttonStyle(WalletPrimaryButton()).disabled(busy)
            } else {
                Button { creating = true } label: { Label("New subaddress", systemImage: "plus") }
                    .buttonStyle(WalletPrimaryButton())
            }
            if let error { WalletNotice(text: error) }
        }
    }

    private func name(_ address: WalletAddressItem) -> String {
        if !address.label.isEmpty {
            return address.id == 0 && address.label == "Primary account" ? WalletL10n.text("Primary account") : address.label
        }
        return address.id == 0 ? WalletL10n.text("Primary address") : WalletL10n.text("Subaddress %lld", Int64(address.id))
    }
}

@MainActor
struct WalletQRScanner: UIViewControllerRepresentable {
    var onResult: (Result<String, Error>) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        Task { @MainActor in
            do { try scanner.startScanning() } catch { _ = context.coordinator.report(.failure(error)) }
        }
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onResult: ((Result<String, Error>) -> Bool)?
        init(onResult: @escaping (Result<String, Error>) -> Bool) { self.onResult = onResult }
        func report(_ result: Result<String, Error>) -> Bool {
            let finished = onResult?(result) ?? true
            if finished { onResult = nil }
            return finished
        }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            receive(addedItems, scanner: scanner)
        }
        func dataScanner(_ scanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            receive(updatedItems, scanner: scanner)
        }
        private func receive(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            for item in items {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    if report(.success(value)) { scanner.stopScanning(); break }
                }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            _ = report(.failure(error))
        }
    }
}
