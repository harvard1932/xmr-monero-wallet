import SwiftUI

struct InvoiceList: View {
    var data: WalletPresentation
    var actions: WalletActions
    @State private var label = ""
    @State private var amount = ""
    @State private var creating = false
    @State private var busy = false
    @State private var selected: WalletInvoiceItem?
    @State private var error: String?

    var body: some View {
        WalletSheet(title: "Payment requests") {
            if creating {
                WalletField(label: "Invoice label") { TextField("e.g. Studio rent", text: $label) }
                WalletField(label: "Amount in XMR") {
                    TextField("0.00", text: $amount).keyboardType(.decimalPad)
                }
                Text("Each request uses its own subaddress to track the amount received.")
                    .font(.footnote).foregroundStyle(WalletStyle.muted)
                Button(busy ? "Creating…" : "Create request") { create() }
                    .buttonStyle(WalletPrimaryButton()).disabled(busy)
                Button("Cancel") { creating = false; error = nil }.disabled(busy)
            } else {
                Button { creating = true } label: { Label("New request", systemImage: "plus") }
                    .buttonStyle(WalletPrimaryButton())
                if data.invoices.isEmpty {
                    ContentUnavailableView("No payment requests", systemImage: "qrcode",
                        description: Text("Create an invoice to request an exact amount of XMR."))
                } else {
                    ForEach(data.invoices) { invoice in
                        Button { selected = invoice } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(invoice.label).font(.headline)
                                    Text(invoiceStatus(invoice)).font(.caption).foregroundStyle(WalletStyle.muted)
                                }
                                Spacer()
                                Text(XMRAmount.format(invoice.amount) + " XMR").font(.subheadline.monospacedDigit())
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(15).background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let error { WalletNotice(text: error) }
        }
        .sheet(item: $selected) { selection in
            invoiceDetail(data.invoices.first { $0.id == selection.id } ?? selection)
        }
    }

    private func create() {
        guard !busy else { return }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let parsed = XMRAmount.parseInput(amount), parsed > 0 else {
            error = "Enter a label and a positive XMR amount with up to 12 decimal places."
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let invoice = try await actions.createInvoice(name, parsed)
                creating = false
                amount = ""
                label = ""
                error = nil
                selected = invoice
            } catch { self.error = error.localizedDescription }
        }
    }

    private func invoiceStatus(_ invoice: WalletInvoiceItem) -> String {
        invoice.received >= invoice.amount ? "Paid" : invoice.received > 0 ? "Partially paid" : "Awaiting payment"
    }

    private func invoiceDetail(_ invoice: WalletInvoiceItem) -> some View {
        let uri = "monero:" + invoice.address + "?tx_amount=" + XMRAmount.format(invoice.amount)
        return WalletSheet(title: "\(invoice.label)") {
            Text(XMRAmount.format(invoice.amount) + " XMR").font(.largeTitle.bold()).monospacedDigit()
            PaymentQR(payload: uri)
            WalletLine(label: "Status", value: invoiceStatus(invoice))
            WalletLine(label: "Received", value: XMRAmount.format(invoice.received) + " XMR")
            WalletField(label: "Dedicated subaddress") {
                Text(invoice.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            ShareLink(item: uri) { Label("Share request", systemImage: "square.and.arrow.up") }
                .buttonStyle(WalletPrimaryButton())
        }
    }
}

struct CoinList: View {
    var data: WalletPresentation
    var actions: WalletActions
    @State private var error: String?
    @State private var busy = false
    @State private var selected: WalletCoinItem?
    @State private var label = ""

    var body: some View {
        WalletSheet(title: "Coin control") {
            Text("Frozen outputs stay unavailable for spending until you thaw them.")
                .font(.subheadline).foregroundStyle(WalletStyle.muted)
            if data.coins.isEmpty {
                ContentUnavailableView("No unspent outputs", systemImage: "square.stack.3d.up",
                    description: Text("Outputs appear here when your wallet receives XMR."))
            }
            ForEach(data.coins) { coin in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(XMRAmount.format(coin.amount) + " XMR").font(.headline.monospacedDigit())
                        Spacer()
                        Text(coin.frozen ? "Frozen" : coin.unlocked ? "Available" : "Locked")
                            .font(.caption).foregroundStyle(coin.frozen ? WalletStyle.apricot : WalletStyle.muted)
                    }
                    if !coin.label.isEmpty { Text(coin.label).font(.subheadline) }
                    Text(coin.id).font(.system(.caption2, design: .monospaced)).foregroundStyle(WalletStyle.muted).textSelection(.enabled)
                    HStack(spacing: 20) {
                        Button { label = coin.label; selected = coin } label: { Label("Label", systemImage: "tag") }
                        Button { setFrozen(coin) } label: {
                            Label(coin.frozen ? "Thaw" : "Freeze", systemImage: coin.frozen ? "sun.max" : "snowflake")
                        }
                    }.font(.subheadline).disabled(busy)
                }.padding(15).background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 14))
            }
            if let error { WalletNotice(text: error) }
        }
        .alert("Output label", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            TextField("Label", text: $label)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let coin = selected else { return }
                busy = true
                Task {
                    defer { busy = false }
                    do { try await actions.labelOutput(coin.id, label); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func setFrozen(_ coin: WalletCoinItem) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await actions.freeze(coin.id, !coin.frozen); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ContactList: View {
    var data: WalletPresentation
    var actions: WalletActions
    @State private var adding = false
    @State private var busy = false
    @State private var name = ""
    @State private var address = ""
    @State private var remove: WalletContactItem?
    @State private var sendTo: WalletContactItem?
    @State private var error: String?

    var body: some View {
        WalletSheet(title: "Contacts") {
            if adding {
                WalletField(label: "Name") { TextField("Contact name", text: $name) }
                WalletField(label: "Monero address") {
                    TextField("Address", text: $address, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.callout, design: .monospaced))
                }
                Button(busy ? "Saving…" : "Save contact") { save() }
                    .buttonStyle(WalletPrimaryButton()).disabled(busy)
                Button("Cancel") { adding = false; error = nil }.disabled(busy)
            } else {
                Button { adding = true } label: { Label("New contact", systemImage: "plus") }
                    .buttonStyle(WalletPrimaryButton())
                if data.contacts.isEmpty {
                    ContentUnavailableView("No contacts", systemImage: "person.crop.rectangle.stack",
                        description: Text("Save a name and Monero address to use when sending."))
                }
                ForEach(data.contacts) { contact in
                    VStack(alignment: .leading, spacing: 11) {
                        Text(contact.name).font(.headline)
                        Text(contact.address).textSelection(.enabled).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(WalletStyle.muted)
                        HStack {
                            Button { sendTo = contact } label: { Label("Send", systemImage: "arrow.up.right") }
                                .disabled(data.viewOnly && actions.cold == nil)
                            Spacer()
                            Button("Remove", role: .destructive) { remove = contact }.disabled(busy)
                        }.font(.subheadline)
                    }.padding(15).background(WalletStyle.dusk, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            if let error { WalletNotice(text: error) }
        }
        .sheet(item: $sendTo) { contact in SendView(data: data, actions: actions, initialAddress: contact.address) }
        .confirmationDialog("Remove this contact?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), presenting: remove) { contact in
            Button("Remove " + contact.name, role: .destructive) {
                guard !busy else { return }
                busy = true
                Task {
                    defer { busy = false }
                    do { try await actions.removeContact(contact.id); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func save() {
        guard !busy else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !address.isEmpty else { error = "Enter the contact’s name and address."; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await actions.saveContact(.init(name: name, address: address))
                error = nil
                self.address = ""
                self.name = ""
                adding = false
            } catch { self.error = error.localizedDescription }
        }
    }
}
