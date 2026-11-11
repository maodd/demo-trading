import SwiftUI

/// Amount → Review (10s lock) → Submitting → Pending → Filled / Failed / Unknown.
struct BuyFlowView: View {
    @State var viewModel: BuyViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .draft:
                    AmountEntryView(viewModel: viewModel)
                case .review(let amount, let quote):
                    ReviewView(viewModel: viewModel, amount: amount, quote: quote)
                case .expired:
                    StatusView(icon: .progress, title: "Refreshing price…",
                               message: "Your 10-second price lock ran out.")
                case .submitting:
                    StatusView(icon: .progress, title: "Placing your order…",
                               message: "Please don't close the app.")
                case .pending(let intent):
                    StatusView(icon: .progress, title: "Order received",
                               message: "Waiting for \(intent.amount.formatted()) of \(viewModel.asset.symbol) to fill.")
                case .unknown:
                    StatusView(icon: .progress, title: "Checking your order…",
                               message: "The connection dropped while placing your order. We're confirming whether it went through — it will never be placed twice.")
                case .filled(let intent, let fill):
                    FilledView(asset: viewModel.asset, intent: intent, fill: fill) { dismiss() }
                case .failed(let intent, let reason):
                    FailedView(intent: intent, reason: reason,
                               retry: { viewModel.retry() }, close: { dismiss() })
                }
            }
            .animation(.default, value: viewModel.state.code)
            .navigationTitle("Buy \(viewModel.asset.symbol)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !viewModel.state.isUnresolved {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
        // Can't swipe away while the request is literally in flight.
        .interactiveDismissDisabled(isSubmitting)
    }

    private var isSubmitting: Bool {
        if case .submitting = viewModel.state { return true }
        return false
    }
}

// MARK: - Amount

struct AmountEntryView: View {
    @Bindable var viewModel: BuyViewModel
    @FocusState private var focused: Bool
    @Environment(PriceStore.self) private var prices

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            Text("Amount in USD").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("$").font(.system(size: 40, weight: .semibold)).foregroundStyle(.secondary)
                TextField("0", text: $viewModel.amountText)
                    .font(.system(size: 52, weight: .bold).monospacedDigit())
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .fixedSize()
                    .accessibilityLabel("Amount in US dollars")
            }
            if let message = viewModel.validation.message {
                Text(message).font(.subheadline).foregroundStyle(.red)
            } else if let qty = viewModel.estimatedQuantity {
                Text(qty).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text(" ").font(.subheadline)
            }

            HStack {
                ForEach(["50", "100", "500", "1000"], id: \.self) { preset in
                    Button("$\(preset)") { viewModel.amountText = preset }
                        .buttonStyle(.bordered)
                }
            }

            if let price = prices.tick(for: viewModel.asset.id)?.price {
                Text("Market price \(price.formatted())  ·  Buying power \(BuyViewModel.mockBalance.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = viewModel.notice {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            }
            Spacer()
            Button {
                viewModel.review()
            } label: {
                Text("Review order").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canReview)
        }
        .padding()
        .onAppear { focused = true }
    }
}

// MARK: - Review

struct ReviewView: View {
    let viewModel: BuyViewModel
    let amount: Money
    let quote: Quote
    @Environment(\.biometrics) private var biometrics
    @Environment(PriceStore.self) private var prices
    @State private var authenticating = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    LabeledContent("Price per \(viewModel.asset.symbol)", value: quote.price.formatted())
                    LabeledContent("Amount", value: amount.formatted())
                    LabeledContent("Est. quantity",
                                   value: "\(Quantity.forAmount(amount, at: quote.price)?.formatted() ?? "—") \(viewModel.asset.symbol)")
                    LabeledContent("Fee", value: Money.zero.formatted())
                } footer: {
                    Text("Quantity is rounded down to 8 decimals. You'll never be charged more than \(amount.formatted()).")
                }
                Section {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let remaining = quote.secondsRemaining(now: context.date)
                        HStack {
                            ZStack {
                                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                                Circle()
                                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(Quote.validity))
                                    .stroke(remaining <= 3 ? Color.orange : Color.accentColor,
                                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.25), value: remaining)
                                Text("\(remaining)").font(.caption.monospacedDigit().bold())
                            }
                            .frame(width: 34, height: 34)
                            VStack(alignment: .leading) {
                                Text("Price locked for \(remaining)s").font(.subheadline.weight(.medium))
                                Text("Refreshes automatically, your amount is kept.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let notice = viewModel.notice {
                    Section { Label(notice, systemImage: "info.circle").foregroundStyle(.orange) }
                }
            }
            Button {
                guard !authenticating else { return }
                authenticating = true
                Task {
                    let ok = await biometrics.authenticate(reason: "Confirm your order")
                    authenticating = false
                    if ok { viewModel.confirm() }
                }
            } label: {
                HStack {
                    if authenticating { ProgressView().tint(.white) } else { Image(systemName: "faceid") }
                    Text("Confirm purchase")
                }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(authenticating || !prices.isOnline)
            .padding()
            .accessibilityHint("Authenticates with Face ID and places the order")
        }
        .task(id: quote.quotedAt) {
            while !Task.isCancelled {
                viewModel.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

// MARK: - Status

struct StatusView: View {
    enum Icon { case progress }
    let icon: Icon
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(title).font(.title2.weight(.semibold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(32)
        .accessibilityElement(children: .combine)
    }
}

struct FilledView: View {
    let asset: Asset
    let intent: OrderIntent
    let fill: Fill
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("Order filled").font(.title2.weight(.semibold))
            VStack(spacing: 10) {
                LabeledContent("Bought", value: "\(fill.quantity.formatted()) \(asset.symbol)")
                LabeledContent("Price", value: fill.price.formatted())
                LabeledContent("Amount", value: intent.amount.formatted())
                LabeledContent("Order ID", value: String(intent.clientOrderID.uuidString.prefix(8)))
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
            Spacer()
            Button(action: done) {
                Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct FailedView: View {
    let intent: OrderIntent
    let reason: FailureReason
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "xmark.octagon.fill").font(.system(size: 64)).foregroundStyle(.red)
            Text("Order not placed").font(.title2.weight(.semibold))
            Text(reason.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("No money was taken.").font(.subheadline.weight(.medium))
            Spacer()
            Button(action: retry) {
                Text("Try again with a new price").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            Button("Close", action: close)
        }
        .padding()
    }
}
