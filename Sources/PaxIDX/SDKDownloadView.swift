import SwiftUI

/// 下載 SDK（多版本管理）：SDK 按版本並存在 Documents/PaxSDK/sdk/
/// （iphoneos-26.sdk／iphoneos-27.sdk），編譯時在專案頁選用哪一版。
/// res（編譯器資源）跨版本共用一份。
struct SDKDownloadView: View {
    private struct ReleaseInfo {
        let major: Int
        let label: String
        let url: String
    }

    private let releases = [
        ReleaseInfo(major: 27, label: "iOS 27.1 SDK",
                    url: "https://github.com/yongshuai1013/PaxIDX/releases/download/paxsdk-ios27/PaxSDK.zip"),
        ReleaseInfo(major: 26, label: "iOS 26.5 SDK",
                    url: "https://github.com/yongshuai1013/PaxIDX/releases/download/paxsdk-ios26/PaxSDK.zip"),
    ]

    @State private var installed: [PaxSDKStore.InstalledSDK] = []
    @State private var busyMajor: Int? = nil
    @State private var progress: Double = 0
    @State private var statusText = ""
    @StateObject private var downloader = SDKZipDownloader()

    var body: some View {
        List {
            Section(header: Text("SDK 版本")) {
                ForEach(releases, id: \.major) { rel in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(rel.label)
                            Spacer()
                            if let sdk = installed.first(where: { $0.major == rel.major }) {
                                Text("已安裝")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button("刪除") {
                                    PaxSDKStore.remove(sdk)
                                    refresh()
                                }
                                .font(.caption)
                                .foregroundColor(.red)
                            } else if busyMajor == rel.major {
                                Text("處理中…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Button("下載") { startDownload(rel) }
                                    .font(.caption)
                            }
                        }
                        if busyMajor == rel.major {
                            ProgressView(value: progress)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if !statusText.isEmpty {
                Section(header: Text("狀態")) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section {
                Text("編譯時用哪一版，在專案的編譯頁上方切換。res（編譯器內建資源）各版共用一份，裝好第一份 SDK 時自動備齊。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("下載 SDK")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        installed = PaxSDKStore.installedSDKs()
    }

    private func startDownload(_ rel: ReleaseInfo) {
        guard let url = URL(string: rel.url) else { return }
        busyMajor = rel.major
        progress = 0
        statusText = "下載中…"
        downloader.start(url: url,
            onProgress: { p in progress = p },
            onDone: { file, errorText in
                if let errorText = errorText {
                    statusText = "下載失敗：\(errorText)"
                    busyMajor = nil
                    return
                }
                guard let file = file else {
                    statusText = "下載失敗：沒有檔案"
                    busyMajor = nil
                    return
                }
                statusText = "解壓安裝中…"
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let sdk = try PaxSDKStore.install(zipAt: file)
                        DispatchQueue.main.async {
                            statusText = "已安裝 iOS \(sdk.version) SDK"
                            busyMajor = nil
                            refresh()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            statusText = "安裝失敗：\(error.localizedDescription)"
                            busyMajor = nil
                        }
                    }
                }
            })
    }
}

/// PaxSDK.zip 下載器（帶進度）
final class SDKZipDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((URL?, String?) -> Void)?

    func start(url: URL, onProgress: @escaping (Double) -> Void,
               onDone: @escaping (URL?, String?) -> Void) {
        self.onProgress = onProgress
        self.onDone = onDone
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        s.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaxSDK-\(UUID().uuidString).zip")
        do {
            try FileManager.default.copyItem(at: location, to: dest)
            onDone?(dest, nil)
        } catch {
            onDone?(nil, error.localizedDescription)
        }
        session.invalidateAndCancel()
        self.session = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            onDone?(nil, error.localizedDescription)
            session.invalidateAndCancel()
            self.session = nil
        }
    }
}
