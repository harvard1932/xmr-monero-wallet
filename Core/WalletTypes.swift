import Foundation

enum WalletRestoreSource: Sendable {
    case mnemonic(String)
    case keys(address: String, view: String, spend: String?)
}

struct WalletAddress: Identifiable, Sendable {
    let id: Int
    let address: String
    let label: String
    let received: UInt64
}

struct WalletPayment: Identifiable, Sendable {
    let id: String
    let amount: UInt64
    let fee: UInt64
    let date: Date
    let incoming: Bool
    let confirmations: UInt64
    let pending: Bool
    let failed: Bool
    let subaddressIndices: [Int]
}

struct WalletSnapshot: Sendable {
    let balance: UInt64
    let unlocked: UInt64
    let height: UInt64
    let targetHeight: UInt64
    let synchronized: Bool
    let connected: Bool
    let watchOnly: Bool
    let addresses: [WalletAddress]
    let history: [WalletPayment]
}

struct WalletTransfer: Identifiable, Sendable {
    let id: UUID
    let destination: String
    let amount: UInt64
    let fee: UInt64
}

struct WalletOutput: Identifiable, Sendable {
    let id: String // Output public key
    let amount: UInt64
    let label: String
    let frozen: Bool
    let unlocked: Bool
    let subaddressIndex: Int
}

struct WalletContact: Identifiable, Sendable {
    let id: Int
    let name: String
    let address: String
}

struct WalletEngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct OfflineReview: Identifiable, Sendable {
    let id: UUID
    let summary: String
}
