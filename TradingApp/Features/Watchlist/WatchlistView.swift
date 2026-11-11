import SwiftUI

struct WatchlistView: View {
    let viewModel: WatchlistViewModel
    @Environment(DebugSettings.self) private var debug

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Watchlist")
                .navigationDestination(for: AssetID.self) { id in
                    if let asset = AssetCatalog.asset(id) {
                        AssetDetailView(asset: asset)
                    }
                }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { DebugMenu() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            List {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonRow()
                }
            }
            .redacted(reason: .placeholder)
            .accessibilityLabel("Loading prices")
        case .loaded(let sections), .offline(let sections):
            List {
                if let banner = viewModel.banner {
                    BannerView(banner: banner)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            NavigationLink(value: row.id) { WatchlistRow(row: row) }
                        }
                    }
                }
            }
            .animation(.default, value: viewModel.banner)
        case .empty:
            ContentUnavailableView("No assets", systemImage: "list.bullet",
                                   description: Text("Your watchlist is empty."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load prices", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { viewModel.retry() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct WatchlistRow: View {
    let row: WatchlistViewModel.Row

    var body: some View {
        HStack(spacing: 12) {
            AssetBadge(symbol: row.symbol, kind: row.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.symbol).font(.headline)
                Text(row.name).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.price)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(row.isStale ? .secondary : .primary)
                    .contentTransition(.numericText())
                if let stale = row.staleText {
                    StaleBadge(text: stale)
                } else if let change = row.change {
                    Text(change)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(row.changeSign > 0 ? .green : (row.changeSign < 0 ? .red : .secondary))
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.price), \(row.staleText ?? row.change ?? "")")
    }
}

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().frame(width: 36, height: 36)
            VStack(alignment: .leading) { Text("XXXX"); Text("Asset name") }
            Spacer()
            VStack(alignment: .trailing) { Text("$000.00"); Text("+0.00%") }
        }
    }
}

struct AssetBadge: View {
    let symbol: String
    let kind: AssetKind

    var body: some View {
        Text(String(symbol.prefix(1)))
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(kind == .crypto ? Color.orange.gradient : Color.blue.gradient))
            .accessibilityHidden(true)
    }
}

struct StaleBadge: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "clock.badge.exclamationmark")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.gray.opacity(0.18)))
            .foregroundStyle(.secondary)
    }
}

struct BannerView: View {
    let banner: WatchlistViewModel.Banner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text).font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.15)))
        .foregroundStyle(color)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch banner {
        case .offline: "You're offline — showing last known prices."
        case .delayed: "Prices delayed. Reconnecting…"
        case .partial(let n): "\(n) price\(n == 1 ? "" : "s") delayed — buying paused for \(n == 1 ? "it" : "them")."
        }
    }

    private var icon: String {
        switch banner {
        case .offline: "wifi.slash"
        case .delayed: "exclamationmark.triangle.fill"
        case .partial: "clock.badge.exclamationmark"
        }
    }

    private var color: Color {
        switch banner {
        case .offline, .delayed: .orange
        case .partial: .gray
        }
    }
}

struct DebugMenu: View {
    @Environment(DebugSettings.self) private var debug

    var body: some View {
        @Bindable var debug = debug
        Menu {
            Toggle("Offline", isOn: $debug.isOffline)
            Toggle("Price feed disconnected", isOn: $debug.isFeedDisconnected)
            Picker("Next order outcome", selection: $debug.forcedOutcome) {
                ForEach(MockOrderAPI.Outcome.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: "ladybug")
        }
        .accessibilityLabel("Debug settings")
    }
}
