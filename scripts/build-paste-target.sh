#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

architecture="${OPENPASTE_ARCH:-$(uname -m)}"
if [[ "$architecture" != "arm64" && "$architecture" != "x86_64" ]]; then
    printf 'Unsupported architecture: %s\n' "$architecture" >&2
    exit 1
fi

output_root="build/acceptance-tools"
app="$output_root/PasteFixture.app"
mkdir -p "$output_root"
staging="$(mktemp -d "$output_root/.PasteFixture.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/PasteFixture.app/Contents/MacOS"
xcrun swiftc \
    -O \
    -target "${architecture}-apple-macosx14.0" \
    -framework AppKit \
    Tests/Support/PasteTarget.swift \
    -o "$staging/PasteFixture.app/Contents/MacOS/PasteFixture"

cat > "$staging/PasteFixture.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PasteFixture</string>
<key>CFBundleIdentifier</key><string>io.github.SwallOwDili.OpenPaste.fixture</string>
<key>CFBundleName</key><string>PasteFixture</string>
<key>CFBundleDisplayName</key><string>OpenPaste Paste Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$staging/PasteFixture.app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$staging/PasteFixture.app"
codesign --verify --deep --strict "$staging/PasteFixture.app"

rm -rf "$app"
mv "$staging/PasteFixture.app" "$app"
printf 'Built %s\n' "$app"
