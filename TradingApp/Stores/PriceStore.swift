import Foundation
import Observation

/// Supplies a lockable quote for the Review screen.
@MainActor
protocol QuoteProvider: AnyObject {
    func quote(for id: AssetID) -> Quote?
}

/// Single source of truth for latest prices (PLAN.md §6). Watchlist and detail both read
/// from here, so prices never disagree between screens.
@Observable @MainActor
final class PriceStore: QuoteProvider {
    enum ConnectionStatus: Equatable {
        case connecting, live, delayed, offline
    }

    static let staleAfter: TimeInterval = 5

    let assets: [Asset]
    private(set) var ticks: [AssetID: PriceTick] = [:]
    /// Refreshed every second so staleness badges update.
    private(set) var now: Date

    @ObservationIgnored private let feed: PriceFeed
    @ObservationIgnored private let clock: DateProvider
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    init(assets: [Asset], feed: PriceFeed, clock: DateProvider, network: NetworkMonitor) {
        self.assets = assets
        self.feed = feed
        self.clock = clock
        self.network = network
        self.now = clock.now()
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            guard let stream = self?.feed.prices() else { return }
            for await tick in stream {
                self?.ticks[tick.assetID] = tick
            }
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = self.clock.now()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func restart() {
        streamTask?.cancel(); streamTask = nil
        timerTask?.cancel(); timerTask = nil
        start()
    }

    func tick(for id: AssetID) -> PriceTick? { ticks[id] }

    func secondsSinceUpdate(_ id: AssetID) -> Int? {
        guard let tick = ticks[id] else { return nil }
        return max(0, Int(now.timeIntervalSince(tick.timestamp)))
    }

    func isStale(_ id: AssetID) -> Bool {
        guard network.isOnline, let tick = ticks[id] else { return true }
        return now.timeIntervalSince(tick.timestamp) > PriceStore.staleAfter
    }

    func changeBasisPoints(for asset: Asset) -> Int64? {
        guard let tick = ticks[asset.id] else { return nil }
        return PriceChange.basisPoints(from: asset.previousClose, to: tick.price)
    }

    var isOnline: Bool { network.isOnline }

    var status: ConnectionStatus {
        if !network.isOnline { return .offline }
        if ticks.isEmpty { return .connecting }
        if assets.allSatisfy({ isStale($0.id) }) { return .delayed }
        return .live
    }

    /// Quote taken from the live price at review time (PLAN.md §11 assumption). Nil if stale/offline.
    func quote(for id: AssetID) -> Quote? {
        guard !isStale(id), let tick = ticks[id] else { return nil }
        return Quote(assetID: id, price: tick.price, quotedAt: clock.now())
    }
}
