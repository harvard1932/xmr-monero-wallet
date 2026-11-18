import XCTest
@testable import XMRMoneroWallet

final class PaymentInputTests: XCTestCase {
    func testAtomicAmountBoundariesRoundTripWithoutRounding() {
        for input: UInt64 in [0, 1, 999_999_999_999, XMRAmount.scale, UInt64.max - 1, UInt64.max] {
            XCTAssertEqual(XMRAmount.parse(XMRAmount.format(input)), input)
        }
        XCTAssertNil(XMRAmount.parse("18446744.073709551616"))
        XCTAssertNil(XMRAmount.parse("0.0000000000001"))
        XCTAssertNil(XMRAmount.parse("-1"))
        XCTAssertNil(XMRAmount.parse("1e-12"))
        XCTAssertEqual(XMRAmount.format(1), "0.000000000001")
    }

    func testLocalizedDecimalInputRejectsAmbiguousGrouping() {
        XCTAssertEqual(XMRAmount.parseInput("0,1", locale: Locale(identifier: "de_DE")), 100_000_000_000)
        XCTAssertNil(XMRAmount.parseInput("1,000", locale: Locale(identifier: "en_US")))
        XCTAssertNil(XMRAmount.parseInput("1.000,50", locale: Locale(identifier: "de_DE")))
    }

    func testPaymentRequestKeepsExactAmount() throws {
        let target = try MoneroPaymentTarget("monero:wallet-address?tx_amount=0.000000000001&recipient_name=Shop")
        XCTAssertEqual(target.address, "wallet-address")
        XCTAssertEqual(target.amount, 1)
        XCTAssertNil(try MoneroPaymentTarget("wallet-address").amount)
    }

    func testUnsupportedOrAmbiguousRequestsAreRejected() {
        for value in [
            "monero:addr?tx_payment_id=01", "monero:addr?tx_amount=1&tx_amount=2",
            "monero:addr?tx_amount=0.0000000000001", "monero:addr?tx_amount=0",
            "monero://host/address", "monero:addr#other", "https://example.com/address"
        ] {
            XCTAssertThrowsError(try MoneroPaymentTarget(value), value)
        }
    }

    func testQRCollectionOrdersAndDeduplicatesFrames() throws {
        var collector = URFrameCollector(kind: "xmr-output")
        XCTAssertNil(try collector.insert("UR:XMR-OUTPUT/2-2/BB"))
        XCTAssertNil(try collector.insert("ur:xmr-output/2-2/bb"))
        XCTAssertEqual(collector.count, 1)
        XCTAssertEqual(try collector.insert("ur:xmr-output/1-2/aa"),
                       ["ur:xmr-output/1-2/aa", "ur:xmr-output/2-2/bb"])
    }

    func testQRCollectionRejectsWrongTypeConflictsAndOversizedSequences() throws {
        var collector = URFrameCollector(kind: "xmr-output")
        XCTAssertThrowsError(try collector.insert("ur:xmr-txsigned/aa"))
        XCTAssertThrowsError(try collector.insert("ur:xmr-output/1-10001/aa"))
        XCTAssertNil(try collector.insert("ur:xmr-output/1-2/aa"))
        XCTAssertThrowsError(try collector.insert("ur:xmr-output/1-2/bb"))
        XCTAssertThrowsError(try collector.insert("ur:xmr-output/2-3/cc"))
    }
}
