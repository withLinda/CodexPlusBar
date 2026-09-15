-- Run with the isolated native preview open: bash scripts/render_design.sh --details
-- This checks real AppKit focus and typing; the Swift Testing suite covers models/tokens.
tell application "System Events" to tell process "CodexPlusBarDesignPreview"
    set frontmost to true
    set elementsList to entire contents of window 1
    set notesEditor to missing value
    repeat with elementRef in elementsList
        set e to contents of elementRef
        if role of e is "AXTextArea" then set notesEditor to e
    end repeat
    if notesEditor is missing value then error "Open the preview with --details first."

    set value of attribute "AXFocused" of notesEditor to true
    keystroke "a" using command down
    keystroke "Short note"
    set size of window 1 to {900, 600}
    delay 0.3
    keystroke " after resize"
    keystroke "t" using command down
    delay 0.3
    keystroke " after theme"
    if value of notesEditor is not "Short note after resize after theme" then error "Short draft lost input."
    if value of attribute "AXFocused" of notesEditor is not true then error "Short editor lost focus."

    keystroke "a" using command down
    set longText to ""
    repeat with i from 1 to 24
        set longText to longText & "Review note " & i & return
    end repeat
    keystroke longText
    set size of window 1 to {1000, 680}
    delay 0.3
    keystroke "After expansion"
    set size of window 1 to {900, 600}
    delay 0.3
    keystroke " and compact resize"
    keystroke "t" using command down
    delay 0.3
    keystroke " and theme change"
    if (value of notesEditor) does not end with "After expansion and compact resize and theme change" then error "Long draft lost input."
    if value of attribute "AXFocused" of notesEditor is not true then error "Long editor lost focus."
    return "Short and long drafts retained focus and accepted input after resize and theme changes; inspect the final caret screenshot."
end tell
