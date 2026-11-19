# Build wallet2 for iPhone and Simulator

Run these commands from the project root on an Apple silicon Mac with Xcode. Each invocation builds the Monero C wrapper, wallet2 and its pinned submodules from source. The script downloads checksum-verified arm64 dependency archives and build tools into a temporary directory, then removes it. The default app build uses a library from Cake Wallet’s signed iPhone distribution for physical devices. [Default engine inputs](../../ThirdParty/WalletEngine.md)

```sh
mkdir -p "$PWD/.build/wallet-engine"
Scripts/build-apple-core.sh ios "$PWD/.build/wallet-engine/device.dylib"
Scripts/build-apple-core.sh ios-simulator "$PWD/.build/wallet-engine/simulator.dylib"
MONERO_DEVICE_LIBRARY="$PWD/.build/wallet-engine/device.dylib" \
MONERO_SIMULATOR_LIBRARY="$PWD/.build/wallet-engine/simulator.dylib" \
Scripts/prepare-core.sh
```

The tools used for verification were Xcode 27.1, the iOS and Simulator 27.1 SDKs, CMake 3.31.6 and Ninja 1.11.1. Each library targets iOS 17 and later. Compiler and linker revisions can affect the resulting Mach-O bytes. Use `xcrun vtool -show-build` to inspect the target platform and `shasum -a 256` to record a library before framework packaging.

The native build checks out monero_c commit `33671871de3d51696b66ffb3bd94f744e26974f6`, checks wallet2 commit `22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0`, initializes its submodules and applies the pinned wrapper patches. Build tools and precompiled support libraries have individual download URLs and SHA-256 values. The macOS tools come from the CMake and Ninja projects’ PyPI distributions. The target-specific dependency archives come from the Simply Build System’s public release cache. The included libraries cover Boost, OpenSSL, libsodium, Unbound, ZeroMQ, protobuf, zlib and libiconv. [Input manifest](inputs.sha256) · [Wrapper dependency definitions](https://github.com/MrCyjaneK/monero_c/blob/33671871de3d51696b66ffb3bd94f744e26974f6/contrib/depends/Makefile) · [Upstream cache](https://github.com/mrcyjanex/simplybs_private/releases)
