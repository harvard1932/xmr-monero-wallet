#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
verify() {
    [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]] || { echo "Wallet engine checksum mismatch." >&2; exit 1; }
}
verify "$root/ThirdParty/monero_wallet2_api_c.h" f1f24af3a9ae7e136c67fbbeffb1af0f7a3dd6cb70a7c43d5bd36a60fdb4a64f
verify "$root/ThirdParty/wallet2_api.hpp" 0338bb84858c5140e2326dc77dea842668058544f53670dde19c5c2fb88ae229

device="$work/device.dylib"
if [[ -n "${MONERO_DEVICE_LIBRARY:-}" ]]; then
    cp "$MONERO_DEVICE_LIBRARY" "$device"
else
    archive="${MONERO_IOS_ARCHIVE:-${MONERO_RELEASE_BUNDLE:-$work/Monero_com_v6.5.4.ipa}}"
    if [[ -z "${MONERO_IOS_ARCHIVE:-${MONERO_RELEASE_BUNDLE:-}}" ]]; then
        curl --proto '=https' -fL --retry 3 \
            https://github.com/cake-tech/cake_wallet/releases/download/v6.5.4/Monero_com_v6.5.4.ipa -o "$archive"
    fi
    verify "$archive" 2a486dbdd4edb1eaee35ebf59babf29e4689c2f063878a03aef6ef018f2a89c2
    unzip -q "$archive" 'Payload/Runner.app/Frameworks/MoneroWallet.framework/*' -d "$work"
    original="$work/Payload/Runner.app/Frameworks/MoneroWallet.framework"
    codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "32J6BB6VUS"' "$original"
    verify "$original/MoneroWallet" 0367554b764f1b6d07bce64187c938f3570c86b44b40c5e3b3534ca146a33d7b
    lipo "$original/MoneroWallet" -thin arm64 -output "$device"
fi
simulator="$work/simulator.dylib"
if [[ -n "${MONERO_SIMULATOR_LIBRARY:-}" ]]; then
    cp "$MONERO_SIMULATOR_LIBRARY" "$simulator"
else
    "$root/Scripts/build-simulator-core.sh" "$simulator"
fi

for platform in ios ios-simulator; do
    framework="$work/$platform/MoneroWallet.framework"
    mkdir -p "$framework"
    if [[ "$platform" == ios ]]; then
        library="$device"
        native_platform=IOS
    else
        library="$simulator"
        native_platform=IOSSIMULATOR
    fi
    [[ "$(lipo -archs "$library")" == arm64 ]] || { echo "Expected an arm64 library for $platform." >&2; exit 1; }
    xcrun vtool -show-build "$library" > "$work/platform.txt"
    [[ "$(awk '$1 == "platform" {print $2}' "$work/platform.txt")" == "$native_platform" ]] || { echo "Incorrect wallet library platform." >&2; exit 1; }
    minos="$(awk '$1 == "minos" {print $2}' "$work/platform.txt")"
    LC_ALL=C strings "$library" > "$work/identifiers.txt"
    grep -Fxq '087f2bb11cdbca5f886346850c74f0404a9c371fd1706521e7590dcea21d8af5-22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0' "$work/identifiers.txt" || { echo "Wrong wrapper or Monero revision for $platform." >&2; exit 1; }
    shasum -a 256 "$library"
    cp "$library" "$framework/MoneroWallet"
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
<key>CFBundleShortVersionString</key><string>0.18.5.3</string>
<key>MinimumOSVersion</key><string>13.0</string>
</dict></plist>
PLIST
    plutil -replace MinimumOSVersion -string "$minos" "$framework/Info.plist"
    codesign --force --sign - "$framework"
done
xcodebuild -create-xcframework -framework "$work/ios/MoneroWallet.framework" \
    -framework "$work/ios-simulator/MoneroWallet.framework" -output "$work/MoneroWallet.xcframework"
mkdir -p "$root/Vendor"
dest="$root/Vendor/MoneroWallet.xcframework"
if [[ -d "$dest" ]]; then mv "$dest" "$work/previous.xcframework"; fi
if ! mv "$work/MoneroWallet.xcframework" "$dest"; then
    if [[ -d "$work/previous.xcframework" && ! -e "$dest" ]]; then mv "$work/previous.xcframework" "$dest"; fi
    exit 1
fi
