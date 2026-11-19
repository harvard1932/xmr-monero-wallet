import Foundation

extension String {
    /// Map only Unicode decimal digits, keeping separators and other characters
    /// intact for the caller’s own locale and syntax checks.
    var walletASCIIDigits: String {
        var canonical = ""
        for scalar in unicodeScalars {
            if scalar.properties.generalCategory == .decimalNumber, let digit = scalar.properties.numericValue {
                canonical.append(String(Int(digit)))
            } else {
                canonical.unicodeScalars.append(scalar)
            }
        }
        return canonical
    }
}

/// UI amounts are atomic units. Decimal input and formatting never use floating-point arithmetic.
enum XMRAmount {
    static let scale: UInt64 = 1_000_000_000_000

    static func parse(_ raw: String) -> UInt64? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.components(separatedBy: ".")
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty,
              whole.utf8.allSatisfy({ (48...57).contains($0) }), let integral = UInt64(whole) else { return nil }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard fraction.utf8.count <= 12, fraction.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let (base, overflows) = integral.multipliedReportingOverflow(by: scale)
        guard !overflows, let fractional = UInt64(fraction + String(repeating: "0", count: 12 - fraction.count)) else { return nil }
        let (result, exceedsRange) = base.addingReportingOverflow(fractional)
        return exceedsRange ? nil : result
    }

    static func parseInput(_ raw: String, locale: Locale = .current) -> UInt64? {
        let separator = locale.decimalSeparator ?? "."
        let local = separator == "." ? raw : raw.replacingOccurrences(of: separator, with: ".")
        return parse(local.walletASCIIDigits)
    }

    static func format(_ atomic: UInt64, minFraction: Int = 0) -> String {
        let whole = String(atomic / scale)
        let digits = String(atomic % scale)
        var fraction = String(repeating: "0", count: 12 - digits.count) + digits
        while fraction.last == "0" && fraction.count > minFraction { fraction.removeLast() }
        return fraction.isEmpty ? whole : whole + "." + fraction
    }
}

struct WalletAddressItem: Identifiable, Equatable {
    var id: Int
    var label: String
    var address: String
}

struct WalletActivityItem: Identifiable, Equatable {
    struct ID: Hashable {
        let hash: String
        let incoming: Bool
        let subaddresses: [Int]
    }
    var id: ID { ID(hash: transactionHash, incoming: incoming, subaddresses: subaddresses) }
    var transactionHash: String
    var subaddresses: [Int]
    var incoming: Bool
    var amount: UInt64
    var date: Date
    var confirmations: UInt64
    var pending: Bool = false
    var failed: Bool = false
    var fee: UInt64 = 0
}

struct WalletCoinItem: Identifiable {
    var id: String // Output public key
    var amount: UInt64
    var frozen: Bool
    var unlocked: Bool
    var label: String = ""
    var subaddressIndex: Int = 0
}

struct WalletPresentation {
    var id: String
    var name: String
    var network: String
    var total: UInt64 = 0
    var available: UInt64 = 0
    var nodeName: String?
    var syncStatus: String = "Offline"
    var synced: Bool = false
    var syncProgress: Double? = nil
    var viewOnly: Bool = false
    var usesProxy: Bool = false
    var networkEnabled: Bool = false
    var addresses: [WalletAddressItem] = []
    var activity: [WalletActivityItem] = []
    var coins: [WalletCoinItem] = []
    var invoices: [WalletInvoiceItem] = []
    var contacts: [WalletContactItem] = []
}

struct WalletInvoiceItem: Identifiable, Codable {
    var id = UUID()
    var label: String
    var address: String
    var amount: UInt64
    var received: UInt64 = 0
}

struct WalletContactItem: Identifiable, Codable {
    var id: Int = -1
    var name: String
    var address: String
}

struct WalletSendReview {
    /// A handle to the exact prepared transaction. Never rebuild on confirmation.
    var id: String
    var address: String
    var amount: UInt64
    var fee: UInt64
}

@MainActor
struct WalletActions {
    var settings: () -> Void
    var wallets: () -> Void
    var refresh: () async -> Void
    var newAddress: (_ label: String) async throws -> WalletAddressItem
    /// Priorities follow wallet2: default 0, low 1, normal 2, high 3.
    var prepare: (_ address: String, _ amount: UInt64, _ priority: Int, _ preferredInputs: [String]) async throws -> WalletSendReview
    var submit: (_ reviewID: String) async throws -> Void
    var discard: (_ reviewID: String) async -> Void
    var freeze: (_ outputKey: String, _ frozen: Bool) async throws -> Void
    var labelOutput: (_ outputKey: String, _ label: String) async throws -> Void
    var saveContact: (WalletContactItem) async throws -> Void
    var removeContact: (Int) async throws -> Void
    /// Allocate a dedicated subaddress, persist invoice metadata, and return it.
    var createInvoice: (_ label: String, _ amount: UInt64) async throws -> WalletInvoiceItem
    var cold: WalletColdActions? = nil
}

struct WalletOfflineReview {
    var id: UUID
    var summary: String
}

@MainActor
struct WalletColdActions {
    var displayPairing: () async throws -> WalletViewPairing
    var exportOutputs: () async throws -> [String]
    var importOutputs: ([String]) async throws -> Void
    var exportKeyImages: () async throws -> [String]
    var importKeyImages: (_ frames: [String], _ trustNodeForThisImport: Bool) async throws -> Void
    var exportUnsigned: (_ reviewID: String) async throws -> [String]
    var inspectUnsigned: ([String]) async throws -> WalletOfflineReview
    var sign: (WalletOfflineReview) async throws -> [String]
    var submitSigned: ([String]) async throws -> Void
}

struct WalletViewPairing: Codable {
    let address: String
    let viewKey: String
}
