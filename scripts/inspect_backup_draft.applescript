-- Run the isolated preview with --details. The explicit fixture menu item reloads
-- the same profile ID with a new WebKit store ID. Cmd-R also belongs to Refresh.
tell application "System Events" to tell process "CodexPlusBarDesignPreview"
    set frontmost to true
    click menu item "Restore same profile fixture" of menu 1 of menu bar item "CodexPlusBarDesignPreview" of menu bar 1
    delay 0.5
    set elementsList to entire contents of window 1
    set notesEditor to missing value
    repeat with elementRef in elementsList
        set e to contents of elementRef
        if role of e is "AXTextArea" then set notesEditor to e
    end repeat
    if notesEditor is missing value then error "Notes editor is missing."
    if value of notesEditor is not "Restored notes must survive" then error "Pre-restore draft is still displayed."
    return "Same-profile restore replaced the mounted detail draft."
end tell
