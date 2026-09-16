#!/bin/bash
# Builds the app and installs it on the connected iPhone (Mac only, Xcode 26.3).
#   ios/scripts/build-device.sh [Debug|Release]
# Errors and warnings are also written to ios/build/last-errors.txt, to paste back as they are.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-Debug}"
if [ ! -f Config/Local.xcconfig ]; then
  echo "Créer ios/Config/Local.xcconfig à partir de Local.xcconfig.example (DEVELOPMENT_TEAM)." >&2
  exit 1
fi
mkdir -p build

# First paired iPhone, unless DEVICE_UDID is set.
if [ -z "${DEVICE_UDID:-}" ]; then
  xcrun devicectl list devices --json-output build/devices.json > /dev/null
  DEVICE_UDID=$(/usr/bin/plutil -extract result.devices.0.hardwareProperties.udid raw build/devices.json 2>/dev/null || true)
fi
if [ -z "$DEVICE_UDID" ]; then
  echo "Aucun iPhone trouvé : le brancher, le déverrouiller et lui faire confiance." >&2
  exit 1
fi

status=0
xcodebuild build \
  -project Planner.xcodeproj -scheme Planner -configuration "$configuration" \
  -destination "id=$DEVICE_UDID" -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  > build/xcodebuild.log 2>&1 || status=$?
grep -E '(error|warning): ' build/xcodebuild.log | sort -u > build/last-errors.txt || true
if [ "$status" -ne 0 ]; then
  cat build/last-errors.txt
  tail -n 5 build/xcodebuild.log
  echo "Build en échec : envoyer ios/build/last-errors.txt (ou la fin de ios/build/xcodebuild.log)." >&2
  exit "$status"
fi

app="build/DerivedData/Build/Products/${configuration}-iphoneos/Planner.app"
xcrun devicectl device install app --device "$DEVICE_UDID" "$app"
bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Info.plist")
xcrun devicectl device process launch --device "$DEVICE_UDID" "$bundle_id" || \
  echo "Installée. Si iOS bloque le lancement : Réglages > Général > VPN et gestion de l'appareil > faire confiance au développeur."
echo "Planner ($configuration) installé sur l'iPhone."
