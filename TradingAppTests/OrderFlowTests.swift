import Testing
import Foundation
@testable import TradingApp

/// Fast config so timeout / pending paths run in milliseconds.
private let fastAPI = MockOrderAPI.Config(
    latency: 0.01...0.02, statusLatency: 0.005...0.01, pendingDuration: 0.05, hangDuration: 1.0
)
private let fastStore = OrderStore.Config(clientTimeout: 0.2, pollInterval: 0.05)

@MainActor
final class StubQuotes: QuoteProvider {
    var price = Money.dollars(100)
    var available = true
    let clock: DateProvider
    init(clock: DateProvider) { self.clock = clock }
    func quote(for id: AssetID) -> Quote? {
        available ? Quote(assetID: id, price: price, quotedAt: clock.now()) : nil
    }
}

@MainActor
private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func intent(_ key: UUID = UUID(), quotedAt: Date = Date()) -> OrderIntent {
    OrderIntent(clientOrderID: key, assetID: AssetID("BTC"), amount: .dollars(50),
                quote: Quote(assetID: AssetID("BTC"), price: .dollars(100_000), quotedAt: quotedAt))
}

struct MockOrderAPITests {
    @Test func sameKeyTwiceCreatesOneOrder() async throws {
        let api = MockOrderAPI(config: fastAPI, clock: SystemDateProvider(), forcedOutcome: .fill)
        let i = intent()
        let first = try await api.submit(i)
        let second = try await api.submit(i)
        #expect(first == second)
        #expect(await api.placedOrderCount == 1)
        #expect(await api.submitCallCount == 2)
    }

    @Test func dedupReturnsOriginalFailure() async throws {
        let api = MockOrderAPI(config: fastAPI, clock: SystemDateProvider(), forcedOutcome: .reject)
        let i = intent()
        #expect(try await api.submit(i) == .failed(.rejected))
        await api.setForcedOutcome(.fill)
        #expect(try await api.submit(i) == .failed(.rejected)) // not re-processed
    }

    @Test func timeoutButPlacedReconcilesToFilled() async throws {
        let api = MockOrderAPI(config: fastAPI, clock: SystemDateProvider(), forcedOutcome: .timeoutPlaced)
        let i = intent()
        await #expect(throws: APIError.timeout) {
            try await withTimeout(0.1) { try await api.submit(i) }
        }
        try await Task.sleep(for: .milliseconds(100))
        let status = try await api.status(i.clientOrderID)
        guard case .filled? = status else { Issue.record("expected filled, got \(String(describing: status))"); return }
        #expect(await api.placedOrderCount == 1)
    }

    @Test func timeoutNotPlacedIsNotFound() async throws {
        let api = MockOrderAPI(config: fastAPI, clock: SystemDateProvider(), forcedOutcome: .timeoutNotPlaced)
        let i = intent()
        await #expect(throws: APIError.timeout) {
            try await withTimeout(0.1) { try await api.submit(i) }
        }
        #expect(try await api.status(i.clientOrderID) == nil)
    }

    @Test func serverRejectsStaleQuote() async throws {
        let api = MockOrderAPI(config: fastAPI, clock: SystemDateProvider(), forcedOutcome: .fill)
        let stale = intent(quotedAt: Date().addingTimeInterval(-11))
        #expect(try await api.submit(stale) == .failed(.quoteExpired))
        #expect(await api.placedOrderCount == 0)
    }
}

@MainActor
struct OrderStoreTests {
    let btc = AssetID("BTC")

    private func makeStore(_ outcome: MockOrderAPI.Outcome, online: Bool = true)
        -> (OrderStore, MockOrderAPI, MockNetworkMonitor, StubQuotes) {
        let clock = SystemDateProvider()
        let api = MockOrderAPI(config: fastAPI, clock: clock, forcedOutcome: outcome)
        let network = MockNetworkMonitor(isOnline: online)
        let quotes = StubQuotes(clock: clock)
        let store = OrderStore(api: api, quotes: quotes, network: network, clock: clock, config: fastStore)
        return (store, api, network, quotes)
    }

    @Test func happyPathFills() async {
        let (store, api, _, _) = makeStore(.fill)
        store.startReview(btc, amount: .dollars(50))
        store.confirm(btc)
        #expect(await waitUntil { store.state(for: btc).code == 4 })
        #expect(await api.placedOrderCount == 1)
    }

    @Test func doubleTapPlacesOneOrder() async {
        let (store, api, _, _) = makeStore(.fill)
        store.startReview(btc, amount: .dollars(50))
        store.confirm(btc)
        store.confirm(btc)
        store.confirm(btc)
        #expect(await waitUntil { store.state(for: btc).code == 4 })
        #expect(await api.submitCallCount == 1)
        #expect(await api.placedOrderCount == 1)
    }

    @Test func offlineAtConfirmDoesNotSubmit() async {
        let (store, api, network, _) = makeStore(.fill)
        store.startReview(btc, amount: .dollars(50))
        network.isOnline = false
        store.confirm(btc)
        #expect(store.state(for: btc).code == 1) // still review
        #expect(store.notice(for: btc) != nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await api.submitCallCount == 0)
    }

    @Test func timeoutPlacedGoesUnknownThenFilledWithoutResubmitting() async {
        let (store, api, _, _) = makeStore(.timeoutPlaced)
        store.startReview(btc, amount: .dollars(50))
        store.confirm(btc)
        #expect(await waitUntil { store.state(for: btc).code == 7 })
        #expect(store.isBuyBlocked(btc))
        #expect(await waitUntil { store.state(for: btc).code == 4 })
        #expect(await api.submitCallCount == 1)
        #expect(await api.placedOrderCount == 1)
    }

    @Test func timeoutNotPlacedResolvesToFailedNotPlaced() async {
        let (store, _, _, _) = makeStore(.timeoutNotPlaced)
        store.startReview(btc, amount: .dollars(50))
        store.confirm(btc)
        #expect(await waitUntil {
            if case .failed(_, .notPlaced) = store.state(for: btc) { return true }
            return false
        })
        #expect(!store.isBuyBlocked(btc))
    }

    @Test func retryAfterFailureUsesNewKey() async {
        let (store, api, _, _) = makeStore(.reject)
        store.startReview(btc, amount: .dollars(50))
        store.confirm(btc)
        #expect(await waitUntil { store.state(for: btc).code == 5 })
        let firstKey = store.state(for: btc).intent!.clientOrderID
        await api.setForcedOutcome(.fill)
        store.retry(btc)
        #expect(store.state(for: btc).code == 1)
        store.confirm(btc)
        #expect(await waitUntil { store.state(for: btc).code == 4 })
        #expect(store.state(for: btc).intent!.clientOrderID != firstKey)
    }

    @Test func noQuoteWhenPriceStale() {
        let (store, _, _, quotes) = makeStore(.fill)
        quotes.available = false
        #expect(store.startReview(btc, amount: .dollars(50)) == false)
        #expect(store.state(for: btc) == .draft)
    }
}
