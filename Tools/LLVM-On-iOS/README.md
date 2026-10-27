# Vendored: LLVM-On-iOS build scripts

Source: https://github.com/emexlab/LLVM-On-iOS at commit
`5c2e215abf1f82fd3cfabba89d45b72e0b6bd8b9` ("feat: added swift 6.4.0 support"),
MIT license (see `LICENSE`).

Vendored files (verbatim except where noted):
- `Makefile`
- `Scripts/build-swift-toolchain.sh`
- `Scripts/swift-ios-toolchain-presets.ini` — **modified**:
  `darwin-deployment-version-ios` 16.0 -> 15.0 (our iOS 15 target).

Driven by `.github/workflows/build-llvm-nyxian.yml`:
`make all OS_VER=15.0 SWIFT_BRANCH=swift-6.4.0-RELEASE` with
`IOS_DEPLOYMENT_TARGET=15.0`. The build fetches Swift + apple/llvm-project
sources at build time; only the scripts live here.
