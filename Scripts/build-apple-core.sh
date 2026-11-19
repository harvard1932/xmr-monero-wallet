#!/bin/bash
# Builds wallet2 and its C wrapper from the pinned source for arm64 iPhone or iOS Simulator.
set -euo pipefail
umask 077
[[ $# == 2 && "$(uname -sm)" == "Darwin arm64" ]] || {
    echo "Usage on an Apple silicon Mac with Xcode: $0 ios|ios-simulator <output-dylib>" >&2
    exit 2
}
case "$1" in
    ios) sdk=iphoneos; platform=IOS ;;
    ios-simulator) sdk=iphonesimulator; platform=IOSSIMULATOR ;;
    *) echo "Unknown target: $1" >&2; exit 2 ;;
esac
target="$1"
recipe="$(cd "$(dirname "$0")/AppleCore" && pwd -P)"
destination="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
work="$(mktemp -d)"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf "$work"' EXIT
wrapper=33671871de3d51696b66ffb3bd94f744e26974f6
wallet2=22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0
source_dir="$work/source"
git init --quiet "$source_dir"
git -C "$source_dir" remote add origin https://github.com/MrCyjaneK/monero_c.git
git -C "$source_dir" fetch --quiet --depth 1 origin "$wrapper"
git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$wrapper" ]]
git -C "$source_dir" submodule update --init --depth 1 monero
[[ "$(git -C "$source_dir/monero" rev-parse HEAD)" == "$wallet2" ]]
git -C "$source_dir/monero" submodule update --init --recursive --depth 1 --jobs 4
git -C "$source_dir/monero" config user.name "Apple wallet build"
git -C "$source_dir/monero" config user.email "build@localhost"
git -C "$source_dir/monero" config commit.gpgSign false
export SOURCE_DATE_EPOCH="$(git -C "$source_dir" show -s --format=%ct HEAD)"
export GIT_COMMITTER_DATE="@$SOURCE_DATE_EPOCH +0000"
export GIT_AUTHOR_DATE="@$SOURCE_DATE_EPOCH +0000"
export ZERO_AR_DATE=1
"$source_dir/apply_patches.sh" monero

export MONERO_APPLE_PREFIX="$source_dir/contrib/depends/aarch64-apple-$target"
mkdir -p "$MONERO_APPLE_PREFIX" "$work/tools"
while read -r group checksum location; do
    [[ "$group" == tools || "$group" == "$target" ]] || continue
    artifact="$work/${location##*/}"
    curl --proto '=https' --fail --silent --show-error --location --retry 3 "$location" --output "$artifact"
    [[ "$(shasum -a 256 "$artifact" | cut -d' ' -f1)" == "$checksum" ]] || {
        echo "Checksum mismatch for ${location##*/}" >&2
        exit 1
    }
    case "$artifact" in
        *.tar.gz) tar -xzf "$artifact" -C "$MONERO_APPLE_PREFIX" ;;
        *.whl) unzip -oq "$artifact" -d "$work/tools" ;;
    esac
    rm "$artifact"
done < "$recipe/inputs.sha256"

cmake="$work/tools/cmake/data/bin/cmake"
ninja="$work/tools/ninja-1.11.1.4.data/scripts/ninja"
chmod +x "$cmake" "$ninja"
export MONERO_APPLE_SDK="$(xcrun --sdk "$sdk" --show-sdk-path)"
export MONERO_APPLE_CC="$(xcrun --find clang)"
export MONERO_APPLE_CXX="$(xcrun --find clang++)"
# wallet2 sets its own Release flags. Keep path normalization in the base flags,
# so assertions in wallet2 and Boost also use stable source paths.
map_source="-ffile-prefix-map=$work=/monero-build"
flags="-O2 -DNDEBUG -g0"
"$cmake" -S "$source_dir/monero_libwallet2_api_c" -B "$work/build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$recipe/toolchain.cmake" -DCMAKE_MAKE_PROGRAM="$ninja" \
    -DMONERO_FLAVOR=monero -DHOST_ABI="aarch64-apple-$target" -DOUTPUT_MODE=SHARED \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$map_source" -DCMAKE_CXX_FLAGS="$map_source" \
    -DCMAKE_C_FLAGS_RELEASE="$flags" -DCMAKE_CXX_FLAGS_RELEASE="$flags" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$work/build -L$MONERO_APPLE_PREFIX/lib" \
    -DSTATIC=ON -DBUILD_GUI_DEPS=ON -DBUILD_TESTS=OFF -DBUILD_DOCUMENTATION=OFF \
    -DUSE_DEVICE_TREZOR=OFF -DUSE_DEVICE_LEDGER=OFF -DUSE_LTO=OFF -DRANDOMX_ENABLE_JIT=OFF
"$cmake" --build "$work/build" --target monero_wallet2_api_c -j4
library="$work/build/libmonero_wallet2_api_c.dylib"
[[ "$(xcrun lipo -archs "$library")" == arm64 ]]
xcrun vtool -show-build "$library" | grep -Eq "platform $platform$"
mv -f "$library" "$destination"
