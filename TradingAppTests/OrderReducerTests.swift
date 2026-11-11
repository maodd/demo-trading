import Testing
import Foundation
@testable import TradingApp

struct OrderReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let btc = AssetID("BTC")
    var quote: Quote { Quote(assetID: btc, price: .dollars(100_000), quotedAt: t0) }
    let key = UUID()
    let amount = Money.dollars(50)

    private func submitting() -> OrderState {
        let review = OrderReducer.reduce(.draft, .quoted(amount: amount, quote: quote))
        return OrderReducer.reduce(review, .confirm(clientOrderID: key, now: t0.addingTimeInterval(2)))
    }

    @Test func draftToReviewToSubmitting() {
        let review = OrderReducer.reduce(.draft, .quoted(amount: amount, quote: quote))
        #expect(review == .review(amount: amount, quote: quote))
        guard case .submitting(let intent) = submitting() else { Issue.record("expected submitting"); return }
        #expect(intent.clientOrderID == key)
        #expect(intent.amount == amount)
        #expect(submitting().code == 2)
    }

    @Test func secondConfirmIsIgnored() {
        let s1 = submitting()
        let s2 = OrderReducer.reduce(s1, .confirm(clientOrderID: UUID(), now: t0.addingTimeInterval(3)))
        #expect(s2 == s1) // same intent, same key
    }

    @Test func expiryBoundaryIsExactlyTenSeconds() {
        let review = OrderState.review(amount: amount, quote: quote)
        let justBefore = OrderReducer.reduce(review, .confirm(clientOrderID: key, now: t0.addingTimeInterval(9.999)))
        #expect(justBefore.code == OrderState.submitting(justBefore.intent!).code)
        let atTen = OrderReducer.reduce(review, .confirm(clientOrderID: key, now: t0.addingTimeInterval(10)))
        #expect(atTen == .expired(amount: amount))
    }

    @Test func clockTickExpiresReviewKeepingAmount() {
        let review = OrderState.review(amount: amount, quote: quote)
        #expect(OrderReducer.reduce(review, .clockTick(now: t0.addingTimeInterval(5))) == review)
        let expired = OrderReducer.reduce(review, .clockTick(now: t0.addingTimeInterval(10)))
        #expect(expired == .expired(amount: amount))
        let fresh = Quote(assetID: btc, price: .dollars(100_100), quotedAt: t0.addingTimeInterval(10))
        #expect(OrderReducer.reduce(expired, .quoted(amount: amount, quote: fresh)) == .review(amount: amount, quote: fresh))
    }

    @Test func expiryDoesNotCancelInFlightOrder() {
        let s = submitting()
        #expect(OrderReducer.reduce(s, .clockTick(now: t0.addingTimeInterval(60))) == s)
    }

    @Test func timeoutIsUnknownNotFailed() {
        let unknown = OrderReducer.reduce(submitting(), .timedOut)
        #expect(unknown.code == 7)
        #expect(unknown.isUnresolved)
        let fill = Fill(quantity: Quantity(units: 50_000), price: .dollars(100_000), filledAt: t0)
        #expect(OrderReducer.reduce(unknown, .filled(fill)).code == 4)
        #expect(OrderReducer.reduce(unknown, .notFound) == .failed(unknown.intent!, .notPlaced))
    }

    @Test func pendingThenFilled() {
        let pending = OrderReducer.reduce(submitting(), .accepted)
        #expect(pending.code == 3)
        let fill = Fill(quantity: Quantity(units: 50_000), price: .dollars(100_000), filledAt: t0)
        #expect(OrderReducer.reduce(pending, .filled(fill)) == .filled(pending.intent!, fill))
    }

    @Test func serverQuoteExpiredReturnsToReviewFlow() {
        #expect(OrderReducer.reduce(submitting(), .failed(.quoteExpired)) == .expired(amount: amount))
    }

    @Test func illegalTransitionsAreIgnored() {
        let fill = Fill(quantity: .zero, price: .zero, filledAt: t0)
        #expect(OrderReducer.reduce(.draft, .filled(fill)) == .draft)
        #expect(OrderReducer.reduce(.draft, .confirm(clientOrderID: key, now: t0)) == .draft)
        #expect(OrderReducer.reduce(.draft, .timedOut) == .draft)
        // Reset is refused while an order may be in flight.
        let s = submitting()
        #expect(OrderReducer.reduce(s, .reset) == s)
        #expect(OrderReducer.reduce(OrderReducer.reduce(s, .timedOut), .reset).code == 7)
    }

    @Test func failedCanRetryWithFreshQuote() {
        let failed = OrderReducer.reduce(submitting(), .failed(.rejected))
        #expect(failed.code == 5)
        let fresh = Quote(assetID: btc, price: .dollars(99_000), quotedAt: t0.addingTimeInterval(30))
        #expect(OrderReducer.reduce(failed, .quoted(amount: amount, quote: fresh)) == .review(amount: amount, quote: fresh))
    }
}
