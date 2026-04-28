import Foundation

enum MenuBarPanelTextScalePreference {
    static let textScaleKey = "MenuBarPanelTextScale"
    static let defaultScale = 1.0
    static let minimumScale = 0.9
    static let maximumScale = 1.35
    static let step = 0.1

    static func textScale(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: textScaleKey) != nil else {
            return defaultScale
        }

        return normalizedTextScale(defaults.double(forKey: textScaleKey))
    }

    static func setTextScale(_ value: Double, defaults: UserDefaults = .standard) {
        defaults.set(normalizedTextScale(value), forKey: textScaleKey)
    }

    static func zoomIn(defaults: UserDefaults = .standard) {
        setTextScale(zoomedInValue(from: textScale(defaults: defaults)), defaults: defaults)
    }

    static func zoomOut(defaults: UserDefaults = .standard) {
        setTextScale(zoomedOutValue(from: textScale(defaults: defaults)), defaults: defaults)
    }

    static func zoomedInValue(from value: Double) -> Double {
        normalizedTextScale(value + step)
    }

    static func zoomedOutValue(from value: Double) -> Double {
        normalizedTextScale(value - step)
    }

    static func normalizedTextScale(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultScale
        }

        let roundedToStep = (value / step).rounded() * step
        return min(max(roundedToStep, minimumScale), maximumScale)
    }
}
