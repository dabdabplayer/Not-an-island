#!/bin/zsh
# Builds a Release copy of Not an Island and packages it as a drag-to-install DMG in build/.
# Signs with SIGN_IDENTITY, or the first "Apple Development" identity in the keychain, so
# macOS permissions survive reinstalls. The result is not notarized: it runs on the Mac that
# built it, but Gatekeeper will block it after a download or AirDrop.
set -euo pipefail

repo=${0:A:h:h}
cd "$repo"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

xcodebuild build \
  -project NotAnIsland.xcodeproj \
  -scheme NotAnIsland \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  -quiet

app=build/Build/Products/Release/NotAnIsland.app
[[ -d $app ]] || { echo "error: $app was not produced" >&2; exit 1; }

identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}
if [[ -z $identity ]]; then
  identity=-
  echo "warning: no Apple Development identity found; signing ad hoc." >&2
  echo "warning: macOS will ask for permissions again after every reinstall." >&2
fi

# The hardened runtime only loads frameworks signed by the same team, which an ad hoc
# signature never is. Like Xcode, leave it off ad hoc builds; it only matters for notarization.
signing=(--force --timestamp=none)
[[ $identity == - ]] || signing+=(--options runtime)

# Sign inside out, so Sparkle's helpers carry the same identity as the app.
sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
for nested in $sparkle/XPCServices/*.xpc $sparkle/Autoupdate $sparkle/Updater.app $app/Contents/Frameworks/Sparkle.framework; do
  codesign $signing --sign "$identity" "$nested"
done
codesign $signing \
  --entitlements NotAnIsland.entitlements \
  --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg=build/NotAnIsland-$version.dmg

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/NotAnIsland.app"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
diskutil image create from --format UDZO --volumeName "Not an Island" "$staging" "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null

echo "Packaged $dmg"
