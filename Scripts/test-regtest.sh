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
download https://github.com/MrCyjaneK/monero_c/releases/download/v0.18.4.6-RC2/release-bundle.zip release.zip 94ae3d99f878d1e392b9c49d4c5431e4d0b7780c6177081df5369d05e68cea70
lib=libmonero_wallet2_api_c.dylib
unzip -p release.zip "v0.18.4.6-RC2/aarch64-apple-darwin/$lib" > "$lib"
chmod +x "$lib"
codesign -fs - "$lib"

ur_commit=d82e7c753e710b8000706dc3383b498438795208
download "https://codeload.github.com/MrCyjaneK/bc-ur/tar.gz/$ur_commit" ur.tar.gz 8a56f89bb7d2015a7e71f231aec11d8c03eb0aa6a418e2dcce449c6b700ba113
tar -xzf ur.tar.gz
ur_src="./bc-ur-$ur_commit/src"
xcrun clang -c "$ur_src"/*.c
xcrun clang++ -std=c++17 -I "$ur_src" "$root/Scripts/Regtest/EncodeUR.cpp" "$ur_src"/*.cpp ./*.o -o encode-ur
xcrun clang++ -std=c++17 -c "$root/Core/MoneroBridge.cpp" -o bridge.o
xcrun swiftc -parse-as-library -import-objc-header "$root/Core/MoneroBridge.h" \
  "$root/Core/WalletTypes.swift" "$root/Core/WalletEngine.swift" "$root/Scripts/Regtest/ColdTransfer.swift" \
  bridge.o "./$lib" -lc++ -Xlinker -rpath -Xlinker '@executable_path' -o cold-transfer
python3 "$root/Scripts/Regtest/regtest.py" "$work" "$work/$bin"
