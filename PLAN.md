# PLAN: Mobile Investing App (SwiftUI) — Watchlist + Buy flow

Status: planning only. No code written yet. Goal: a trustworthy-feeling app on top of live prices and a slow, flaky order API.

## 1. Scope
**Core (build in this order)**
1. Watchlist: ~10 assets (5 tokenized stocks, 5 crypto), live prices, price change, staleness indicator.
2. Asset detail + Buy: enter amount -> review -> confirm -> pending -> filled / failed.

**Robustness (part of core, not stretch)**
- Loading, empty, offline, partial-failure states.
- Never place a duplicate order (double-tap, retry, timeout).

**Stretch (stub or skip):** persistence, chart, accessibility pass. Unit tests for the order state logic are cheap and high-value, so they move into core if time allows.

**Out of scope:** real auth/KYC, real funds, sell flow, limit orders. Biometrics are mocked.

## 2. Decisions from the brief
- ~10 assets, hardcoded list in the mock.
- **Price lock: 10 seconds.** A quote shown on the review screen is valid for 10s. If it passes 10s before the order is confirmed or submitted, treat it as expired and restart the flow from the Review screen with a fresh price.
- We build our own mock price stream and mock order API, including slow responses, random failures and network timeouts.
- **Order state is an enum.** Money may be integers (fixed-point); meanings and handling can expand as we go.

## 3. Domain model
**Asset identity**
- `AssetID`: struct wrapping a stable string (e.g. `"TSLA"`, `"BTC"`), `Hashable`. Never use display names as identity.
- `AssetKind`: enum `stock | crypto`.
- `Asset`: `id`, `kind`, `symbol`, `name`.

**Money (integers, no floating point)**
- `Money`: `micros: Int64` (1 USD = 1_000_000 micros) + `currency` (USD only for now). Formatting in one helper only.
- Price per unit: `Money`. Order amount: `Money`.
- Quantity: `Int64` in 1e-8 units (fixed-point). Computed as `amount * 1e8 / price`, rounded down (never over-sell/over-credit). Display-only conversion to string.
- Percent change: derived from the previous close or first price, computed with integer math, formatted at the edge.
- Rule: all conversions are in one `Money`/`Quantity` file and unit tested.

**Price tick / quote**
- `PriceTick`: `assetID`, `price: Money`, `timestamp: Date`.
- `Quote`: `assetID`, `price: Money`, `quotedAt: Date`; `isExpired(now)` is `now - quotedAt >= 10s`. Clock is injected.

**Order**
- `OrderState` enum with Int raw values (easy to log and persist):
  - `0 draft` — entering amount
  - `1 review` — quote shown, user reviewing (with expiry countdown)
  - `2 submitting` — request in flight (UI locked)
  - `3 pending` — server accepted, not yet filled
  - `4 filled`
  - `5 failed(reason)` — rejected / server error, definitively no order placed
  - `6 expired` — quote older than 10s; return to review with new quote
  - `7 unknown` — timeout or lost response; outcome not known, must reconcile
- `FailureReason`: `rejected`, `serverError`, `insufficientFunds`, `offline`, ... (expandable).
- `OrderIntent`: `clientOrderID: UUID` (idempotency key), `assetID`, `amount: Money`, `quote: Quote`.
- Transitions live in a pure function `reduce(state, event) -> state` so they can be unit tested without UI.

## 4. Buy flow and state machine
```
draft --amount valid--> review(quote, 10s timer)
review --confirm--> submitting        [only legal from review; second tap ignored]
review --10s elapsed--> expired --refresh quote--> review (new intent, new key)
submitting --accepted--> pending --> filled | failed
submitting --definite error--> failed (retry allowed: new intent only if server confirms no order)
submitting --timeout--> unknown --reconcile via getOrder(key)--> pending | filled | failed | not found
```
**Expiry rules**
- Check expiry when the user taps Confirm (client side) and send the quote timestamp/price in the request so the mock server also rejects stale quotes (`quoteExpired`) -> back to Review with a fresh quote.
- Review screen shows a visible countdown; at 0 it auto-refreshes the price and resets the timer without losing the entered amount.
- Once an order is `submitting`, the quote is considered used; expiry does not cancel in-flight orders.

**Never duplicate an order**
1. UI guard: Confirm button disabled and state machine ignores `confirm` unless state == `review`.
2. Idempotency key: `clientOrderID` generated once per intent (at Confirm), reused for every retry of that same intent. A new key is only created after the user restarts from Review with a new quote.
3. Mock server dedups on key: same key returns the original result (including original failure).
4. Timeout = unknown, not failed. Retry/reconcile with the same key, or look the order up by key. The Buy button is blocked for that asset until resolved.
5. Offline at confirm: don't submit; show offline error and keep state in `review`.

## 5. Mock backend (we build it)
**`PriceFeed` protocol**: `func prices() -> AsyncStream<PriceTick>`
- `MockPriceFeed`: random walk per asset, tick every 0.5–1.5s per asset with jitter, price in micros, never negative.
- Failure injection: randomly pauses one or two assets for 8–15s (to trigger staleness), and a toggle to simulate stream disconnect.

