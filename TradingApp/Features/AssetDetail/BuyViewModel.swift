import Foundation
import Observation

/// Thin view model for amount entry + validation. Order logic lives in `OrderStore`.
@Observable @MainActor
final class BuyViewModel {
    nonisolated static let minimum = Money.dollars(1)
    nonisolated static let maximum = Money.dollars(10_000)
    /// Mock balance used for validation only (PLAN.md §11).
    nonisolated static let mockBalance = Money.dollars(25_000)

    enum Validation: Equatable {
        case empty
        case invalid
        case belowMinimum
        case aboveMaximum
        case insufficientFunds
        case valid(Money)

        var message: String? {
            switch self {
            case .empty, .valid: nil
            case .invalid: "Enter a valid amount (max 2 decimals)."
            case .belowMinimum: "Minimum order is \(BuyViewModel.minimum.formatted())."
            case .aboveMaximum: "Maximum order is \(BuyViewModel.maximum.formatted())."
            case .insufficientFunds: "Not enough buying power."
            }
        }
    }

    let asset: Asset
    var amountText = ""

    private let prices: PriceStore
    private let orders: OrderStore

    init(asset: Asset, prices: PriceStore, orders: OrderStore) {
        self.asset = asset
        self.prices = prices
        self.orders = orders
    }

    var state: OrderState { orders.state(for: asset.id) }
    var notice: String? { orders.notice(for: asset.id) }

    var validation: Validation {
        let trimmed = amountText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        guard let amount = Money.parse(trimmed) else { return .invalid }
        if amount < Self.minimum { return .belowMinimum }
        if amount > Self.mockBalance { return .insufficientFunds }
        if amount > Self.maximum { return .aboveMaximum }
        return .valid(amount)
    }

    var estimatedQuantity: String? {
        guard case .valid(let amount) = validation, let price = prices.tick(for: asset.id)?.price,
              let qty = Quantity.forAmount(amount, at: price) else { return nil }
        return "≈ \(qty.formatted()) \(asset.symbol)"
    }

    var canReview: Bool {
        if case .valid = validation, !prices.isStale(asset.id) { return true }
        return false
    }

    func review() {
        guard case .valid(let amount) = validation else { return }
        orders.startReview(asset.id, amount: amount)
    }

    func tick() { orders.tick(asset.id) }
    func confirm() { orders.confirm(asset.id) }
    func retry() { orders.retry(asset.id) }
    func reset() { orders.reset(asset.id) }
}
