#!/bin/bash
# Builds Flowstate.app from the SwiftPM release binary and installs it to
# ~/Applications. Signs with the stable "Murmur Dev" self-signed identity when
# present (keeps TCC grants alive across rebuilds), else falls back to ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Flowstate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/murmur.icns "$APP/Contents/Resources/murmur.icns"
cp .build/release/Murmur "$APP/Contents/MacOS/Flowstate"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A self-signed cert won't appear under the codesigning *policy* filter, but
# codesign can still sign with it by name — check the cert exists instead.
if security find-certificate -c "Murmur Dev" >/dev/null 2>&1; then
    IDENTITY="Murmur Dev"
else
    IDENTITY="-"
    cat >&2 <<'EOF'
WARNING: no "Murmur Dev" certificate found — signing ad-hoc.
         Accessibility/Microphone grants will NOT survive rebuilds.
         One-time fix: Keychain Access → Certificate Assistant → Create a
         Certificate… → Name: "Murmur Dev", Identity Type: Self-Signed Root,
         Certificate Type: Code Signing → Create. Then rerun this script.
EOF
fi

# --options runtime: hardened runtime, so another same-user process can't
# DYLD_INSERT_LIBRARIES or debugger-attach into an app holding Accessibility +
# Microphone. Self-signed "Murmur Dev" still satisfies TCC persistence. (Add
# --timestamp for a notarizable build; it needs network, so it's left off here.)
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/Murmur.app ~/Applications/Flowstate.app
ditto "$APP" ~/Applications/Flowstate.app

echo "Signed with: $IDENTITY"
echo "Installed:   ~/Applications/Flowstate.app  (launch with: open ~/Applications/Flowstate.app)"
