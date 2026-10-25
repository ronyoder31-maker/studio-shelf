#!/bin/bash
# Installs the simulator build, seeds the demo library, and captures screens in light and dark mode.
set -u
APP=$(find build/DD/Build/Products -name "StudioShelf.app" -path "*iphonesimulator*" | head -1)
[ -z "$APP" ] && { echo "no app"; exit 1; }
mkdir -p ci/screens
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl install "$SIM" "$APP"
BID=com.ronyoder.studioshelf
shot() { # name section appearance
  xcrun simctl ui "$SIM" appearance "$3"
  xcrun simctl terminate "$SIM" $BID 2>/dev/null
  xcrun simctl launch "$SIM" $BID -demo -section "$2" >/dev/null
  sleep "${4:-6}"
  xcrun simctl io "$SIM" screenshot "ci/screens/$1.png" >/dev/null
}
shot 01-allfiles-light allFiles light 8
shot 02-browser-light browser light 12
shot 03-downloads-light downloads light
shot 04-media-light media light
shot 05-printables-light printables light
shot 06-allfiles-dark allFiles dark
shot 07-downloads-dark downloads dark
shot 08-settings-dark settings dark
ls -la ci/screens
