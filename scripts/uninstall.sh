#!/bin/sh
# Remove shelf and open Ice if it is installed. Keeps ~/.shelf (the layout memory and logs).
LABEL=com.aaqifz.shelf
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/shelf"
rm -rf "$HOME/Applications/Shelf.app"
open -b com.jordanbaird.Ice 2>/dev/null || true
echo "shelf removed. Memory and logs kept in ~/.shelf/"
