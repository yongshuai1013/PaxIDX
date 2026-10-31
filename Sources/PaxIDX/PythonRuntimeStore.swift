import Foundation
import Zip

/// Python 執行環境倉庫：Documents/PythonRuntime——release paxpython-3.13 的
/// PaxPythonRuntime.zip 解壓落地（通用宿主 PythonHost、Python.framework、
/// python/ 完整標準庫、dylib-template.plist、VERSION）。
/// 所有 Python 專案共用一份，組裝 App 時從這裡複製。
enum PythonRuntimeStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PythonRuntime", isDirectory: true)
    }

    static var version: String? {
        try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("PythonHost").path)
            && fm.fileExists(atPath: root.appendingPathComponent("Python.framework/Python").path)
            && fm.fileExists(atPath: root.appendingPathComponent("python/lib/python3.13/os.py").path)
    }

    /// 安裝一份 PaxPythonRuntime.zip（整份覆蓋舊版）
    static func install(zipAt zipURL: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("PythonRuntimeInstall-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try Zip.unzipFile(zipURL, destination: tmp, overwrite: true, password: nil)
        guard fm.fileExists(atPath: tmp.appendingPathComponent("PythonHost").path),
              fm.fileExists(atPath: tmp.appendingPathComponent("python/lib/python3.13/os.py").path)
        else {
            throw NSError(domain: "PythonRuntimeStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "壓縮包內容不完整（缺宿主或標準庫）"])
        }
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.moveItem(at: tmp, to: root)
        // zip 解壓可能丟執行權限，宿主補上
        try? fm.setAttributes([.posixPermissions: 0o755],
                              ofItemAtPath: root.appendingPathComponent("PythonHost").path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
