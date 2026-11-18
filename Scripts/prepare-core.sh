#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
release=v0.18.4.6-RC2
digest=94ae3d99f878d1e392b9c49d4c5431e4d0b7780c6177081df5369d05e68cea70
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bundle="${MONERO_RELEASE_BUNDLE:-$work/release-bundle.zip}"
if [[ -z "${MONERO_RELEASE_BUNDLE:-}" ]]; then
    curl --proto '=https' -fL --retry 3 "https://github.com/MrCyjaneK/monero_c/releases/download/$release/release-bundle.zip" -o "$bundle"
fi
actual="$(shasum -a 256 "$bundle" | cut -d' ' -f1)"
if [[ "$actual" != "$digest" ]]; then
    echo "Monero wallet engine archive checksum mismatch." >&2
    exit 1
fi
for platform in ios ios-simulator; do
    framework="$work/$platform/MoneroWallet.framework"
    mkdir -p "$framework"
    unzip -p "$bundle" "$release/aarch64-apple-$platform/libmonero_wallet2_api_c.dylib" > "$framework/MoneroWallet"
    chmod 755 "$framework/MoneroWallet"
    install_name_tool -id '@rpath/MoneroWallet.framework/MoneroWallet' "$framework/MoneroWallet"
    cat > "$framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.getmonero.walletcore</string>
<key>CFBundleName</key><string>MoneroWallet</string>
<key>CFBundleExecutable</key><string>MoneroWallet</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.18.4</string>
<key>MinimumOSVersion</key><string>12.0</string>
</dict></plist>
PLIST
    codesign --force --sign - "$framework"
done
xcodebuild -create-xcframework -framework "$work/ios/MoneroWallet.framework" \
    -framework "$work/ios-simulator/MoneroWallet.framework" -output "$work/MoneroWallet.xcframework"
mkdir -p "$root/Vendor"
dest="$root/Vendor/MoneroWallet.xcframework"
if [[ -d "$dest" ]]; then mv "$dest" "$work/previous.xcframework"; fi
mv "$work/MoneroWallet.xcframework" "$dest"
