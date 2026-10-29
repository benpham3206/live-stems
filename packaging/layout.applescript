on run argv
    set imageFolder to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        tell folder (imageFolder as text)
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {160, 140, 880, 720}
            set options to icon view options of container window
            set arrangement of options to not arranged
            set icon size of options to 112
            set text size of options to 13
            set background picture of options to file ".background:background.png"
            set position of item "Live Stems.app" of container window to {185, 235}
            set position of item "Applications" of container window to {535, 235}
            update without registering applications
        end tell
    end tell
end run
