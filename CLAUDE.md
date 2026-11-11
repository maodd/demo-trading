# CLAUDE.md — iOS project conventions

## Stack
- Swift 5.9+/6, SwiftUI, iOS 17+ (use `@Observable`, not `ObservableObject`)
- Concurrency: async/await and actors only. No Combine, no completion handlers, no GCD unless wrapping legacy APIs.
- No third-party dependencies unless I ask.

## Architecture
- MVVM + repository: View -> ViewModel (`@Observable`, `@MainActor`) -> Repository (protocol) -> API client (protocol)
- Every external dependency (network, storage, clock, UUID, WebSocket) sits behind a protocol and is injected via initializer.
- Provide `Mock*`/`Stub*` implementations for every protocol; the app runs fully on mocks by default.
- ViewModels expose a single `state` enum: `.idle / .loading / .loaded(T) / .empty / .failed(Error)`.
- Models are `struct`, `Codable`, `Equatable`, `Sendable`, `Identifiable` where relevant.

## Money and data rules
- Money, prices, quantities: `Decimal`. Never `Double`/`Float`.
- Parse decimals from strings in JSON (custom decoder), format with `Decimal.FormatStyle` / `NumberFormatter` with explicit currency code.
- Mutating requests (orders, transfers) carry an idempotency key generated once per user intent.
- Network errors are typed (`enum APIError: Error`), never swallow errors silently.

## UI rules
- Every screen handles loading, error (with retry), and empty states.
- Accessibility labels on interactive elements; support Dynamic Type.
- Previews use mock dependencies.

## Testing
- Tests are required for every ViewModel and repository. Swift Testing (`@Test`) preferred, XCTest ok.
- Test happy path, error path, empty path, and one edge case (e.g. timeout, duplicate submission).
- Use the mocks above; no real network in tests.

## Workflow (how you work with me)
1. Before coding, restate requirements and write a short plan in `PLAN.md`. Wait for my OK on architecture.
2. Build a thin end-to-end vertical slice first (mock API -> repo -> VM -> view -> one test). Then iterate.
3. Small, reviewable diffs. Explain non-obvious decisions in one or two lines.
4. After each change: build and run tests via XcodeBuildMCP. Report failures verbatim and fix them. Never claim it works without running it.
5. Do not refactor or touch unrelated files. Flag ideas instead of acting on them.
6. If a requirement is ambiguous, ask one short question rather than guessing.

## Folder layout
```
App/            entry point, DI composition root
Features/<Name>/  View, ViewModel, Models
Core/Networking/  APIClient protocol + impl + mock
Core/Persistence/ Store protocol + impl + mock
Tests/
```
