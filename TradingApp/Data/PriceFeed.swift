import Foundation

@MainActor
protocol PriceFeed: AnyObject {
    func prices() -> AsyncStream<PriceTick>
}

/// Random-walk price stream with jitter, per-asset pauses (to trigger staleness)
/// and a disconnect toggle (PLAN.md §5).
@MainActor
final class MockPriceFeed: PriceFeed {
    struct Config: Sendable {
        var initialDelay: ClosedRange<Double> = 0.8...1.8
        var tickInterval: ClosedRange<Double> = 0.5...1.5
        /// Chance per tick that an asset goes silent for `pauseDuration`.
        var pauseChance: Double = 0.012
        var pauseDuration: ClosedRange<Double> = 8...15
        /// Max move per tick in basis points.
        var maxStepBasisPoints: Int64 = 18
    }

    /// Debug toggle: simulate the stream dropping.
    var isDisconnected = false
    /// Debug: assets that never tick after the first price (forces a stale row).
    var frozenAssets: Set<AssetID>

    private let assets: [Asset]
    private let config: Config
    private let clock: DateProvider
    private let network: NetworkMonitor
    private var lastPrice: [AssetID: Money] = [:]

    init(assets: [Asset], config: Config = Config(), clock: DateProvider,
         network: NetworkMonitor, frozenAssets: Set<AssetID> = []) {
        self.assets = assets
        self.config = config
        self.clock = clock
        self.network = network
        self.frozenAssets = frozenAssets
        for asset in assets {
            let drift = Int64.random(in: -150...150) // ±1.5% from previous close
            lastPrice[asset.id] = Money(micros: asset.previousClose.micros + asset.previousClose.micros * drift / 10_000).roundedToCents()
        }
    }

    func prices() -> AsyncStream<PriceTick> {
        let (stream, continuation) = AsyncStream.makeStream(of: PriceTick.self)
        let tasks = assets.map { asset in
            Task { @MainActor [weak self] in
                await self?.run(asset: asset, continuation: continuation)
            }
        }
        continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
        return stream
    }

    private func run(asset: Asset, continuation: AsyncStream<PriceTick>.Continuation) async {
        try? await Task.sleep(for: .seconds(Double.random(in: config.initialDelay)))
        var hasTicked = false
        while !Task.isCancelled {
            let frozen = hasTicked && frozenAssets.contains(asset.id)
            if !isDisconnected, network.isOnline, !frozen {
                if hasTicked, Double.random(in: 0..<1) < config.pauseChance {
                    try? await Task.sleep(for: .seconds(Double.random(in: config.pauseDuration)))
                    continue
                }
                continuation.yield(PriceTick(assetID: asset.id, price: step(asset.id), timestamp: clock.now()))
                hasTicked = true
            }
            try? await Task.sleep(for: .seconds(Double.random(in: config.tickInterval)))
        }
    }

    private func step(_ id: AssetID) -> Money {
        let current = lastPrice[id] ?? .zero
        let bp = Int64.random(in: -config.maxStepBasisPoints...config.maxStepBasisPoints)
        let floor = Money(micros: 10_000) // never negative / zero
        let next = max(floor, Money(micros: current.micros + current.micros * bp / 10_000).roundedToCents())
        lastPrice[id] = next
        return next
    }
}
