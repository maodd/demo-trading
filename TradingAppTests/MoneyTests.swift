import Testing
import Foundation
@testable import TradingApp

struct MoneyTests {
    @Test func parsesUserInput() {
        #expect(Money.parse("12.34") == Money(micros: 12_340_000))
        #expect(Money.parse("1,000") == Money.dollars(1_000))
        #expect(Money.parse(".5") == Money(micros: 500_000))
        #expect(Money.parse("12.") == Money.dollars(12))
    }

    @Test func rejectsInvalidInput() {
        #expect(Money.parse("") == nil)
        #expect(Money.parse("abc") == nil)
        #expect(Money.parse("1.234") == nil) // > 2 decimals
        #expect(Money.parse("1.2.3") == nil)
        #expect(Money.parse("-5") == nil)
        #expect(Money.parse("9999999999999") == nil) // too many digits
    }

    @Test func formatsCurrency() {
        #expect(Money(micros: 1_234_567_890).formatted() == "$1,234.57")
        #expect(Money.zero.formatted() == "$0.00")
    }

    @Test func quantityRoundsDown() {
        // $100 / $3 = 33.333333333… → 33.33333333 (never rounded up)
        let qty = Quantity.forAmount(.dollars(100), at: .dollars(3))
        #expect(qty?.units == 3_333_333_333)
        #expect(qty?.formatted() == "33.33333333")
    }

    @Test func quantityForExpensiveAsset() {
        // $50 of BTC at $104,250.00
        let qty = Quantity.forAmount(.dollars(50), at: .dollars(104_250))
        #expect(qty?.units == 47_961) // 0.00047961… rounded down
        #expect(qty?.formatted() == "0.00047961")
    }

    @Test func quantityLargeAmountDoesNotOverflow() {
        // 1e12 micros * 1e8 overflows Int64; full-width math must handle it.
        let qty = Quantity.forAmount(.dollars(1_000_000), at: Money(micros: 720_000))
        #expect(qty != nil)
        #expect(qty!.units == 138_888_888_888_888)
    }

    @Test func quantityRejectsZeroPrice() {
        #expect(Quantity.forAmount(.dollars(10), at: .zero) == nil)
    }

    @Test func percentChangeInBasisPoints() {
        #expect(PriceChange.basisPoints(from: .dollars(100), to: Money(micros: 101_230_000)) == 123)
        #expect(PriceChange.formatted(basisPoints: 123) == "+1.23%")
        #expect(PriceChange.formatted(basisPoints: -40) == "−0.40%")
        #expect(PriceChange.formatted(basisPoints: 0) == "0.00%")
    }
}
