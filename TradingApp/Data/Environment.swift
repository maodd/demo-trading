import Foundation
import Observation

// MARK: - Clock

/// Injected clock (named to avoid clashing with Swift's `Clock`).
protocol DateProvider: Sendable {
    func now() -> Date
}

struct SystemDateProvider: DateProvider {
    func now() -> Date { Date() }
}

/// Settable clock for tests.
final class TestDateProvider: DateProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

// MARK: - Network reachability

@MainActor
protocol NetworkMonitor: AnyObject {
    var isOnline: Bool { get }
}

@Observable @MainActor
final class MockNetworkMonitor: NetworkMonitor {
    var isOnline: Bool
    init(isOnline: Bool = true) { self.isOnline = isOnline }
}

// MARK: - Biometrics (mocked, PLAN.md §1)

protocol BiometricAuthenticator: Sendable {
    func authenticate(reason: String) async -> Bool
}

struct MockBiometrics: BiometricAuthenticator {
    var delay: Duration = .milliseconds(600)
    func authenticate(reason: String) async -> Bool {
        try? await Task.sleep(for: delay)
        return true
    }
}

// MARK: - Timeout helper

enum APIError: Error, Equatable, Sendable {
    case timeout
    case offline
    case server(status: Int)
}

/// Runs `operation`, throwing `APIError.timeout` if it does not finish in `seconds`.
func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw APIError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw APIError.timeout }
        return result
    }
}
