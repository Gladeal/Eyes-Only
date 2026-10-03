#!/bin/bash
# Double-click this if Eyes Only keeps asking for Screen Recording permission.
# It removes the download quarantine (which makes macOS run the app from a random read-only copy,
# so the permission never sticks), clears any stale permission, and opens the app.
# If macOS blocks this file, right-click it and choose Open.

APP="/Applications/Eyes Only.app"
[ -d "$APP" ] || APP="$(cd "$(dirname "$0")" && pwd)/Eyes Only.app"

echo "Using: $APP"
echo "Quitting Eyes Only if it's running ..."
osascript -e 'tell application id "com.eyesonly.app" to quit' 2>/dev/null
sleep 1
echo "Removing the download quarantine ..."
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
xattr -dr com.apple.quarantine "$0" 2>/dev/null
echo "Clearing any stale Screen Recording permission ..."
tccutil reset ScreenCapture com.eyesonly.app 2>/dev/null
echo "Opening the app ..."
open "$APP"
echo
echo "NOW: when asked, turn ON Screen Recording for Eyes Only,"
echo "then QUIT the app (eye icon → Quit) and open it once more."
