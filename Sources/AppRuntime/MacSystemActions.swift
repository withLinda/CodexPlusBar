import AppKit

@MainActor
enum MacSystemActions {
    @discardableResult
    static func copyToPasteboard(_ text: String) -> Bool {
        guard text.isEmpty == false else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    static func open(_ url: URL?) -> Bool {
        guard let url else {
            return false
        }

        return NSWorkspace.shared.open(url)
    }
}
