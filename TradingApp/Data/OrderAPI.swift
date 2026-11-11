import Foundation

enum OrderStatus: Equatable, Sendable {
    case pending
    case filled(Fill)
    case failed(FailureReason)
}

protocol OrderAPI: Sendable {
    /// Idempotent on `intent.clientOrderID`.
    func submit(_ intent: OrderIntent) async throws -> OrderStatus
    /// Returns nil when the server has no order for this key.
    func status(_ clientOrderID: UUID) async throws -> OrderStatus?
}

/// In-memory order server with latency, failures, timeouts and dedup (PLAN.md §5).
actor MockOrderAPI: OrderAPI {
    enum Outcome: String, CaseIterable, Sendable, Identifiable {
        case random, fill, pendingThenFill, reject, serverError, timeoutPlaced, timeoutNotPlaced
        var id: String { rawValue }
        var label: String {
            switch self {
            case .random: "Random (weighted)"
            case .fill: "Fill"
            case .pendingThenFill: "Pending → Fill"
            case .reject: "Reject"
            case .serverError: "Server error (5xx)"
            case .timeoutPlaced: "Timeout, order placed"
            case .timeoutNotPlaced: "Timeout, not placed"
            }
        }
    }

    struct Config: Sendable {
        var latency: ClosedRange<Double> = 1...4
        var statusLatency: ClosedRange<Double> = 0.3...0.8
        var pendingDuration: Double = 3
        /// How long a "timeout" request hangs (longer than the client timeout).
        var hangDuration: Double = 30
        var weights: [(Outcome, Double)] = [
            (.fill, 0.35), (.pendingThenFill, 0.20), (.reject, 0.10),
            (.serverError, 0.15), (.timeoutPlaced, 0.10), (.timeoutNotPlaced, 0.10),
        ]
    }

    private enum Result {
        case filled(Fill)
        case pendingUntil(Date, Fill)
        case failed(FailureReason)
        case serverError
    }

    private var orders: [UUID: Result] = [:]
    private(set) var submitCallCount = 0
    private(set) var forcedOutcome: Outcome
    private let config: Config
    private let clock: DateProvider

    /// Number of distinct orders the server actually placed (fills / pending).
    var placedOrderCount: Int {
        orders.values.filter {
            switch $0 { case .filled, .pendingUntil: true; default: false }
        }.count
    }

    init(config: Config = Config(), clock: DateProvider, forcedOutcome: Outcome = .random) {
        self.config = config
        self.clock = clock
        self.forcedOutcome = forcedOutcome
    }

    func setForcedOutcome(_ outcome: Outcome) { forcedOutcome = outcome }

    func submit(_ intent: OrderIntent) async throws -> OrderStatus {
        submitCallCount += 1
        let id = intent.clientOrderID

        // Dedup: same key returns the stored result, including a stored failure.
        if let existing = orders[id] {
            try await sleep(config.latency)
            return try status(of: existing)
        }

        let now = clock.now()
        if intent.quote.isExpired(now: now) {
            orders[id] = .failed(.quoteExpired)
            try await sleep(config.latency)
            return .failed(.quoteExpired)
        }

        let fill = Fill(
            quantity: Quantity.forAmount(intent.amount, at: intent.quote.price) ?? .zero,
            price: intent.quote.price,
            filledAt: now
        )

        switch pickOutcome() {
        case .random, .fill:
            orders[id] = .filled(fill)
            try await sleep(config.latency)
            return .filled(fill)
        case .pendingThenFill:
            orders[id] = .pendingUntil(now.addingTimeInterval(config.latency.upperBound + config.pendingDuration), fill)
            try await sleep(config.latency)
            return .pending
        case .reject:
            orders[id] = .failed(.rejected)
            try await sleep(config.latency)
            return .failed(.rejected)
        case .serverError:
            orders[id] = .serverError
            try await sleep(config.latency)
            throw APIError.server(status: 503)
        case .timeoutPlaced:
            // The order IS placed; the response is lost.
            orders[id] = .pendingUntil(now.addingTimeInterval(config.pendingDuration), fill)
            try await Task.sleep(for: .seconds(config.hangDuration))
            throw APIError.timeout
        case .timeoutNotPlaced:
            // Request never processed; nothing stored.
            try await Task.sleep(for: .seconds(config.hangDuration))
            throw APIError.timeout
        }
    }

    func status(_ clientOrderID: UUID) async throws -> OrderStatus? {
        try await sleep(config.statusLatency)
        guard let result = orders[clientOrderID] else { return nil }
        return try status(of: result)
    }

    private func status(of result: Result) throws -> OrderStatus {
        switch result {
        case .filled(let fill): return .filled(fill)
        case .pendingUntil(let date, let fill): return clock.now() >= date ? .filled(fill) : .pending
        case .failed(let reason): return .failed(reason)
        case .serverError: throw APIError.server(status: 503)
        }
    }

    private func pickOutcome() -> Outcome {
        guard forcedOutcome == .random else { return forcedOutcome }
        var roll = Double.random(in: 0..<config.weights.reduce(0) { $0 + $1.1 })
        for (outcome, weight) in config.weights {
            if roll < weight { return outcome }
            roll -= weight
        }
        return .fill
    }

    private func sleep(_ range: ClosedRange<Double>) async throws {
        try await Task.sleep(for: .seconds(Double.random(in: range)))
    }
}
