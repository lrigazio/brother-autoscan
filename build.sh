#!/bin/zsh
# Builds ~/Applications/AutoScan.app and installs the login agent.
set -e
cd "$(dirname "$0")"
A=~/Applications/AutoScan.app
mkdir -p $A/Contents/MacOS
cp app/Info.plist $A/Contents/
swiftc -O app/main.swift app/Crop.swift -o $A/Contents/MacOS/AutoScan
codesign --force --sign - $A
sed "s|/Users/luca|$HOME|g" com.luca.autoscan.plist > ~/Library/LaunchAgents/com.luca.autoscan.plist
launchctl bootout gui/$(id -u)/com.luca.autoscan 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.luca.autoscan.plist
echo "Installed. Plug in the scanner."
