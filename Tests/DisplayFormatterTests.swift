import Foundation
import Testing
@testable import CodexPlusBar

struct DisplayFormatterTests {
    @Test
    func expiryValueUsesLabelForCalmActiveDates() {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let value = DisplayFormatter.expiryValue(
            referenceDate.addingTimeInterval(TimeInterval(9 * 24 * 3_600)),
            referenceDate: referenceDate
        )

        #expect(value == DisplayFormatter.LabeledValue(label: "Expires in", value: "9d"))
    }

    @Test
    func expiryValueUsesLabelForWarningDates() {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let value = DisplayFormatter.expiryValue(
            referenceDate.addingTimeInterval(TimeInterval(5 * 24 * 3_600)),
            referenceDate: referenceDate
        )

        #expect(value == DisplayFormatter.LabeledValue(label: "Expires in", value: "5d"))
    }

    @Test
    func expiryValueFallsBackToSingleWordForExpiredDates() {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let value = DisplayFormatter.expiryValue(
            referenceDate.addingTimeInterval(-60),
            referenceDate: referenceDate
        )

        #expect(value == DisplayFormatter.LabeledValue(label: nil, value: "Expired"))
    }
}
