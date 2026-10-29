import SwiftUI
import Zip

/// 下載 SDK 頁（2026-10-29 永帥交代：原「下載管理」四件套改制）：
/// 編譯用的 SDK 只剩這一件——PaxSDK.zip（iPhoneOS 26 世代 SDK＋自編
/// Swift 6.4 編譯器 res，介面版本戳已在打包時改成 6.4）從 GitHub
/// release `paxsdk-ios26` 下載，解壓到 Documents/PaxSDK，試編與之後
/// 的編譯流程直指該處。不再有模塊疊加／Clang 頭／sysroot 等分件下載。
struct SDKDownloadView: View {
    @StateObject private var downloader = SDKDownloader()
    @State private var installed = SDKDownloadView.sdkReady()

    static var destRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaxSDK")
    }

    static func sdkReady() -> Bool {
        let fm = FileManager.default
        let sdk = destRoot.appendingPathComponent("iPhoneOS.sdk")
        let e = sdk.appendingPathComponent("usr/lib/swift/Swift.swiftmodule/arm64e-apple-ios.swiftinterface")
        let a = sdk.appendingPathComponent("usr/lib/swift/Swift.swiftmodule/arm64-apple-ios.swiftinterface")
        return (fm.fileExists(atPath: e.path) || fm.fileExists(atPath: a.path))
            && fm.fileExists(atPath: destRoot.appendingPathComponent("res/module.modulemap").path)
    }

    var body: some View {
        List {
            Section(header: Text("編譯用 SDK")) {
                HStack {
                    Text("狀態")
                    Spacer()
                    Text(installed ? "已就位" : "未下載")
                        .foregroundColor(installed ? .green : .orange)
                }
                if downloader.busy {
                    HStack {
                        ProgressView(value: downloader.progress)
                        Text("\(Int(downloader.progress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 45, alignment: .trailing)
                    }
                }
                if !downloader.message.isEmpty {
                    Text(downloader.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !downloader.busy {
                    Button(installed ? "重新下載 SDK" : "下載 SDK") {
                        downloader.start()
                    }
                }
                if installed && !downloader.busy {
                    Button("刪除 SDK", role: .destructive) {
                        try? FileManager.default.removeItem(at: Self.destRoot)
                        installed = Self.sdkReady()
                    }
                }
                Text("iPhoneOS 26 世代 SDK＋自編 Swift 6.4 編譯器資源（res）。下載後解壓到 Documents/PaxSDK，編譯時直接使用。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("下載 SDK")
        .onAppear { installed = Self.sdkReady() }
        .onChange(of: downloader.doneTick) { _ in installed = Self.sdkReady() }
    }
}

final class SDKDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress = 0.0
    @Published var busy = false
    @Published var message = ""
    @Published var doneTick = 0

    func start() {
        busy = true
        message = "下載中…"
        progress = 0
        let url = URL(string: "https://github.com/yongshuai1013/PaxIDX/releases/download/paxsdk-ios26/PaxSDK.zip")!
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let dest = SDKDownloadView.destRoot
        do {
            DispatchQueue.main.async { self.message = "下載完成，解壓中…" }
            try? fm.removeItem(at: dest)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let staged = dest.appendingPathComponent("PaxSDK.zip")
            try? fm.removeItem(at: staged)
            try fm.moveItem(at: location, to: staged)
            try Zip.unzipFile(staged, destination: dest, overwrite: true, password: nil)
            try? fm.removeItem(at: staged)
            let ok = SDKDownloadView.sdkReady()
            DispatchQueue.main.async {
                self.message = ok ? "SDK 已就位" : "解壓完成但驗證未過，請回報"
                self.busy = false
                self.doneTick += 1
            }
        } catch {
            DispatchQueue.main.async {
                self.message = "失敗：\(error.localizedDescription)"
                self.busy = false
                self.doneTick += 1
            }
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.message = "下載失敗：\(error.localizedDescription)"
                self.busy = false
                self.doneTick += 1
            }
        }
        session.finishTasksAndInvalidate()
    }
}
