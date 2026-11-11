import SwiftUI
import Observation

@main
struct TradingApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            WatchlistView(viewModel: WatchlistViewModel(prices: env.priceStore))
                .environment(env.priceStore)
                .environment(env.orderStore)
                .environment(env.debug)
                .environment(\.biometrics, env.biometrics)
                .task { env.priceStore.start() }
        }
    }
}

/// Composition root. Everything runs on mocks by default.
/// Launch arguments (for deterministic demos):
///   -forceOutcome <fill|pendingThenFill|reject|serverError|timeoutPlaced|timeoutNotPlaced>
///   -frozenAsset <SYMBOL>   (asset stops ticking → stale badge)
///   -startOffline
@MainActor
final class AppEnvironment {
    let clock: DateProvider = SystemDateProvider()
    let network: MockNetworkMonitor
    let feed: MockPriceFeed
    let priceStore: PriceStore
    let orderAPI: MockOrderAPI
    let orderStore: OrderStore
    let debug: DebugSettings
    let biometrics: BiometricAuthenticator = MockBiometrics()

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let outcome = value(after: "-forceOutcome").flatMap(MockOrderAPI.Outcome.init(rawValue:)) ?? .random
        let frozen = Set(value(after: "-frozenAsset").map { [AssetID($0)] } ?? [])

        network = MockNetworkMonitor(isOnline: !arguments.contains("-startOffline"))
        feed = MockPriceFeed(assets: AssetCatalog.all, clock: clock, network: network, frozenAssets: frozen)
        priceStore = PriceStore(assets: AssetCatalog.all, feed: feed, clock: clock, network: network)
        orderAPI = MockOrderAPI(clock: clock, forcedOutcome: outcome)
        orderStore = OrderStore(api: orderAPI, quotes: priceStore, network: network, clock: clock)
        debug = DebugSettings(network: network, feed: feed, api: orderAPI, outcome: outcome)
    }
}

/// In-app debug switches (PLAN.md §5: force specific outcomes to demo each path).
@Observable @MainActor
final class DebugSettings {
    var forcedOutcome: MockOrderAPI.Outcome {
        didSet { let api = self.api, o = forcedOutcome; Task { await api.setForcedOutcome(o) } }
    }
    var isOffline: Bool {
        get { !network.isOnline }
        set { network.isOnline = !newValue }
    }
    var isFeedDisconnected: Bool {
        didSet { feed.isDisconnected = isFeedDisconnected }
    }

    @ObservationIgnored private let network: MockNetworkMonitor
    @ObservationIgnored private let feed: MockPriceFeed
    @ObservationIgnored private let api: MockOrderAPI

    init(network: MockNetworkMonitor, feed: MockPriceFeed, api: MockOrderAPI, outcome: MockOrderAPI.Outcome) {
        self.network = network
        self.feed = feed
        self.api = api
        self.forcedOutcome = outcome
        self.isFeedDisconnected = feed.isDisconnected
    }
}

private struct BiometricsKey: EnvironmentKey {
    static let defaultValue: BiometricAuthenticator = MockBiometrics()
}

extension EnvironmentValues {
    var biometrics: BiometricAuthenticator {
        get { self[BiometricsKey.self] }
        set { self[BiometricsKey.self] = newValue }
    }
}
