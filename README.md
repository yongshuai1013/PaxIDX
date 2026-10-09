# PaxIDX

iOS 15 上的 C 編譯器：在 iPhone 上直接把 C 代碼編成 IPA。

## 專注 C

本版本專注 C/C++ 編譯器。Swift 支持已暫停（2026-10-09 決定）。

## 功能

- C/C++ 代碼編輯
- 調用內建 Clang/LLD 工具鏈編譯
- 打包成 IPA
- iOS SDK 管理

## 構建

需要 GitHub Actions 構建 IPA（見 `.github/workflows/build-ipa.yml`）。
