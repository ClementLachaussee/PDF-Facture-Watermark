#!/bin/bash
# Compile Acquitter.app (nécessite les outils en ligne de commande Xcode : xcode-select --install)
set -e
cd "$(dirname "$0")"

APP="Acquitter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/Acquitter" main.swift -framework Cocoa
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

touch "$APP"
echo "OK : $APP créée. Vous pouvez la glisser dans /Applications."
