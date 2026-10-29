-- Synthetic preview only: verifies real secure-field focus, typing, theme transition,
-- submit enablement and the native save panel without touching live profile data.
tell application "System Events" to tell process "CodexPlusBarDesignPreview"
    set frontmost to true
    set fields to {}
    set exportButton to missing value
    set elementsList to entire contents of window 1
    repeat with elementRef in elementsList
        set e to contents of elementRef
        if role of e is "AXTextField" then set end of fields to e
        if role of e is "AXButton" then
            try
                if value of attribute "AXIdentifier" of e is "backup.submit" then set exportButton to e
            end try
        end if
    end repeat
    if (count of fields) is not 2 then error "Expected password and confirmation fields."
    if exportButton is missing value then error "Export action missing."
    if enabled of exportButton then error "Empty passwords must not enable export."
    set value of attribute "AXFocused" of item 1 of fields to true
    keystroke "synthetic-test-password"
    key code 36
    delay 0.2
    keystroke "synthetic-test-password"
    delay 0.2
    if not enabled of exportButton then error "Matching secure fields did not enable export."
    keystroke "t" using command down
    delay 0.3
    if not enabled of exportButton then error "Theme transition lost secure input."
    click exportButton
    delay 0.5
    if (count of sheets of window 1) is 0 then error "Native save panel did not appear."
    key code 53
    return "Password typing, Return focus, theme preservation, submit validation and native save panel passed."
end tell