**`OrderAPI` protocol**: `submit(intent) async throws -> OrderResponse`, `status(clientOrderID) async throws -> OrderStatus`
- `MockOrderAPI` (actor, holds an in-memory order table keyed by `clientOrderID`).
- Latency 1–4s.
- Outcome mix per new order (weights tunable): ~55% fills (maybe after a pending phase), ~10% rejected, ~15% 5xx before processing, ~10% network timeout where the order **is** actually placed server-side, ~10% network timeout where it was **not** placed.
- Rejects stale quotes (>10s) with `quoteExpired`.
- Dedup: same key returns the stored result.
- `status(key)` returns the true state (or not found) so the client can reconcile after a timeout.
- Client-side request timeout: ~8s (use a `withTimeout` wrapper around the call).
- A debug switch (launch argument or in-app toggle) forces specific outcomes so we can demo each path deterministically.

## 6. Architecture and where state lives
- **Protocols** for `PriceFeed`, `OrderAPI`, `Clock`, `NetworkMonitor` (reachability), injected into stores; mocks for all.
- **`PriceStore`** (`@Observable`, `@MainActor`): single source of truth for latest `PriceTick` per `AssetID`, last-update time, and connection status. The watchlist and detail screens both read from it, so prices never disagree between screens.
- **`OrderStore`** (`@Observable`): owns active and recent orders by `clientOrderID`, runs the state machine, handles submit/reconcile. Detail and any future orders screen observe it.
- **`WatchlistViewModel` / `BuyViewModel`**: thin; derive display state from stores.
- **Staleness**: a tick older than 5s -> "Stale" badge (gray price + time since update); whole feed silent -> banner "Prices delayed".
- **Display state per screen** is an enum: `loading | loaded | empty | error(retry) | offline(cached)`.
- Folder layout:
```
App/                 entry, composition root
Domain/              AssetID, Asset, Money, Quantity, Quote, OrderState, reducer
Data/                PriceFeed, OrderAPI protocols + Mock implementations
Stores/              PriceStore, OrderStore
Features/Watchlist/  view + view model
Features/AssetDetail/ detail, amount entry, review, status views
Tests/               Money, reducer, mock API dedup, expiry
```

## 7. UI states checklist
- Watchlist: loading (skeleton), loaded, empty, offline banner with last-known prices marked stale, per-row stale badge, partial failure (some assets stale, others live).
- Detail: price + change, Buy button (disabled when asset stale/offline).
- Amount entry: numeric keypad, validation (min/max, balance mock), shows estimated quantity.
- Review: price, estimated quantity, fee line (stub), countdown, Confirm (mock biometrics).
- Status: submitting (spinner, locked), pending, filled (summary), failed (reason + retry rules), unknown ("checking your order…", no retry until resolved).

## 8. Build order (small, reviewable commits)
| Step | Deliverable | Verify |
|---|---|---|
| 1 | Domain types: `Money`, `Quantity`, `AssetID`, `Quote`, `OrderState` + reducer | unit tests |
| 2 | `PriceFeed` + `MockPriceFeed` + `PriceStore` | prints ticks; staleness works |
| 3 | Watchlist screen (loading, loaded, stale, offline) | run in simulator |
| 4 | `OrderAPI` + `MockOrderAPI` (latency, failures, dedup, timeout) | tests for dedup/timeout |
| 5 | `OrderStore` + state machine wiring + idempotency | tests: double tap, retry, timeout->reconcile |
| 6 | Detail + amount + review (10s expiry) + status views | manual run through each outcome |
| 7 | Stretch if time: tests polish, persistence, a11y labels | — |
| 8 | Review wrap-up: update this file with done / stubbed / next | — |

Mid-session requirement change: keep reducer and stores decoupled from views so a new ask (e.g. limit order, fees, new state) is a small diff.

## 9. Testing priorities (money path)
- `Money`/`Quantity` math: rounding down, no overflow, formatting.
- Reducer: all legal and illegal transitions; double `confirm` ignored.
- Expiry at exactly 10s boundary with injected clock.
- Mock API: same key twice -> single order; timeout-but-placed reconciles to filled.
- Offline at confirm doesn't create an order.

## 10. AI usage notes (for the walkthrough)
- Delegate: mock feed/API boilerplate, view scaffolding, first-draft tests.
- Keep for myself: domain types, the state machine, idempotency rules, expiry rules, review of every diff.
- Verification in money paths: pure functions with tests, injected clock, deterministic failure switch, run each outcome manually.
- Handoff: this PLAN.md + the state diagram + notes on stubs and known gaps.

## 11. Assumptions / open questions
- Currency is USD only; no real balance (a mock balance for validation only).
- Integer fixed-point for money, as agreed; Decimal remains an option if the requirement changes.
- Staleness threshold 5s and request timeout 8s are tunable constants.
- Is the quote price taken from the live `PriceStore` at review time? (Assumed yes.)

## 12. Done / Stubbed / Next (fill in at the end)
- Done: —
- Stubbed: —
- Next: —
