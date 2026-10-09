import Foundation
import ZIPFoundation

/// Darwin SDK 管理：下載、解壓、定位
/// SDK 從 PaxIDX 的 darwin-sdk release 下載（zip 格式，約 35MB，iOS 18.5 SDK），解壓到 App 容器
final class SDKManager {
    static let shared = SDKManager()

    /// SDK 在容器中的路徑
    var sdkPath: URL? {
        let url = containerURL.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// SDK 是否已安裝
    var isInstalled: Bool { sdkPath != nil }

    private var containerURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SDK", isDirectory: true)
    }

    /// 從 PaxIDX release 下載 iPhoneOS SDK（zip，約 35MB，iOS 18.5）
    /// - Parameters:
    ///   - onProgress: 進度回調 (0.0~1.0)
    ///   - completion: 完成回調 (成功/失敗訊息)
    func downloadLatest(
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // 回退：iOS 15.6 SDK（C 可用；Swift 模塊後續單獨疊加）
        let downloadURLString = "https://github.com/yongshuai1013/PaxIDX/releases/download/darwin-sdk-1/paxidx-darwin-sdk.zip"
        guard let downloadURL = URL(string: downloadURLString) else {
            completion(.failure(NSError(domain: "SDKManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "SDK 下載地址無效"])))
            return
        }

        // 先清掉舊的髒數據（18.5/15.6 混裝會導致 lld 報平台不支援）
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let sdkDir = docs.appendingPathComponent("SDK", isDirectory: true)
            if fm.fileExists(atPath: sdkDir.path) {
                try? fm.removeItem(at: sdkDir)
            }
        }

        // 下載（只下底包；Swift 6 模塊改手動疊加，避免自動疊加失敗拖累整個 SDK）
        self.downloadFile(from: downloadURL, onProgress: onProgress) { result in
            switch result {
            case .success(let fileURL):
                // 解壓
                do {
                    try self.extract(zip: fileURL)
                    try? FileManager.default.removeItem(at: fileURL)
                    if let sdk = self.sdkPath {
                        completion(.success(sdk))
                    } else {
                        throw NSError(domain: "SDKManager", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "解壓後找不到 SDK"])
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func downloadFile(
        from url: URL,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let delegate = DownloadDelegate(
            onProgress: onProgress,
            completion: { result in
                switch result {
                case .success(let tempURL):
                    // 移到臨時位置
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("sdk.zip")
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: dest)
                        completion(.success(dest))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        delegate.task = task
        task.resume()
    }

    private func extract(zip: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: containerURL, withIntermediateDirectories: true)
        // 先刪舊 SDK，避免新舊混雜
        let target = containerURL.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }

        // 用 ZIPFoundation 解壓（已在項目中，iOS 可用）
        guard let archive = Archive(url: zip, accessMode: .read) else {
            throw NSError(domain: "SDKManager", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "無法打開 zip"])
        }
        for entry in archive {
            let destURL = containerURL.appendingPathComponent(entry.path)
            if entry.type == .directory {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: destURL)
            }
        }

        // 解壓出來是 iPhoneOS15.6.sdk，重命名為 iPhoneOS.sdk
        let extracted = containerURL.appendingPathComponent("iPhoneOS15.6.sdk", isDirectory: true)
        if fm.fileExists(atPath: extracted.path) {
            try? fm.removeItem(at: target)
            try fm.moveItem(at: extracted, to: target)
        }
        if !fm.fileExists(atPath: target.path) {
            throw NSError(domain: "SDKManager", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "解壓後找不到 iPhoneOS.sdk"])
        }
    }

    /// 下載並疊加 Swift 6 模塊到 SDK 的 usr/lib/swift
    /// （C 專注版：已停用，保留空函數以兼容舊調用）
    private func overlaySwiftModules(onProgress: @escaping (Double) -> Void) throws {
        // Swift 已暫停，不再疊加模塊
        return
    }

    /// 刪除已安裝的 SDK
    func remove() throws {
        try FileManager.default.removeItem(at: containerURL)
    }
}

/// 下載進度代理：真實按字節數更新進度
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var task: URLSessionDownloadTask?
    private let onProgress: (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void

    init(onProgress: @escaping (Double) -> Void,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async { self.onProgress(progress) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        completion(.success(location))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completion(.failure(error))
        }
    }
}
