// Run only with one synthetic DesignPreview; checks real native controls.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func text(_ element: AXUIElement) -> String {
    ["AXTitle", "AXDescription", "AXValue"].compactMap { attribute(element, $0) as? String }.joined(separator: " | ")
}
func elements(_ root: AXUIElement) -> [AXUIElement] {
    [root] + (attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(elements)
}
func bounds(_ element: AXUIElement) -> CGRect {
    var point = CGPoint.zero, size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) }
    if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) }
    return CGRect(origin: point, size: size)
}
func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.linda.CodexPlusBar.DesignPreview")
require(apps.count == 1, "Launch exactly one synthetic preview")
let app = apps[0], root = AXUIElementCreateApplication(apps[0].processIdentifier)
let windows = attribute(root, kAXWindowsAttribute) as! [AXUIElement]
let windowBounds = bounds(windows[0])
func button(_ label: String) -> AXUIElement {
    let match = elements(root).first { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && text($0).components(separatedBy: " | ").contains(label) }
    require(match != nil, "Missing button: \(label)")
    return match!
}
let refresh = button("Refresh"), remove = button("Remove profile"), sync = button("Sync OpenChamber now")
for control in [refresh, remove, sync] {
    require(windowBounds.contains(bounds(control)), "Control outside window: \(text(control))")
    require(bounds(control).width > 30 && bounds(control).height >= 24, "Control compressed")
}
require(bounds(refresh).maxX <= bounds(remove).minX, "Remove must follow Refresh")
require(abs(bounds(refresh).midY - bounds(remove).midY) < 2, "Actions not in one row")
require(elements(root).map(text).joined().contains("s**o@example.com"), "Expected disposable profile")
if CommandLine.arguments.contains("--keyboard") {
    require(NSApplication.shared.isFullKeyboardAccessEnabled, "Enable keyboard navigation for this check")
    app.activate(options: [])
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    require(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, "Preview must be frontmost")
    var reached = false
    for _ in 0..<60 {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: down)
            event?.flags = []; event?.post(tap: .cghidEventTap)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let focused = attribute(root, kAXFocusedUIElementAttribute), text(unsafeBitCast(focused, to: AXUIElement.self)).contains("Remove profile") { reached = true; break }
    }
    require(reached, "Tab did not reach Remove")
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: down)
        event?.flags = []; event?.post(tap: .cghidEventTap)
    }
} else {
    require(AXUIElementPerformAction(remove, kAXPressAction as CFString) == .success, "Remove AXPress failed")
}
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
require(!elements(root).map(text).joined().contains("s**o@example.com"), "Disposable profile was not removed directly")
require(AXUIElementPerformAction(button("Sync OpenChamber now"), kAXPressAction as CFString) == .success, "Sync AXPress failed")
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
require(elements(root).map(text).joined().contains("profiles linked"), "Synthetic sync result missing")
print("PASS: \(Int(windowBounds.width))×\(Int(windowBounds.height)) actions fit, Remove \(CommandLine.arguments.contains("--keyboard") ? "Tab/Space" : "AXPress") removed the disposable profile, Sync now published fixture status")
