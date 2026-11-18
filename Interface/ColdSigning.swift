import SwiftUI
import AVFoundation
import VisionKit

private enum ColdInput: String, Identifiable {
    case outputs = "xmr-output", images = "xmr-keyimage", unsigned = "xmr-txunsigned", signed = "xmr-txsigned"
    var id: Self { self }
    var label: String {
        switch self {
        case .outputs: "wallet outputs"
        case .images: "key images"
        case .unsigned: "unsigned transaction"
        case .signed: "signed transaction"
        }
    }
}

struct URInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Collects the systematic fragments produced by wallet2. Full CBOR and UR
/// integrity checks run in the native engine after this transport-level check.
struct URFrameCollector {
    let kind: String
    private(set) var expected = 0
    private(set) var count = 0
    private var size = 0
    private var parts: [Int: String] = [:]

    init(kind: String) { self.kind = kind }

    mutating func insert(_ frame: String) throws -> [String]? {
        guard frame.utf8.count <= 4096 else { throw URInputError("This QR frame is too large.") }
        let text = frame.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fields = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count), fields.first == "ur:" + kind, fields.last?.isEmpty == false,
              fields.last?.utf8.allSatisfy({ (97...122).contains($0) }) == true else {
            throw URInputError("Scan a " + kind + " QR code.")
        }
        var index = 1
        var total = 1
        if fields.count == 3 {
            let seq = fields[1].split(separator: "-", omittingEmptySubsequences: false)
            guard seq.count == 2, let n = Int(seq[0]), let t = Int(seq[1]),
                  (1...10000).contains(t), (1...t).contains(n) else { throw URInputError("Invalid QR frame sequence.") }
            index = n
            total = t
        }
        guard expected == 0 || expected == total else { throw URInputError("These frames belong to different transfers. Start a new scan.") }
        expected = total
        if let seen = parts[index] {
            guard seen == text else { throw URInputError("Conflicting QR frames. Restart with one transfer.") }
        } else {
            guard size + text.utf8.count <= 4 * 1024 * 1024 else { throw URInputError("This transfer exceeds the frame size limit.") }
            parts[index] = text
            size += text.utf8.count
            count += 1
        }
        return count == expected ? (1...expected).compactMap { parts[$0] } : nil
    }
}

struct URFrameDisplay: View {
    let frames: [String]
    let instructions: String
    @State private var index = 0
    @State private var playing = false
    var body: some View {
        if frames.isEmpty {
            WalletNotice(text: "The wallet returned no QR frames.")
        } else {
            Text(instructions).font(.subheadline).foregroundStyle(WalletStyle.muted)
            PaymentQR(payload: frames[index % frames.count].uppercased())
            if frames.count > 1 {
                WalletLine(label: "Frame", value: "\(index + 1) / \(frames.count)")
                HStack {
                    Button { playing = false; index = (index + frames.count - 1) % frames.count } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    Spacer()
                    Button { playing.toggle() } label: {
                        Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                    }
                    Spacer()
                    Button { playing = false; index = (index + 1) % frames.count } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                }
                .task(id: playing) {
                    guard playing else { return }
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
                        index = (index + 1) % frames.count
                    }
                }
            }
        }
    }
}

private struct ColdFrameReader: View {
    var kind: ColdInput
    var deliver: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera = false
    @State private var collector: URFrameCollector
    @State private var error: String?

    init(kind: ColdInput, deliver: @escaping ([String]) -> Void) {
        self.kind = kind
        self.deliver = deliver
        _collector = State(initialValue: URFrameCollector(kind: kind.rawValue))
    }
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Text("Scan " + kind.label).font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            if camera {
                WalletQRScanner { result in
                    do {
                        if let frames = try collector.insert(try result.get()) {
                            deliver(frames)
                            dismiss()
                            return true
                        }
                        error = nil
                        return false
                    } catch {
                        self.error = error.localizedDescription
                        camera = false
                        return true
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 18))
                if collector.expected > 0 {
                    ProgressView(value: Double(collector.count), total: Double(collector.expected))
                    Text("\(collector.count) of \(collector.expected) frames").font(.caption.monospacedDigit())
                }
            } else {
                Spacer()
                Image(systemName: "qrcode.viewfinder").font(.system(size: 55)).foregroundStyle(WalletStyle.apricot)
                Text("Point your camera at the " + kind.label + " QR code on the other device.").multilineTextAlignment(.center)
                if let error { WalletNotice(text: error) }
                Spacer()
                Button("Start scan") {
                    Task {
                        guard await cameraAvailable() else {
                            error = "The camera is unavailable. Check camera permissions on this iPhone."
                            return
                        }
                        collector = URFrameCollector(kind: kind.rawValue)
                        error = nil
                        camera = true
                    }
                }.buttonStyle(WalletPrimaryButton())
            }
        }.padding(20).background(WalletStyle.ink).foregroundStyle(WalletStyle.text).preferredColorScheme(.dark)
    }
}

