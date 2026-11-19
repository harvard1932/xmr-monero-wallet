#!/bin/bash
set -euo pipefail
umask 077
[[ "$(uname -sm)" == "Darwin arm64" ]] || { echo "This harness requires an Apple silicon Mac with Xcode." >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

download() {
  curl --proto '=https' --fail --silent --show-error --location --retry 3 "$1" -o "$2"
  [[ "$(shasum -a 256 "$2" | cut -d' ' -f1)" == "$3" ]] || { echo "Input checksum mismatch." >&2; exit 1; }
}
download https://downloads.getmonero.org/cli/monero-mac-armv8-v0.18.5.4.tar.bz2 cli.tar.bz2 d457de7c8a1ad42e3232fdea6d9f9003be9652143fb8f719c1fc906aa6b4917b
bin=monero-aarch64-apple-darwin11-v0.18.5.4
tar -xjf cli.tar.bz2 "$bin/monerod" "$bin/monero-wallet-rpc"
lib=libmonero_wallet2_api_c.dylib
mac_archive="${MONERO_MAC_ARCHIVE:-$work/Monero_com_v6.5.4.dmg}"
if [[ -z "${MONERO_MAC_ARCHIVE:-}" ]]; then
    curl --proto '=https' -fLsS --retry 3 https://github.com/cake-tech/cake_wallet/releases/download/v6.5.4/Monero_com_v6.5.4.dmg -o "$mac_archive"
fi
[[ "$(shasum -a 256 "$mac_archive" | cut -d' ' -f1)" == 12609942cb06af45e02fdd1968b99c079601645b8299214f37d59edc8d5ee724 ]] || { echo "Mac archive checksum mismatch." >&2; exit 1; }
(
    mkdir disk
    hdiutil attach -readonly -nobrowse -mountpoint "$work/disk" "$mac_archive" >/dev/null
    trap 'hdiutil detach "$work/disk" >/dev/null' EXIT
    original="$work/disk/Monero.com.app/Contents/Frameworks/$lib"
    codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "32J6BB6VUS"' "$original"
    lipo "$original" -thin arm64 -output "$work/$lib"
)
[[ "$(shasum -a 256 "$lib" | cut -d' ' -f1)" == 3d0786038cbe65ad0c5ecac510f22784afc9de47979ca474f28ba618cebff9a4 ]] || { echo "Mac wallet engine checksum mismatch." >&2; exit 1; }
chmod +x "$lib"
install_name_tool -id "@rpath/$lib" "$lib"
codesign -fs - "$lib"

ur_commit=d82e7c753e710b8000706dc3383b498438795208
download "https://codeload.github.com/MrCyjaneK/bc-ur/tar.gz/$ur_commit" ur.tar.gz 8a56f89bb7d2015a7e71f231aec11d8c03eb0aa6a418e2dcce449c6b700ba113
tar -xzf ur.tar.gz
ur_src="./bc-ur-$ur_commit/src"
xcrun clang -c "$ur_src"/*.c
xcrun clang++ -std=c++17 -I "$ur_src" "$root/Scripts/Regtest/EncodeUR.cpp" "$ur_src"/*.cpp ./*.o -o encode-ur
xcrun clang++ -std=c++17 -c "$root/Core/MoneroBridge.cpp" -o bridge.o
xcrun swiftc -parse-as-library -import-objc-header "$root/Core/MoneroBridge.h" \
  "$root/Core/WalletTypes.swift" "$root/Core/WalletEngine.swift" "$root/Scripts/Regtest/ColdTransfer.swift" "$root/Scripts/Regtest/HotTransfer.swift" \
  bridge.o "./$lib" -lc++ -Xlinker -rpath -Xlinker '@executable_path' -o cold-transfer
python3 "$root/Scripts/Regtest/regtest.py" "$work" "$work/$bin"
mkdir "$work/private-testnet"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/Scripts/Regtest/hot_testnet.py" "$work/private-testnet" "$work/$bin" "$work/cold-transfer"
