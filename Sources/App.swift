import SwiftUI

@main
struct CodexPlusBar: App {
    @NSApplicationDelegateAdaptor(CodexAppDelegate.self) private var appDelegate
    @State private var appRuntime: AppRuntimeController

    init() {
        CodexFontRegistry.registerBundledFonts()
        let appRuntime = AppRuntimeController()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            appRuntime.start()
        }
        _appRuntime = State(initialValue: appRuntime)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
