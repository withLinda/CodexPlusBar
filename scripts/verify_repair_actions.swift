// Native Accessibility smoke check. Mutations are restricted to synthetic preview services.
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
let live = CommandLine.arguments.contains("--live-read-only")
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: live ? "com.linda.CodexPlusBar" : "com.linda.CodexPlusBar.DesignPreview")
    .filter { !live || $0.bundleURL?.path == "/Applications/CodexPlusBar.app" }
guard AXIsProcessTrusted(), apps.count == 1, let app = apps.first else { fatalError("Expected one accessible target app") }
let root = AXUIElementCreateApplication(app.processIdentifier)
func button(_ label: String) -> AXUIElement {
    let matches = elements(root).filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && text($0).contains(label) }
    guard matches.count == 1 else { fatalError("Expected one \(label) button") }
    return matches[0]
}
func press(_ label: String) {
    guard !live, AXUIElementPerformAction(button(label), kAXPressAction as CFString) == .success else { fatalError("Preview press failed") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
}
func keyboardPressRepair() {
    guard !live, NSApplication.shared.isFullKeyboardAccessEnabled else { fatalError("Enable keyboard navigation for this check") }
    app.activate(options: [])
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { fatalError("Preview is not frontmost") }
    let source = CGEventSource(stateID: .combinedSessionState)
    func key(_ code: CGKeyCode) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
    }
    for _ in 0..<60 {
        key(48)
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        if let focused = attribute(root, kAXFocusedUIElementAttribute),
           text(unsafeBitCast(focused, to: AXUIElement.self)).contains("Repair both app sign-ins") {
            key(49)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            return
        }
    }
    fatalError("Keyboard did not reach Repair both")
}
if let index = CommandLine.arguments.firstIndex(of: "--capture-scrolled"), !live,
   CommandLine.arguments.indices.contains(index + 1) {
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    guard let window = windows.first(where: {
        let bounds = $0[kCGWindowBounds as String] as? [String: NSNumber]
        return $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier
            && $0[kCGWindowLayer as String] as? Int == 0 && (bounds?["Height"]?.doubleValue ?? 0) > 200
    }), let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
          let number = window[kCGWindowNumber as String] as? Int else { fatalError("Preview window missing") }
    let point = CGPoint(x: (bounds["X"]?.doubleValue ?? 0) + (bounds["Width"]?.doubleValue ?? 0) * 0.8,
                        y: (bounds["Y"]?.doubleValue ?? 0) + (bounds["Height"]?.doubleValue ?? 0) * 0.7)
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -270, wheel2: 0, wheel3: 0)
    event?.location = point
    event?.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(number), CommandLine.arguments[index + 1]]
    try capture.run(); capture.waitUntilExit()
    guard capture.terminationStatus == 0 else { fatalError("Capture failed") }
}
if live {
    _ = button("Repair both app sign-ins")
    print("PASS: installed Repair both control is visible (read-only)")
} else if CommandLine.arguments.contains("--cancel") {
    for label in ["Switch and open ChatGPT / Codex", "Switch OpenChamber", "Check all OpenChamber sign-ins", "Sync OpenChamber now"] {
        let matches = elements(root).filter { attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && text($0).contains(label) }
        guard matches.count == 1 else { fatalError("Expected one competing \(label) control") }
        for control in matches {
            guard attribute(control, kAXEnabledAttribute) as? Bool == false else { fatalError("Competing action remained enabled") }
        }
    }
    press("Cancel app sign-in repair")
    _ = button("Repair both app sign-ins")
    guard elements(root).contains(where: { text($0).contains("Repair cancelled.") }) else { fatalError("Cancellation result missing") }
    print("PASS: competing actions disabled; Cancel restores Repair both with cancellation feedback")
} else {
    guard !elements(root).contains(where: { text($0).contains("Both app sign-ins updated.") }) else { fatalError("Success was already present") }
    if CommandLine.arguments.contains("--keyboard") { keyboardPressRepair() }
    else { press("Repair both app sign-ins") }
    guard elements(root).contains(where: { text($0).contains("Both app sign-ins updated.") }) else { fatalError("Repair result missing") }
    print("PASS: Repair both invokes the controller and reports both saved sign-ins")
}
