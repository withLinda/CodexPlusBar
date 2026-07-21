import SwiftUI

struct LabeledValueText: View {
    let presentation: DisplayFormatter.LabeledValue
    let prefix: String
    let labelColor: Color
    let valueColor: Color
    let font: Font

    init(
        presentation: DisplayFormatter.LabeledValue,
        prefix: String = "",
        labelColor: Color,
        valueColor: Color,
        font: Font
    ) {
        self.presentation = presentation
        self.prefix = prefix
        self.labelColor = labelColor
        self.valueColor = valueColor
        self.font = font
    }

    var body: some View {
        if let label = presentation.label {
            let labelText = Text("\(prefix)\(label) ")
                .foregroundStyle(labelColor)
            let valueText = Text(presentation.value)
                .foregroundStyle(valueColor)
                .monospacedDigit()

            Text("\(labelText)\(valueText)")
                .font(font)
                .lineLimit(1)
        } else {
            Text("\(prefix)\(presentation.value)")
                .font(font)
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}
