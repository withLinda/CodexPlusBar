import Foundation
import Testing
@testable import CodexPlusBar

struct MenuBarPanelTextScalePreferenceTests {
    @Test
    func missingPreferenceUsesDefaultScale() {
        let (defaults, suiteName) = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(MenuBarPanelTextScalePreference.textScale(defaults: defaults) == 1.0)
    }

    @Test
    func storedPreferenceIsClampedToReadableRange() {
        let (defaults, suiteName) = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MenuBarPanelTextScalePreference.setTextScale(9, defaults: defaults)
        #expect(MenuBarPanelTextScalePreference.textScale(defaults: defaults) == 1.35)

        MenuBarPanelTextScalePreference.setTextScale(0.1, defaults: defaults)
        #expect(MenuBarPanelTextScalePreference.textScale(defaults: defaults) == 0.9)
    }

    @Test
    func zoomButtonsMoveByOneStepAndClampAtBounds() {
        let (defaults, suiteName) = makeUserDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        MenuBarPanelTextScalePreference.setTextScale(1.0, defaults: defaults)
        MenuBarPanelTextScalePreference.zoomIn(defaults: defaults)
        #expect(MenuBarPanelTextScalePreference.textScale(defaults: defaults) == 1.1)

        MenuBarPanelTextScalePreference.zoomOut(defaults: defaults)
        MenuBarPanelTextScalePreference.zoomOut(defaults: defaults)
        #expect(MenuBarPanelTextScalePreference.textScale(defaults: defaults) == 0.9)

        MenuBarPanelTextScalePreference.zoomOut(defaults: defaults)
        #expect(MenuBarPanelTextScalePreference.textScale(defaults: defaults) == 0.9)
    }
}

private func makeUserDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "CodexPlusBarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
