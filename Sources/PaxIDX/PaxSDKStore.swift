import Foundation
import Zip

/// 打包 SDK 倉庫（整合正式路）：Documents/PaxSDK 下按版本並存——
/// sdk/iphoneos-26.sdk、sdk/iphoneos-27.sdk（完整 SDK 樹）＋res/（編譯器
/// 資源，與編譯器同源、跨 SDK 版本共用）。編譯時由使用者在專案頁選版。
enum PaxSDKStore {
    struct InstalledSDK: Identifiable, Equatable {
        let folderName: String
        let url: URL
        let version: String
        let major: Int
        var id: String { folderName }
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaxSDK", isDirectory: true)
    }
    static var sdkStoreDir: URL { root.appendingPathComponent("sdk", isDirectory: true) }
    static var resDir: URL { root.appendingPathComponent("res", isDirectory: true) }
    private static var legacySDK: URL { root.appendingPathComponent("iPhoneOS.sdk", isDirectory: true) }
    private static var embeddedMarker: URL { root.appendingPathComponent("embedded-sdk-version.txt") }

    /// SDKSettings.json 的 Version（如 "27.1"）；缺位時從 CanonicalName 推
    static func sdkVersion(at sdkURL: URL) -> String? {
        let p = sdkURL.appendingPathComponent("SDKSettings.json")
        guard let data = try? Data(contentsOf: p),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        if let v = dict["Version"] as? String { return v }
        if let c = dict["CanonicalName"] as? String {
            return c.replacingOccurrences(of: "iphoneos", with: "")
        }
        return nil
    }

    static func major(of version: String) -> Int {
        Int(version.split(separator: ".").first ?? "") ?? 0
    }

    static func folderName(forVersion version: String) -> String {
        "iphoneos-\(major(of: version)).sdk"
    }

    /// 舊佈局（PaxSDK/iPhoneOS.sdk）搬進版本目錄；同主版已在位則刪舊。
    static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacySDK.path),
              let ver = sdkVersion(at: legacySDK) else { return }
        let dest = sdkStoreDir.appendingPathComponent(folderName(forVersion: ver), isDirectory: true)
        try? fm.createDirectory(at: sdkStoreDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: legacySDK)
        } else {
            try? fm.moveItem(at: legacySDK, to: dest)
            patchTBDs(in: dest)
        }
    }

    static func installedSDKs() -> [InstalledSDK] {
        migrateLegacyIfNeeded()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sdkStoreDir.path) else { return [] }
        var out: [InstalledSDK] = []
        for name in names where name.hasPrefix("iphoneos-") && name.hasSuffix(".sdk") {
            let url = sdkStoreDir.appendingPathComponent(name, isDirectory: true)
            let ver = sdkVersion(at: url) ?? name
                .replacingOccurrences(of: "iphoneos-", with: "")
                .replacingOccurrences(of: ".sdk", with: "")
            out.append(InstalledSDK(folderName: name, url: url, version: ver, major: major(of: ver)))
        }
        return out.sorted { a, b in
            if a.major != b.major { return a.major > b.major }
            return a.version > b.version
        }
    }

    /// 安裝一份 PaxSDK.zip（內含 iPhoneOS.sdk/ 與 res/）：SDK 進版本目錄
    /// （同主版覆蓋）、res 只在缺位時補、.tbd 順手修 x1 目標。
    @discardableResult
    static func install(zipAt zipURL: URL) throws -> InstalledSDK {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("PaxSDKInstall-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try Zip.unzipFile(zipURL, destination: tmp, overwrite: true, password: nil)
        let srcSDK = tmp.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        guard fm.fileExists(atPath: srcSDK.path), let ver = sdkVersion(at: srcSDK) else {
            throw NSError(domain: "PaxSDKStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "壓縮包裡找不到合法的 iPhoneOS.sdk"])
        }
        let folder = folderName(forVersion: ver)
        let dest = sdkStoreDir.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: sdkStoreDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: srcSDK, to: dest)
        patchTBDs(in: dest)
        // res 共用：缺位才補（現行 res 與編譯器同源，別被其他包覆蓋）
        let srcRes = tmp.appendingPathComponent("res", isDirectory: true)
        if fm.fileExists(atPath: srcRes.path),
           !fm.fileExists(atPath: resDir.appendingPathComponent("module.modulemap").path) {
            if fm.fileExists(atPath: resDir.path) { try? fm.removeItem(at: resDir) }
            try fm.moveItem(at: srcRes, to: resDir)
        }
        // 舊佈局同版殘留清掉（避免雙份佔空間）
        if let lv = sdkVersion(at: legacySDK), lv == ver {
            try? fm.removeItem(at: legacySDK)
        }
        return InstalledSDK(folderName: folder, url: dest, version: ver, major: major(of: ver))
    }

    static func remove(_ sdk: InstalledSDK) {
        try? FileManager.default.removeItem(at: sdk.url)
    }

    /// 27 世代 .tbd 的目標清單多了 LLVM 21 不認識的 arm64e.x1-ios
    /// （整份被 TAPI 判 malformed、連結全滅，2026-10-29 #171 真機實證）。
    /// 安裝時把 x1 目標改寫成 arm64-ios（與 arm64e 並列的經典對）。
    static func patchTBDs(in sdkURL: URL) {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: sdkURL.path) else { return }
        for case let rel as String in en {
            guard rel.hasSuffix(".tbd") else { continue }
            let p = sdkURL.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: p, encoding: .utf8),
                  text.contains("x1-ios") else { continue }
            let fixed = text
                .replacingOccurrences(of: "arm64e.x1-ios", with: "arm64-ios")
                .replacingOccurrences(of: "arm64.x1-ios", with: "arm64-ios")
            try? fixed.write(to: p, atomically: true, encoding: .utf8)
        }
    }

    /// App 內嵌 PaxSDK.zip 的落地（試編頁與正式編譯共用）。
    static func bootstrapEmbeddedIfNeeded() {
        let fm = FileManager.default
        let markerExists = fm.fileExists(atPath: embeddedMarker.path)
        if markerExists && !installedSDKs().isEmpty { return }
        guard let zip = Bundle.main.url(forResource: "PaxSDK", withExtension: "zip") else { return }
        if let sdk = try? install(zipAt: zip) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            try? sdk.version.write(to: embeddedMarker, atomically: true, encoding: .utf8)
        }
    }
}
