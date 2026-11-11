import Foundation

/// All money / quantity conversions live in this file (PLAN.md §3).
/// Values are integer fixed-point; `Decimal` is used only at the formatting edge.

/// Money in micros: 1 USD = 1_000_000 micros.
struct Money: Hashable, Comparable, Sendable, Codable {
    static let microsPerUnit: Int64 = 1_000_000

    var micros: Int64
    var currency: String = "USD"

    init(micros: Int64, currency: String = "USD") {
        self.micros = micros
        self.currency = currency
    }

    static func dollars(_ whole: Int64) -> Money { Money(micros: whole * microsPerUnit) }
    static let zero = Money(micros: 0)

    static func < (lhs: Money, rhs: Money) -> Bool { lhs.micros < rhs.micros }

    /// Parses user input like "1,234.56" into micros. Returns nil for invalid input,
    /// more than `maxFractionDigits` decimals, or values that would overflow.
    static func parse(_ text: String, maxFractionDigits: Int = 2) -> Money? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intPart = parts[0].isEmpty ? "0" : String(parts[0])
        let fracPart = parts.count == 2 ? String(parts[1]) : ""
        let isDigits: (String) -> Bool = { $0.allSatisfy { $0.isASCII && $0.isNumber } }
        guard isDigits(intPart), isDigits(fracPart),
              fracPart.count <= maxFractionDigits, intPart.count <= 12,
              let whole = Int64(intPart),
              let frac = Int64(fracPart.padding(toLength: 6, withPad: "0", startingAt: 0))
        else { return nil }
        let (scaled, o1) = whole.multipliedReportingOverflow(by: microsPerUnit)
        let (total, o2) = scaled.addingReportingOverflow(frac)
        guard !o1, !o2 else { return nil }
        return Money(micros: total)
    }

    /// Formatting helper — the only place money becomes a string.
    func formatted() -> String {
        let value = Decimal(micros) / Decimal(Money.microsPerUnit)
        return value.formatted(
            .currency(code: currency)
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(2))
        )
    }

    /// Rounds to whole cents (used by the mock feed so the displayed price is the traded price).
    func roundedToCents() -> Money {
        let cent: Int64 = 10_000
        let rounded = (micros + cent / 2) / cent * cent
        return Money(micros: rounded, currency: currency)
    }
}

/// Asset quantity in 1e-8 units.
struct Quantity: Hashable, Comparable, Sendable, Codable {
    static let unitsPerWhole: Int64 = 100_000_000
    static let zero = Quantity(units: 0)

    var units: Int64

    static func < (lhs: Quantity, rhs: Quantity) -> Bool { lhs.units < rhs.units }

    /// `amount / price`, rounded DOWN (never over-credit). Nil for a non-positive price or overflow.
    static func forAmount(_ amount: Money, at price: Money) -> Quantity? {
        guard price.micros > 0, amount.micros >= 0 else { return nil }
        // Guard the quotient fits in Int64 before the full-width divide.
        guard amount.micros / price.micros < Int64.max / unitsPerWhole - 1 else { return nil }
        let product = amount.micros.multipliedFullWidth(by: unitsPerWhole)
        let (quotient, _) = price.micros.dividingFullWidth(product)
        return Quantity(units: quotient)
    }

    /// e.g. "0.00123456" — trailing zeros trimmed, display only.
    func formatted() -> String {
        let whole = units / Quantity.unitsPerWhole
        let frac = units % Quantity.unitsPerWhole
        var fracString = String(frac)
        fracString = String(repeating: "0", count: max(0, 8 - fracString.count)) + fracString
        while fracString.hasSuffix("0") { fracString.removeLast() }
        let wholeString = whole.formatted(.number.locale(Locale(identifier: "en_US")))
        return fracString.isEmpty ? wholeString : "\(wholeString).\(fracString)"
    }
}

enum PriceChange {
    /// Change in basis points (1% = 100 bp), integer math, truncated toward zero.
    static func basisPoints(from reference: Money, to current: Money) -> Int64? {
        guard reference.micros > 0 else { return nil }
        return (current.micros - reference.micros) * 10_000 / reference.micros
    }

    /// e.g. "+1.23%" / "−0.40%"
    static func formatted(basisPoints bp: Int64) -> String {
        let sign = bp > 0 ? "+" : (bp < 0 ? "−" : "")
        let magnitude = bp.magnitude
        let cents = magnitude % 100
        return "\(sign)\(magnitude / 100).\(cents < 10 ? "0" : "")\(cents)%"
    }
}
