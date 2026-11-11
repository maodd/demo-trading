import Foundation
import Observation

/// Thin: derives display state from `PriceStore`.
@Observable @MainActor
final class WatchlistViewModel {
    struct Row: Identifiable, Equatable {
        let id: AssetID
        let symbol: String
        let name: String
        let kind: AssetKind
        let price: String
        let change: String?
        let changeSign: Int
        let isStale: Bool
        let staleText: String?
    }

    struct Section: Identifiable, Equatable {
        let kind: AssetKind
        let rows: [Row]
        var id: AssetKind { kind }
        var title: String { kind.sectionTitle }
    }

    enum DisplayState: Equatable {
        case loading
        case loaded([Section])
        case empty
        /// Offline: last known prices, all marked stale.
        case offline(cached: [Section])
        /// Offline with nothing cached.
        case failed(String)
    }

    enum Banner: Equatable {
        case offline
        case delayed
        case partial(count: Int)
    }

    let prices: PriceStore

    init(prices: PriceStore) { self.prices = prices }

    var state: DisplayState {
        if prices.assets.isEmpty { return .empty }
        let hasPrices = !prices.ticks.isEmpty
        if !prices.isOnline {
            return hasPrices ? .offline(cached: sections) : .failed("You're offline and no prices have loaded yet.")
        }
        return hasPrices ? .loaded(sections) : .loading
    }

    var banner: Banner? {
        switch prices.status {
        case .offline: return .offline
        case .delayed: return .delayed
        case .connecting: return nil
        case .live:
            // Only assets that ticked and then went quiet count; first-load ones are still connecting.
            let stale = prices.assets.filter { prices.tick(for: $0.id) != nil && prices.isStale($0.id) }.count
            return stale > 0 ? .partial(count: stale) : nil
        }
    }

    func retry() { prices.restart() }

    private var sections: [Section] {
        AssetKind.allCases.compactMap { kind in
            let rows = prices.assets.filter { $0.kind == kind }.map(row)
            return rows.isEmpty ? nil : Section(kind: kind, rows: rows)
        }
    }

    private func row(_ asset: Asset) -> Row {
        let tick = prices.tick(for: asset.id)
        let bp = prices.changeBasisPoints(for: asset)
        let stale = prices.isStale(asset.id)
        var staleText: String?
        if tick == nil {
            staleText = prices.isOnline ? "Connecting…" : "No price"
        } else if stale, let s = prices.secondsSinceUpdate(asset.id) {
            staleText = s >= 60 ? "Stale · \(s / 60)m" : "Stale · \(s)s"
        }
        return Row(
            id: asset.id, symbol: asset.symbol, name: asset.name, kind: asset.kind,
            price: tick?.price.formatted() ?? "—",
            change: bp.map(PriceChange.formatted(basisPoints:)),
            changeSign: bp.map { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) } ?? 0,
            isStale: stale,
            staleText: staleText
        )
    }
}
