# PaxIDX Makefile
# 所有註釋使用正體中文

.PHONY: gen build test ipa clean

# 用 XcodeGen 生成 Xcode 項目
gen:
	xcodegen generate

# 編譯 App（Debug）
build: gen
	xcodebuild -project PaxIDX.xcodeproj -scheme PaxIDX -configuration Debug -sdk iphoneos build

# 跑單元測試
test: gen
	xcodebuild -project PaxIDX.xcodeproj -scheme PaxIDX -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 14' test

# 打未簽名 IPA（給 CI / 側載用）
ipa: gen
	xcodebuild -project PaxIDX.xcodeproj -scheme PaxIDX -configuration Release -sdk iphoneos -archivePath build/PaxIDX.xcarchive archive CODE_SIGNING_ALLOWED=NO
	mkdir -p build/Payload
	cp -r build/PaxIDX.xcarchive/Products/Applications/PaxIDX.app build/Payload/
	cd build && zip -r PaxIDX-unsigned.ipa Payload/
	@echo "未簽名 IPA 已生成：build/PaxIDX-unsigned.ipa"

# 清理
clean:
	rm -rf build/
	rm -rf PaxIDX.xcodeproj
