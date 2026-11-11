import SwiftUI

struct AssetDetailView: View {
    let asset: Asset
    @Environment(PriceStore.self) private var prices
    @Environment(OrderStore.self) private var orders
    @State private var showingBuy = false

    var body: some View {
        let tick = prices.tick(for: asset.id)
        let stale = prices.isStale(asset.id)
        let bp = prices.changeBasisPoints(for: asset)
        let orderState = orders.state(for: asset.id)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    AssetBadge(symbol: asset.symbol, kind: asset.kind)
                    VStack(alignment: .leading) {
                        Text(asset.name).font(.title3.weight(.semibold))
                        Text(asset.kind == .stock ? "Tokenized stock" : "Crypto")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(tick?.price.formatted() ?? "—")
                        .font(.system(size: 44, weight: .bold).monospacedDigit())
                        .foregroundStyle(stale ? .secondary : .primary)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Price \(tick?.price.formatted() ?? "unavailable")")
                    HStack(spacing: 8) {
                        if let bp {
                            Text("\(PriceChange.formatted(basisPoints: bp)) today")
                                .foregroundStyle(bp > 0 ? .green : (bp < 0 ? .red : .secondary))
                        }
                        if stale {
                            StaleBadge(text: prices.secondsSinceUpdate(asset.id).map { "Updated \($0)s ago" } ?? "No price")
                        } else {
                            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption.weight(.medium)).foregroundStyle(.green)
                        }
                    }
                    .font(.subheadline.monospacedDigit())
                }

                Divider()

                LabeledContent("Previous close", value: asset.previousClose.formatted())
                LabeledContent("Buying power", value: BuyViewModel.mockBalance.formatted())

                if orderState.isUnresolved {
                    Label("You have an order in progress. Buying is paused until it settles.",
                          systemImage: "hourglass")
                        .font(.subheadline)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.1)))
                        .onTapGesture { showingBuy = true }
                } else if let reason = buyDisabledReason(stale: stale) {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                showingBuy = true
            } label: {
                Text(orderState.isUnresolved ? "View order" : "Buy \(asset.symbol)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!orderState.isUnresolved && buyDisabledReason(stale: stale) != nil)
            .padding()
            .background(.bar)
            .accessibilityHint("Opens the buy flow")
        }
        .navigationTitle(asset.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingBuy, onDismiss: {
            // Settled or never submitted → clear; in-flight orders keep running in the store.
            if !orders.state(for: asset.id).isUnresolved { orders.reset(asset.id) }
        }) {
            BuyFlowView(viewModel: BuyViewModel(asset: asset, prices: prices, orders: orders))
        }
    }

    private func buyDisabledReason(stale: Bool) -> String? {
        if !prices.isOnline { return "You're offline. Buying is unavailable." }
        if stale { return "Price is delayed. Buying is paused until it updates." }
        return nil
    }
}
