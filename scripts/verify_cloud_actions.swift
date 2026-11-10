// Run against one isolated --cloud DesignPreview, never the installed app.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func elements(_ element: AXUIElement) -> [AXUIElement] {
    [element] + ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap(elements)
}
func text(_ element: AXUIElement) -> String {
    ["AXTitle", "AXDescription", "AXValue"].compactMap { attribute(element, $0) as? String }.joined(separator: " | ")
}
func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.linda.CodexPlusBar.DesignPreview")
require(AXIsProcessTrusted() && apps.count == 1, "Expected one accessible synthetic preview")
let app = apps[0], root = AXUIElementCreateApplication(apps[0].processIdentifier)
let label = "Import Browser saved session from Linda’s MacBook Air"
let empty = CommandLine.arguments.contains("--empty")
if empty {
    require(elements(root).contains { text($0).contains("No saved sessions available") }, "Empty inbox copy missing")
} else {
require(elements(root).contains { text($0).contains(label) }, "Import accessibility label missing")
require(!elements(root).contains { text($0).contains("Saved session ready.") }, "Feedback must start empty")
}
app.activate(options: [])
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
require(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, "Preview must be frontmost")
if empty {
    require(!elements(root).contains { text($0).contains(label) }, "Empty inbox has an import button")
} else if CommandLine.arguments.contains("--keyboard") {
    require(NSApplication.shared.isFullKeyboardAccessEnabled, "Enable system Keyboard navigation for this check")
    func key(_ code: CGKeyCode) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = []; event?.post(tap: .cghidEventTap)
        }
    }
    var reached = false
    for _ in 0..<100 {
        key(48)
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        if let focus = attribute(root, kAXFocusedUIElementAttribute), text(unsafeBitCast(focus, to: AXUIElement.self)).contains(label) {
            reached = true; break
        }
    }
    require(reached, "Tab did not reach the import control")
    key(49)
} else {
    let button = elements(root).first { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && text($0).contains(label) }!
    require(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success, "Import AXPress failed")
}
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
if !empty { require(elements(root).contains { text($0).contains("Saved session ready.") }, "Import did not produce feedback") }
if let index = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.indices.contains(index + 1) {
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    let window = windows.first {
        let bounds = $0[kCGWindowBounds as String] as? [String: NSNumber]
        return $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier &&
            $0[kCGWindowLayer as String] as? Int == 0 && (bounds?["Height"]?.doubleValue ?? 0) > 200
    }!
    let bounds = window[kCGWindowBounds as String] as! [String: NSNumber]
    let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -550, wheel2: 0, wheel3: 0)
    scroll?.location = CGPoint(x: bounds["X"]!.doubleValue + bounds["Width"]!.doubleValue * 0.8,
                               y: bounds["Y"]!.doubleValue + bounds["Height"]!.doubleValue * 0.6)
    scroll?.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(window[kCGWindowNumber as String] as! Int), CommandLine.arguments[index + 1]]
    try capture.run(); capture.waitUntilExit()
    require(capture.terminationStatus == 0, "Capture failed")
}
print(empty ? "PASS: empty inbox copy and no import action" : "PASS: exact import label, \(CommandLine.arguments.contains("--keyboard") ? "Tab/Space" : "AXPress"), and import feedback")
