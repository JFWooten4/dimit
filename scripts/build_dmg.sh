#!/bin/bash
# Packages a Dimit.app (default: build/release/Dimit.app) into
# <same directory>/Dimit-<version>.dmg with a designed Finder window.
#
# The artwork is rendered by scripts/render_dmg_background.swift using only
# macOS AppKit. Finder then persists the layout into the image's .DS_Store,
# so the shipped DMG opens with the intended background and icon positions
# without adding a third-party packaging dependency.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

SRC_APP=${1:-$APP}
require_app "$SRC_APP"
VERSION=$(app_version "$SRC_APP")
DIR=$(dirname "$SRC_APP")
DMG="$DIR/Dimit-$VERSION.dmg"
RW_DMG="$DIR/Dimit-$VERSION-rw.dmg"
STAGE="$DIR/dmgroot"
ARTWORK_RENDERER="scripts/render_dmg_background.swift"
VOLUME="Dimit $VERSION"

[ -f "$ARTWORK_RENDERER" ] || { echo "ERROR: DMG artwork renderer missing: $ARTWORK_RENDERER" >&2; exit 1; }
rm -rf "$STAGE" "$DMG" "$RW_DMG"
mkdir -p "$STAGE/.background"
cp -R "$SRC_APP" "$STAGE/Dimit.app"
ln -s /Applications "$STAGE/Applications"
swift "$ARTWORK_RENDERER" "$STAGE/.background/dmg-background.png"

# Build a temporary writable image, let Finder persist the presentation into
# .DS_Store, then convert it to the compressed read-only image we ship.
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDRW -quiet "$RW_DMG"
LAYOUT_ATTACH=$(hdiutil attach -readwrite -noverify -noautoopen -plist "$RW_DMG")
LAYOUT_MOUNT=$(python3 -c 'import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(next(e["mount-point"] for e in d["system-entities"] if "mount-point" in e))' <<<"$LAYOUT_ATTACH")
[ -n "$LAYOUT_MOUNT" ] || { echo "ERROR: could not mount writable image" >&2; exit 1; }
cleanup_layout() {
    hdiutil detach "$LAYOUT_MOUNT" -quiet 2>/dev/null || true
}
trap cleanup_layout EXIT

# Native Finder scripting gives us the polished drag-to-install window without
# a create-dmg dependency. The first local run may ask the invoking terminal
# for permission to automate Finder.
osascript <<APPLESCRIPT
set volumeName to "$VOLUME"
tell application "Finder"
    tell disk volumeName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {180, 120, 840, 575}

        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:dmg-background.png"

        set position of item "Dimit.app" to {175, 225}
        set position of item "Applications" to {485, 225}

        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$LAYOUT_MOUNT" -quiet
trap - EXIT
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$DMG"
rm -rf "$STAGE" "$RW_DMG"

# Mount and check the image carries the app, Applications link, installer
# artwork, Finder layout, and intact app signature. The trap guarantees the
# volume is detached even when a check fails.
ATTACH=$(hdiutil attach -readonly -nobrowse -noautoopen -plist "$DMG")
trap 'hdiutil detach "$(sed -n "s|.*<string>\\(/Volumes/[^<]*\\)</string>.*|\\1|p" <<<"$ATTACH" | head -1)" -quiet 2>/dev/null || true' EXIT
MOUNT=$(python3 -c 'import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(next(e["mount-point"] for e in d["system-entities"] if "mount-point" in e))' <<<"$ATTACH")
[ -n "$MOUNT" ] || { echo "ERROR: could not mount $DMG" >&2; exit 1; }

[ -d "$MOUNT/Dimit.app" ] || { echo "ERROR: Dimit.app missing from the image" >&2; exit 1; }
[ -L "$MOUNT/Applications" ] || { echo "ERROR: Applications link missing from the image" >&2; exit 1; }
[ -f "$MOUNT/.background/dmg-background.png" ] || { echo "ERROR: DMG artwork missing from the image" >&2; exit 1; }
[ -f "$MOUNT/.DS_Store" ] || { echo "ERROR: Finder layout missing from the image" >&2; exit 1; }
if ! codesign --verify --deep --strict "$MOUNT/Dimit.app"; then
    echo "ERROR: signature broken inside the image" >&2; exit 1
fi

echo "image contents: Dimit.app ($VERSION, $(app_build "$MOUNT/Dimit.app")) + Applications link + designed Finder layout, signature intact"
echo "built: $DMG ($(du -h "$DMG" | cut -f1))"
