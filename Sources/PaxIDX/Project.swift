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
    /// 建立專案時選定的 SDK（PaxSDKStore 的 folderName，如
    /// iphoneos-27.sdk）；nil＝未指定，編譯時用最新已安裝的一版
    var sdkFolder: String?

    init(name: String, bundleID: String, version: String = "1.0", sdkFolder: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.sdkFolder = sdkFolder
    }
}
