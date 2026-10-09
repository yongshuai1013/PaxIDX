import Foundation

/// 簽名佔位：簽名走 GitHub Actions，這裡只留接口
/// 不依賴 XKit（XKit 要求 iOS 17）
enum AppBundleSigner {
    enum SignError: LocalizedError {
        case notImplemented

        var errorDescription: String? {
            return "簽名請走 GitHub Actions"
        }
    }

    /// 對 ipa 簽名（目前未實作，直接拋錯）
    /// - Parameter ipaURL: 未簽名的 .ipa 路徑
    static func sign(ipaURL: URL) throws {
        throw SignError.notImplemented
    }
}
