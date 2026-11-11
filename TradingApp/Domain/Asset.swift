import Foundation

/// Stable identity for an asset. Never use display names as identity.
struct AssetID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

enum AssetKind: String, Sendable, Codable, CaseIterable {
    case stock
    case crypto

    var sectionTitle: String {
        switch self {
        case .stock: "Tokenized stocks"
        case .crypto: "Crypto"
        }
    }
}

struct Asset: Identifiable, Hashable, Sendable {
    let id: AssetID
    let kind: AssetKind
    let symbol: String
    let name: String
    /// Reference price for the daily change.
    let previousClose: Money
}

/// Hardcoded list of ~10 assets (see PLAN.md §2).
enum AssetCatalog {
    static let all: [Asset] = [
        Asset(id: AssetID("AAPL"), kind: .stock, symbol: "AAPL", name: "Apple", previousClose: .dollars(231)),
        Asset(id: AssetID("TSLA"), kind: .stock, symbol: "TSLA", name: "Tesla", previousClose: .dollars(342)),
        Asset(id: AssetID("NVDA"), kind: .stock, symbol: "NVDA", name: "NVIDIA", previousClose: .dollars(178)),
        Asset(id: AssetID("MSFT"), kind: .stock, symbol: "MSFT", name: "Microsoft", previousClose: .dollars(512)),
        Asset(id: AssetID("SPY"), kind: .stock, symbol: "SPY", name: "S&P 500 ETF", previousClose: .dollars(668)),
        Asset(id: AssetID("BTC"), kind: .crypto, symbol: "BTC", name: "Bitcoin", previousClose: .dollars(104_250)),
        Asset(id: AssetID("ETH"), kind: .crypto, symbol: "ETH", name: "Ethereum", previousClose: .dollars(3_480)),
        Asset(id: AssetID("SOL"), kind: .crypto, symbol: "SOL", name: "Solana", previousClose: .dollars(162)),
        Asset(id: AssetID("LINK"), kind: .crypto, symbol: "LINK", name: "Chainlink", previousClose: .dollars(16)),
        Asset(id: AssetID("ONDO"), kind: .crypto, symbol: "ONDO", name: "Ondo", previousClose: Money(micros: 720_000)),
    ]

    static func asset(_ id: AssetID) -> Asset? { all.first { $0.id == id } }
}
