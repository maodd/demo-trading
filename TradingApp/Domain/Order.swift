import Foundation

struct PriceTick: Equatable, Sendable {
    let assetID: AssetID
    let price: Money
    let timestamp: Date
}

/// A price the user is shown on Review. Valid for 10 seconds (PLAN.md §2).
struct Quote: Equatable, Sendable {
    static let validity: TimeInterval = 10

    let assetID: AssetID
    let price: Money
    let quotedAt: Date

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(quotedAt) >= Quote.validity
    }

    func secondsRemaining(now: Date) -> Int {
        max(0, Int((Quote.validity - now.timeIntervalSince(quotedAt)).rounded(.up)))
    }
}

/// One user intent to buy. `clientOrderID` is the idempotency key, generated once at Confirm.
struct OrderIntent: Equatable, Sendable, Identifiable {
    let clientOrderID: UUID
    let assetID: AssetID
    let amount: Money
    let quote: Quote

    var id: UUID { clientOrderID }
    var estimatedQuantity: Quantity { Quantity.forAmount(amount, at: quote.price) ?? .zero }
}

struct Fill: Equatable, Sendable {
    let quantity: Quantity
    let price: Money
    let filledAt: Date
}

/// Reasons where the outcome is DEFINITE: no order was placed.
enum FailureReason: Equatable, Sendable {
    case rejected
    case serverError
    case insufficientFunds
    case offline
    case quoteExpired
    case notPlaced

    var message: String {
        switch self {
        case .rejected: "The order was rejected by the exchange."
        case .serverError: "Our servers had a problem before your order was processed."
        case .insufficientFunds: "Insufficient funds."
        case .offline: "You're offline."
        case .quoteExpired: "The price expired."
        case .notPlaced: "The connection dropped before your order reached us."
        }
    }
}

/// Order state machine (PLAN.md §3–4). `code` gives the stable Int for logging/persistence.
enum OrderState: Equatable, Sendable {
    case draft
    case review(amount: Money, quote: Quote)
    case submitting(OrderIntent)
    case pending(OrderIntent)
    case filled(OrderIntent, Fill)
    case failed(OrderIntent, FailureReason)
    case expired(amount: Money)
    case unknown(OrderIntent)

    var code: Int {
        switch self {
        case .draft: 0
        case .review: 1
        case .submitting: 2
        case .pending: 3
        case .filled: 4
        case .failed: 5
        case .expired: 6
        case .unknown: 7
        }
    }

    var intent: OrderIntent? {
        switch self {
        case .submitting(let i), .pending(let i), .unknown(let i), .filled(let i, _), .failed(let i, _): i
        case .draft, .review, .expired: nil
        }
    }

    /// An order may exist server-side and is not settled yet: Buy is blocked for the asset.
    var isUnresolved: Bool {
        switch self {
        case .submitting, .pending, .unknown: true
        default: false
        }
    }
}

enum OrderEvent: Equatable, Sendable {
    case quoted(amount: Money, quote: Quote)
    case confirm(clientOrderID: UUID, now: Date)
    case clockTick(now: Date)
    case accepted
    case filled(Fill)
    case failed(FailureReason)
    case timedOut
    case notFound
    case reset
}

/// Pure transition function. Illegal events return the state unchanged.
enum OrderReducer {
    static func reduce(_ state: OrderState, _ event: OrderEvent) -> OrderState {
        switch (state, event) {

        // Getting a (fresh) quote: from draft, review (auto-refresh), expired, or a definite failure.
        case (.draft, .quoted(let amount, let quote)),
             (.review, .quoted(let amount, let quote)),
             (.expired, .quoted(let amount, let quote)),
             (.failed, .quoted(let amount, let quote)):
            return .review(amount: amount, quote: quote)

        // Confirm is ONLY legal from review. A second tap finds `.submitting` and is ignored.
        case (.review(let amount, let quote), .confirm(let id, let now)):
            if quote.isExpired(now: now) { return .expired(amount: amount) }
            return .submitting(OrderIntent(clientOrderID: id, assetID: quote.assetID, amount: amount, quote: quote))

        case (.review(let amount, let quote), .clockTick(let now)):
            return quote.isExpired(now: now) ? .expired(amount: amount) : state

        case (.submitting(let i), .accepted), (.unknown(let i), .accepted), (.pending(let i), .accepted):
            return .pending(i)

        case (.submitting(let i), .filled(let fill)),
             (.pending(let i), .filled(let fill)),
             (.unknown(let i), .filled(let fill)):
            return .filled(i, fill)

        // Server says the quote was stale: no order placed, back to review with a fresh price.
        case (.submitting(let i), .failed(.quoteExpired)):
            return .expired(amount: i.amount)

        case (.submitting(let i), .failed(let reason)),
             (.pending(let i), .failed(let reason)),
             (.unknown(let i), .failed(let reason)):
            return .failed(i, reason)

        // Timeout is UNKNOWN, never failed: we must reconcile.
        case (.submitting(let i), .timedOut):
            return .unknown(i)

        case (.unknown(let i), .notFound):
            return .failed(i, .notPlaced)

        // Reset is not allowed while an order may be in flight.
        case (_, .reset) where !state.isUnresolved:
            return .draft

        default:
            return state
        }
    }
}
