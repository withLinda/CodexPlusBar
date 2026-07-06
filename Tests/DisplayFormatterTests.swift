import Foundation
import Testing
@testable import CodexPlusBar

struct DisplayFormatterTests {
    @Test(arguments: [
        ("putrigildarahimah13@gmail.com", "putrig**ah13@gmail.com"),
        ("abcdefghij@outlook.com", "abc**ij@outlook.com"),
        ("abcdef@icloud.com", "a**f@icloud.com"),
        ("ab@hotmail.com", "**@hotmail.com"),
        ("Work account", "Work account"),
        ("not-an-email@", "not-an-email@"),
    ])
    func privateProfileLabelMasksEmailLocalPart(input: String, expected: String) {
        #expect(DisplayFormatter.privateProfileLabel(input) == expected)
    }

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
