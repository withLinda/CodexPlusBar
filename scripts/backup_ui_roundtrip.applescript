-- Usage: osascript scripts/backup_ui_roundtrip.applescript export|restore /absolute/backup/path
-- Operates only on the synthetic CodexPlusBarDesignPreview host.
on run argv
    set mode to item 1 of argv
    set backupPath to item 2 of argv
    tell application "System Events" to tell process "CodexPlusBarDesignPreview"
        set frontmost to true
        set elementsList to entire contents of window 1
        set fields to {}
        set submit to missing value
        repeat with elementRef in elementsList
            set e to contents of elementRef
            if role of e is "AXTextField" then set end of fields to e
            if role of e is "AXButton" then
                try
                    if value of attribute "AXIdentifier" of e is "backup.submit" then set submit to e
                end try
            end if
        end repeat
        set value of attribute "AXFocused" of item 1 of fields to true
        keystroke "a" using command down
        keystroke "synthetic-test-password"
        if mode is "export" then
            key code 36
            keystroke "synthetic-test-password"
        end if
        delay 0.2
        click submit
        if mode is "export" then
            delay 0.5
            keystroke "g" using {command down, shift down}
            delay 0.3
            keystroke backupPath
            key code 36
            delay 0.4
            key code 36
        else
            repeat 100 times
                set restoreButton to missing value
                set elementsList to entire contents of window 1
                repeat with elementRef in elementsList
                    set e to contents of elementRef
                    try
                        if value of attribute "AXIdentifier" of e is "backup.restore" then set restoreButton to e
                    end try
                end repeat
                if restoreButton is not missing value then exit repeat
                delay 0.1
            end repeat
            if restoreButton is missing value then error "Backup never reached validated preview."
            click restoreButton
        end if
        repeat 100 times
            set elementsList to entire contents of window 1
            repeat with elementRef in elementsList
                try
                    set e to contents of elementRef
                    if role of e is "AXStaticText" then
                        set textValue to value of e
                        if mode is "export" and textValue is "Backup ready" then return "Real native export completed."
                        if mode is "restore" and textValue is "Welcome to your new Mac" then return "Real native restore completed."
                    end if
                end try
            end repeat
            delay 0.1
        end repeat
        error "Workflow did not reach success; inspect the preview."
    end tell
end run
