#!/bin/zsh
# Writes a Sparkle appcast announcing one DMG to standard output.
#   scripts/appcast.sh <app> <dmg> <download-url>
# Signs with the private key in SPARKLE_PRIVATE_KEY, or else the key generate_keys stored in
# the keychain for the account app.arysha.NotAnIsland.
set -euo pipefail

repo=${0:A:h:h}
app=$1
dmg=$2
url=$3

sign_update=$repo/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
[[ -x $sign_update ]] || { echo "error: $sign_update not found; build the app first" >&2; exit 1; }

if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
  signature=$(print -r -- "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$dmg")
else
  signature=$("$sign_update" --account app.arysha.NotAnIsland "$dmg")
fi

plist=$app/Contents/Info.plist
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Not an Island</title>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/dabdabplayer/Not-an-island/releases</sparkle:fullReleaseNotesLink>
      <enclosure url="$url" type="application/x-apple-diskimage" $signature/>
    </item>
  </channel>
</rss>
EOF
