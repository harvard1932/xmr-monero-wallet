#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
archive="${TOR_RELEASE_ARCHIVE:-$work/tor.zip}"
if [[ -z "${TOR_RELEASE_ARCHIVE:-}" ]]; then
  curl --proto '=https' --fail --location --retry 3 \
    https://github.com/iCepa/Tor.framework/releases/download/409.17.1/tor-nolzma.xcframework.zip -o "$archive"
fi
expected=39579058d205389ce6aaeda6b152b730bed18032ec987487218f9466e9cd6c49
[[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$expected" ]] || { echo "Tor archive checksum mismatch." >&2; exit 1; }

# Replace two lifecycle-related compilation units using the exact headers and
# orconfig.h included in each verified binary slice. Keep every other member.
verify_source() {
  local source="$1" digest="$2"
  [[ "$(shasum -a 256 "$root/Scripts/Tor/$source.c" | cut -d' ' -f1)" == "$digest" ]] || {
    echo "Tor source checksum mismatch for $source." >&2
    exit 1
  }
  patch -s -o "$work/$source.c" "$root/Scripts/Tor/$source.c" "$root/Scripts/Tor/$source.patch"
}
verify_source workqueue e005bd4e9acdcc80b8c0bd260f4b6412a1327424101005c0fa6a989b54600931
verify_source dispatch_naming 39517e0ed88205b70c7f4a08f61e72b675166262571f775b6b0d57383488fb94

mkdir -p "$work/release" "$work/stage"
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
  mkdir -p "$work/$slice"
  upstream="tor-nolzma.xcframework/$slice"
  unzip -q "$archive" "$upstream/Headers/*" -d "$work/release"
  unzip -p "$archive" "$upstream/tor-nolzma.a" > "$work/$slice/fat.a"
  library="$work/$slice/libtorwallet.a"
  if [[ "$slice" == ios-arm64 ]]; then
    mv "$work/$slice/fat.a" "$library"
    sdk=iphoneos
    target=arm64-apple-ios15.0
  else
    xcrun lipo "$work/$slice/fat.a" -thin arm64 -output "$library"
    sdk=iphonesimulator
    target=arm64-apple-ios15.0-simulator
  fi
  members="$(xcrun ar -t "$library")"
  for source in workqueue dispatch_naming; do
    [[ "$(grep -Fxc "$source.o" <<< "$members")" == 1 ]]
    xcrun --sdk "$sdk" clang -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
      -O2 -fstack-protector-strong -ffile-prefix-map="$work"=. -I "$work/release/$upstream/Headers" -c "$work/$source.c" -o "$work/$slice/$source.o"
  done
  ZERO_AR_DATE=1 xcrun ar -rcs "$library" "$work/$slice/workqueue.o" "$work/$slice/dispatch_naming.o"
done
unzip -p "$archive" tor-nolzma.xcframework/ios-arm64/Headers/feature/api/tor_api.h | cmp - "$root/ThirdParty/Tor/tor_api.h"
xcodebuild -create-xcframework -library "$work/ios-arm64/libtorwallet.a" \
  -library "$work/ios-arm64_x86_64-simulator/libtorwallet.a" -output "$work/stage/tor-nolzma.xcframework"
mkdir -p "$root/Vendor"
dest="$root/Vendor/tor-nolzma.xcframework"
if [[ -d "$dest" ]]; then mv "$dest" "$work/prior.xcframework"; fi
mv "$work/stage/tor-nolzma.xcframework" "$dest"