@MainActor
private func cameraAvailable() async -> Bool {
    guard DataScannerViewController.isSupported, await AVCaptureDevice.requestAccess(for: .video) else { return false }
    return DataScannerViewController.isAvailable
}

/// An app-specific pairing payload contains only public address and private view key.
private struct PairPayload: Codable {
    static let format = "xmr-wallet-view-pair-v1"
    let type: String
    let address: String
    let viewKey: String

    init(pairing: WalletViewPairing) {
        type = Self.format
        address = pairing.address
        viewKey = pairing.viewKey
    }

    static func decode(_ input: String) throws -> WalletViewPairing {
        guard input.utf8.count < 1024,
              let payload = try? JSONDecoder().decode(Self.self, from: Data(input.utf8)),
              payload.type == Self.format, [95,106].contains(payload.address.utf8.count),
              payload.address.utf8.allSatisfy({ "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8.contains($0) }),
              payload.viewKey.count == 64, payload.viewKey.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { throw URInputError("Scan a view-only pairing code from this app.") }
        return WalletViewPairing(address: payload.address, viewKey: payload.viewKey)
    }
}

struct PairingQRImportButton: View {
    var onPair: (WalletViewPairing) -> Void
    @State private var scan = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    if await cameraAvailable() { error = nil; scan = true }
                    else { error = "The camera is unavailable. Enter the address and private view key manually." }
                }
            } label: { Label("Scan view-only pairing QR", systemImage: "qrcode.viewfinder") }
            if let error { WalletNotice(text: error) }
        }
        .sheet(isPresented: $scan) {
            ZStack(alignment: .topTrailing) {
                WalletQRScanner { result in
                    do { onPair(try PairPayload.decode(try result.get())) }
                    catch { self.error = error.localizedDescription }
                    scan = false
                    return true
                }
                Button("Close") { scan = false }.buttonStyle(.borderedProminent).padding()
            }
        }
    }
}

