import Foundation
import ZIPFoundation

/// IPA 打包：把 .app 塞進 Payload/ 再 zip 成 .ipa
enum IPABuilder {
    enum BuildError: LocalizedError {
        case appNotFound
        case zipFailed

        var errorDescription: String? {
            switch self {
            case .appNotFound: return "找不到 .app"
            case .zipFailed: return "打包 zip 失敗"
            }
        }
    }

    /// - Parameters:
    ///   - appURL: 已編好的 .app 目錄
    ///   - outputURL: 要輸出的 .ipa 路徑
    ///   - log: 日誌回調
    static func build(appURL: URL, outputURL: URL, log: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appURL.path) else { throw BuildError.appNotFound }

        // 建暫存目錄：staging/Payload/<Name>.app
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try fm.copyItem(at: appURL, to: payload.appendingPathComponent(appURL.lastPathComponent))

        // 如有舊 ipa 先刪
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        // zip 起來
        guard let archive = Archive(url: outputURL, accessMode: .create) else {
            throw BuildError.zipFailed
        }
        // 遞迴把 staging 下所有東西加進去（entry 路徑相對於 staging）
        let enumerator = fm.enumerator(at: staging, includingPropertiesForKeys: nil)!
        for case let fileURL as URL in enumerator {
            let rel = fileURL.path.replacingOccurrences(of: staging.path + "/", with: "")
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            let entryPath = isDir.boolValue ? rel + "/" : rel
            try archive.addEntry(with: entryPath, relativeTo: staging, compressionMethod: .deflate)
        }

        try fm.removeItem(at: staging)
        log("已輸出：\(outputURL.lastPathComponent)")
    }
}
