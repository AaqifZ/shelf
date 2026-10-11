#!/bin/sh
# Build shelf, install ~/Applications/Shelf.app, link the CLI, and write the login agent.
# Does not start shelf. Run `shelf use shelf` for that.
set -e
cd "$(dirname "$0")/.."

LABEL=com.aaqifz.shelf
APP="$HOME/Applications/Shelf.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

swift build -c release --product shelf
mkdir -p "$APP/Contents/MacOS" "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/.shelf"
cp .build/release/shelf "$APP/Contents/MacOS/shelf"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>shelf</string>
  <key>CFBundleExecutable</key><string>shelf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PL
# A fixed certificate keeps the Accessibility and Screen Recording grants across rebuilds.
# Create it once with scripts/make-signing-cert.sh. Set SHELF_SIGN_IDENTITY to use another certificate.
IDENTITY="${SHELF_SIGN_IDENTITY:-shelf-local}"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier "$LABEL" "$APP"
else
  echo "note: no $IDENTITY certificate, so shelf is signed ad hoc. Each rebuild asks for the permissions again."
  echo "      Run scripts/make-signing-cert.sh once to keep them."
  codesign --force --sign - --identifier "$LABEL" "$APP"
fi
ln -sf "$APP/Contents/MacOS/shelf" "$HOME/.local/bin/shelf"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/shelf</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/.shelf/shelf.err</string>
</dict></plist>
PL

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "$DOMAIN/$LABEL"
  echo "shelf updated and restarted."
else
  launchctl disable "$DOMAIN/$LABEL"   # stays off at login until `shelf use shelf`
  echo "shelf installed. Start it with: shelf use shelf"
fi
