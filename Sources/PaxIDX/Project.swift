import Foundation

/// 項目模型，對應 Documents/projects/<name>/ 目錄
struct Project: Identifiable, Codable, Equatable {
    /// 用項目名稱當 id（同一設備上名稱唯一）
    var id: String { name }
    /// 項目名稱（也是目錄名）
    var name: String
    /// Bundle ID
    var bundleID: String
    /// 版本號
    var version: String

    init(name: String, bundleID: String, version: String = "1.0") {
        self.name = name
        self.bundleID = bundleID
        self.version = version
    }
}
