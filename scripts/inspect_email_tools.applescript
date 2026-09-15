-- Run the isolated preview with --email-tools --compact first.
-- Enable macOS Keyboard navigation for the Tab/Space check, then restore your preference.
on controlWithID(identifier)
    tell application "System Events" to tell process "CodexPlusBarDesignPreview"
        set elementsList to entire contents of window 1
        repeat with elementRef in elementsList
            set e to contents of elementRef
            try
                set candidate to value of attribute "AXIdentifier" of e
            on error
                set candidate to ""
            end try
            if candidate is identifier then return e
        end repeat
    end tell
    error "Missing preview control: " & identifier
end controlWithID

tell application "System Events" to tell process "CodexPlusBarDesignPreview"
    set frontmost to true
    keystroke "b" using {command down, shift down}
end tell
try
    tell application "System Events" to tell process "CodexPlusBarDesignPreview"
        set frontmost to true
        set firstToggle to my controlWithID("email-tools.used.d.esignreview@gmail.com")
        if role of firstToggle is not "AXCheckBox" then error "Used state lost checkbox semantics"
        if value of firstToggle is not 1 then error "Unexpected initial fixture state"
        perform action "AXPress" of firstToggle
        delay 0.2
        if value of (my controlWithID("email-tools.used.d.esignreview@gmail.com")) is not 0 then error "Accessibility toggle failed"

        set value of attribute "AXFocused" of (my controlWithID("email-tools.input")) to true
        set foundKeyboardTarget to false
        repeat 40 times
            key code 48
            delay 0.08
            set focusedControl to value of attribute "AXFocusedUIElement"
            try
                set focusedID to value of attribute "AXIdentifier" of focusedControl
            on error
                set focusedID to ""
            end try
            if focusedID is "email-tools.used.des.ignreview@gmail.com" then
                set foundKeyboardTarget to true
                exit repeat
            end if
        end repeat
        if not foundKeyboardTarget then error "Checkbox was not reached by Tab; enable macOS Keyboard navigation."
        keystroke space
        delay 0.2
        if value of (my controlWithID("email-tools.used.des.ignreview@gmail.com")) is not 1 then error "Space did not toggle the focused checkbox"

        perform action "AXPress" of (my controlWithID("email-tools.copy.d.esignreview@gmail.com"))
        delay 0.2
    end tell
    if (the clipboard as text) is not "d.esignreview@gmail.com" then error "Copy address failed"

    tell application "System Events" to tell process "CodexPlusBarDesignPreview"
        perform action "AXPress" of (my controlWithID("email-tools.copy-unused"))
        delay 0.2
    end tell
    set copiedAddresses to the clipboard as text
    if copiedAddresses does not contain "d.esignreview@gmail.com" then error "Unused address missing from copy"
    if copiedAddresses contains "de.signreview@gmail.com" then error "Used address was copied as unused"
    if copiedAddresses contains "des.ignreview@gmail.com" then error "Newly used address was copied as unused"

    tell application "System Events" to tell process "CodexPlusBarDesignPreview"
        set filterField to my controlWithID("email-tools.filter")
        set value of attribute "AXFocused" of filterField to true
        keystroke "design.review"
        set size of window 1 to {900, 620}
        delay 0.2
        set size of window 1 to {760, 520}
        keystroke "t" using command down
        delay 0.3
        keystroke "x"
        if value of filterField is not "design.reviewx" then error "Filter lost typing after resize/theme change"
        if value of attribute "AXFocused" of filterField is not true then error "Filter lost focus"
        key code 51

        set inputField to my controlWithID("email-tools.input")
        set value of attribute "AXFocused" of inputField to true
        keystroke "newmailbox"
        key code 36
        delay 0.2
        set generatedSession to my controlWithID("email-tools.session.newmailbox@gmail.com")
        keystroke "resume"
        if value of inputField is not "resume" then error "Generate reset input focus"
    end tell
on error errorText number errorNumber
    tell application "System Events" to tell process "CodexPlusBarDesignPreview" to keystroke "k" using {command down, shift down}
    error errorText number errorNumber
end try
tell application "System Events" to tell process "CodexPlusBarDesignPreview" to keystroke "k" using {command down, shift down}
return "Checkbox AX/Space actions, copy, unused-copy exclusion, search, generate, and resize/theme typing passed; clipboard restored."
