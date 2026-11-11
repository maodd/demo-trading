import Foundation
import Observation

/// Owns the buy flow per asset, runs the reducer, handles submit + reconcile (PLAN.md §4, §6).
@Observable @MainActor
final class OrderStore {
    struct Config: Sendable {
        var clientTimeout: TimeInterval = 8
        var pollInterval: TimeInterval = 1.5
    }

    private(set) var flows: [AssetID: OrderState] = [:]
    /// Short user-facing notice per asset ("Price refreshed", "You're offline…").
    private(set) var notices: [AssetID: String] = [:]

    @ObservationIgnored private let api: OrderAPI
    @ObservationIgnored private let quotes: QuoteProvider
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let clock: DateProvider
    @ObservationIgnored private let makeID: () -> UUID
    @ObservationIgnored private let config: Config

    init(api: OrderAPI, quotes: QuoteProvider, network: NetworkMonitor, clock: DateProvider,
         config: Config = Config(), makeID: @escaping () -> UUID = UUID.init) {
        self.api = api
        self.quotes = quotes
        self.network = network
        self.clock = clock
        self.config = config
        self.makeID = makeID
    }

    func state(for id: AssetID) -> OrderState { flows[id] ?? .draft }
    func notice(for id: AssetID) -> String? { notices[id] }
    func isBuyBlocked(_ id: AssetID) -> Bool { state(for: id).isUnresolved }

    // MARK: Intents from the UI

    /// Amount entered → Review with a fresh quote.
    @discardableResult
    func startReview(_ id: AssetID, amount: Money) -> Bool {
        guard let quote = quotes.quote(for: id) else {
            notices[id] = "Live price unavailable. Try again in a moment."
            return false
        }
        notices[id] = nil
        apply(.quoted(amount: amount, quote: quote), to: id)
        return true
    }

    /// Called by the Review screen's timer. At 0s the price auto-refreshes, keeping the amount.
    func tick(_ id: AssetID) {
        apply(.clockTick(now: clock.now()), to: id)
        if case .expired(let amount) = state(for: id) {
            refreshQuote(id, amount: amount, notice: "Price refreshed — new 10s lock.")
        }
    }

    func confirm(_ id: AssetID) {
        // Guard 1: only from review (a double tap finds `.submitting` and returns).
        guard case .review = state(for: id) else { return }
        // Offline at confirm: don't submit, stay in review.
        guard network.isOnline else {
            notices[id] = "You're offline. No order was placed."
            return
        }
        notices[id] = nil
        // Guard 2: idempotency key generated ONCE per intent, here.
        apply(.confirm(clientOrderID: makeID(), now: clock.now()), to: id)
        switch state(for: id) {
        case .submitting(let intent):
            Task { await submit(intent) }
        case .expired(let amount):
            refreshQuote(id, amount: amount, notice: "Quote expired before confirm — here's the new price.")
        default:
            break
        }
    }

    /// From a definite failure: back to Review with a fresh quote (a NEW key will be minted on confirm).
    func retry(_ id: AssetID) {
        guard case .failed(let intent, _) = state(for: id) else { return }
        refreshQuote(id, amount: intent.amount, notice: nil)
    }

    func reset(_ id: AssetID) {
        apply(.reset, to: id)
        if state(for: id) == .draft { notices[id] = nil }
    }

    // MARK: Networking

    private func submit(_ intent: OrderIntent) async {
        let api = self.api
        do {
            let status = try await withTimeout(config.clientTimeout) { try await api.submit(intent) }
            handle(status, for: intent)
        } catch APIError.server {
            apply(.failed(.serverError), for: intent)
        } catch APIError.offline {
            apply(.failed(.offline), for: intent)
        } catch {
            // Timeout or anything unexpected: outcome is UNKNOWN, never assume failed.
            apply(.timedOut, for: intent)
            await reconcile(intent)
        }
    }

    private func handle(_ status: OrderStatus, for intent: OrderIntent) {
        switch status {
        case .pending:
            apply(.accepted, for: intent)
            Task { await reconcile(intent) }
        case .filled(let fill):
            apply(.filled(fill), for: intent)
        case .failed(.quoteExpired):
            apply(.failed(.quoteExpired), for: intent)
            refreshQuote(intent.assetID, amount: intent.amount, notice: "The price moved on — please review the new quote.")
        case .failed(let reason):
            apply(.failed(reason), for: intent)
        }
    }

    /// Polls `status(key)` until the order settles. Same key throughout — never resubmits a new order.
    private func reconcile(_ intent: OrderIntent) async {
        let api = self.api
        let key = intent.clientOrderID
        while isCurrent(intent), state(for: intent.assetID).isUnresolved {
            try? await Task.sleep(for: .seconds(config.pollInterval))
            guard isCurrent(intent) else { return }
            do {
                let status = try await withTimeout(config.clientTimeout) { try await api.status(key) }
                switch status {
                case nil:
                    if case .unknown = state(for: intent.assetID) { apply(.notFound, for: intent) }
                case .pending?:
                    apply(.accepted, for: intent)
                case .filled(let fill)?:
                    apply(.filled(fill), for: intent)
                case .failed(let reason)?:
                    apply(.failed(reason), for: intent)
                }
            } catch {
                continue // still unknown; keep checking with the same key
            }
        }
    }

    // MARK: Helpers

    private func refreshQuote(_ id: AssetID, amount: Money, notice: String?) {
        if let quote = quotes.quote(for: id) {
            apply(.quoted(amount: amount, quote: quote), to: id)
            notices[id] = notice
        } else {
            notices[id] = "Live price unavailable. Waiting for a fresh quote…"
        }
    }

    private func isCurrent(_ intent: OrderIntent) -> Bool {
        state(for: intent.assetID).intent?.clientOrderID == intent.clientOrderID
    }

    private func apply(_ event: OrderEvent, to id: AssetID) {
        flows[id] = OrderReducer.reduce(state(for: id), event)
    }

    /// Only applies network results to the intent they belong to.
    private func apply(_ event: OrderEvent, for intent: OrderIntent) {
        guard isCurrent(intent) else { return }
        apply(event, to: intent.assetID)
    }
}