struct ColdSigningTools: View {
    var data: WalletPresentation
    var actions: WalletColdActions
    @State private var activeScan: ColdInput?
    @State private var collected: [String] = []
    @State private var scannedKind: ColdInput?
    @State private var frames: [String] = []
    @State private var instructions = ""
    @State private var review: WalletOfflineReview?
    @State private var pairText: String?
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var trustNode = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WalletSheet(title: "Cold signing", canDismiss: !busy) {
            if let pairText {
                Text("Scan this code from the view-only restore screen on your online device. Anyone with this code can see incoming payments.")
                    .font(.subheadline).foregroundStyle(WalletStyle.muted)
                PaymentQR(payload: pairText).privacySensitive()
                Button("Hide pairing code") { self.pairText = nil }.buttonStyle(WalletPrimaryButton())
            } else if !frames.isEmpty {
                URFrameDisplay(frames: frames, instructions: instructions)
                Button("Done") { frames = []; instructions = "" }.buttonStyle(WalletPrimaryButton(muted: true))
            } else if let review {
                Text("Review on this device").font(.title2.bold())
                Text("Check every destination, amount and fee before signing.").foregroundStyle(WalletStyle.muted)
                Text(review.summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button(busy ? "Signing…" : "Sign this transaction") {
                    run {
                        self.review = nil
                        let signed = try await actions.sign(review)
                        display(signed, "Scan the signed transaction into the online view-only wallet.")
                    }
                }.buttonStyle(WalletPrimaryButton()).disabled(busy || data.networkEnabled)
                Button("Cancel") { self.review = nil }.disabled(busy)
            } else if let scannedKind {
                Text("Scanned " + scannedKind.label).font(.title2.bold())
                if scannedKind == .images {
                    Toggle("Trust this node for this import", isOn: $trustNode)
                    Text("Importing key images lets the connected node link spent outputs in this wallet. Use a node you control.")
                        .font(.footnote).foregroundStyle(WalletStyle.muted)
                } else if scannedKind == .signed {
                    Text("Broadcast this signed transaction on " + data.network + " using the online wallet. Confirm you reviewed it on the signer.")
                        .foregroundStyle(WalletStyle.muted)
                }
                Button(buttonFor(scannedKind)) { apply(scannedKind) }.buttonStyle(WalletPrimaryButton())
                    .disabled(busy || (scannedKind == .images && !trustNode))
                Button("Cancel") { clearImport() }.disabled(busy)
            } else if data.viewOnly {
                Text("Online view-only wallet").font(.title2.bold())
                Text("Sync outputs and key images with the offline signer before building a payment in Send.")
                    .font(.subheadline).foregroundStyle(WalletStyle.muted)
                taskButton("Export outputs", "qrcode") {
                    run { display(try await actions.exportOutputs(), "Import these outputs into the matching offline signer.") }
                }
                taskButton("Import key images", "qrcode.viewfinder") { activeScan = .images }
                taskButton("Broadcast signed transaction", "paperplane") { activeScan = .signed }
            } else {
                Text("Offline signer").font(.title2.bold())
                if data.networkEnabled {
                    Text("Choose Offline in node settings before using this wallet as a signer.").foregroundStyle(WalletStyle.muted)
                } else {
                    Text("Pair with a view-only wallet, import its outputs, then return key images. Review and sign its payment requests here.")
                        .font(.subheadline).foregroundStyle(WalletStyle.muted)
                    taskButton("Show view-only pairing code", "person.badge.key") {
                        run {
                            let pairing = try await actions.displayPairing()
                            pairText = String(decoding: try JSONEncoder().encode(PairPayload(pairing: pairing)), as: UTF8.self)
                        }
                    }
                    taskButton("Import outputs", "qrcode.viewfinder") { activeScan = .outputs }
                    taskButton("Export key images", "qrcode") {
                        run { display(try await actions.exportKeyImages(), "Import these key images into the matching online view-only wallet.") }
                    }
                    taskButton("Scan unsigned transaction", "signature") { activeScan = .unsigned }
                }
            }
            if let status { Label(status, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(WalletStyle.mint) }
            if let error { WalletNotice(text: error) }
            if busy { ProgressView() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                pairText = nil
                frames = []
                review = nil
                activeScan = nil
                clearImport()
            }
        }
        .sheet(item: $activeScan) { kind in
            ColdFrameReader(kind: kind) { result in
                collected = result
                scannedKind = kind
                status = nil
                error = nil
            }
        }
    }

    private func buttonFor(_ kind: ColdInput) -> String {
        switch kind {
        case .outputs: "Import outputs"
        case .images: "Import key images"
        case .unsigned: "Inspect transaction"
        case .signed: "Confirm broadcast"
        }
    }

    private func taskButton(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }.buttonStyle(WalletPrimaryButton(muted: true)).disabled(busy)
    }

    private func display(_ payload: [String], _ prompt: String) {
        frames = payload
        instructions = prompt
    }

    private func clearImport() {
        collected = []
        scannedKind = nil
        trustNode = false
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        status = nil
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }

    private func apply(_ kind: ColdInput) {
        run {
            switch kind {
            case .outputs: try await actions.importOutputs(collected); status = "Outputs imported."
            case .images: try await actions.importKeyImages(collected, trustNode); status = "Key images imported."
            case .unsigned: review = try await actions.inspectUnsigned(collected)
            case .signed:
                // A timeout can occur after broadcast. Consume the scanned payload
                // for every submit attempt so another send requires a new scan.
                let signed = collected
                clearImport()
                try await actions.submitSigned(signed)
                status = "Signed transaction submitted."
            }
            clearImport()
        }
    }
}
