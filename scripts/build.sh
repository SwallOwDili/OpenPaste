#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
[[ "${OPENPASTE_TESTING:-0}" != "1" ]] || { print -u2 "Refusing to package an OPENPASTE_TESTING build."; exit 1; }
python3 scripts/version.py >/dev/null
mkdir -p build/OpenPaste.app/Contents/MacOS build/OpenPaste.app/Contents/Resources
iconset_dir="$(mktemp -d)/OpenPaste.iconset"
mkdir -p "$iconset_dir"
for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" Assets/AppIcon.png --out "$iconset_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    sips -z "$retina_size" "$retina_size" Assets/AppIcon.png --out "$iconset_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o build/OpenPaste.app/Contents/Resources/OpenPaste-v2.icns
rm -r "${iconset_dir:h}"
build_archs=("${OPENPASTE_ARCH:-$(uname -m)}")
if [[ "${build_archs[1]}" == "universal" ]]; then build_archs=(arm64 x86_64); fi
for build_arch in "${build_archs[@]}"; do
    [[ "$build_arch" == "arm64" || "$build_arch" == "x86_64" ]] || { print -u2 "Unsupported architecture: $build_arch"; exit 1; }
    swift build --manifest-cache none -c release --triple "${build_arch}-apple-macosx14.0" --scratch-path "build/swiftpm-${build_arch}" --product OpenPaste
    bin_dir="$(swift build --manifest-cache none -c release --triple "${build_arch}-apple-macosx14.0" --scratch-path "build/swiftpm-${build_arch}" --show-bin-path)"
    cp "$bin_dir/OpenPaste" "build/OpenPaste-${build_arch}"
done
if (( ${#build_archs} == 2 )); then
    lipo -create build/OpenPaste-arm64 build/OpenPaste-x86_64 -output build/OpenPaste.app/Contents/MacOS/OpenPaste
else
    cp "build/OpenPaste-${build_archs[1]}" build/OpenPaste.app/Contents/MacOS/OpenPaste
fi
python3 scripts/verify-production-binary.py build/OpenPaste.app/Contents/MacOS/OpenPaste
dsymutil build/OpenPaste.app/Contents/MacOS/OpenPaste -o build/OpenPaste.app.dSYM
strip -x build/OpenPaste.app/Contents/MacOS/OpenPaste

cp LICENSE NOTICE LICENSE.zh-CN.txt NOTICE.zh-CN.txt build/OpenPaste.app/Contents/Resources/
firebase_bundle_config="build/OpenPaste.app/Contents/Resources/GoogleService-Info.plist"
if [[ -f Assets/GoogleService-Info.plist ]]; then
    cp Assets/GoogleService-Info.plist "$firebase_bundle_config"
    chmod 644 "$firebase_bundle_config"
else
    # A previous configured build must not leave telemetry enabled in a local build.
    [[ ! -f "$firebase_bundle_config" ]] || rm "$firebase_bundle_config"
fi
cat > build/OpenPaste.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenPaste</string>
<key>CFBundleIdentifier</key><string>io.github.SwallOwDili.OpenPaste</string>
<key>CFBundleName</key><string>OpenPaste</string>
<key>CFBundleDisplayName</key><string>OpenPaste</string>
<key>CFBundleIconFile</key><string>OpenPaste-v2.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>FIREBASE_ANALYTICS_COLLECTION_ENABLED</key><false/>
<key>GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED</key><false/>
<key>FirebaseAutomaticScreenReportingEnabled</key><false/>
<key>FirebaseAppDelegateProxyEnabled</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>UTExportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>io.github.SwallOwDili.OpenPaste.clip-id</string><key>UTTypeConformsTo</key><array><string>public.data</string></array><key>UTTypeDescription</key><string>OpenPaste item reference</string></dict></array>
</dict></plist>
PLIST
python3 scripts/version.py --plist build/OpenPaste.app/Contents/Info.plist
# Set OPENPASTE_SIGNING_IDENTITY to keep a stable identity across updates.
# An explicitly selected but unavailable identity fails; there is no fallback.
signing_identity="${OPENPASTE_SIGNING_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    print -u2 "Development build: ad-hoc signing; updates may require Accessibility permission again."
fi
codesign --force --sign "$signing_identity" build/OpenPaste.app
codesign --verify --deep --strict build/OpenPaste.app
